import AppKit
import AVFoundation
import Testing
import SwiftUI
@testable import Trimato

@MainActor
@Suite(.serialized)
struct VoiceAdjustmentTests {
    private func fixture(amplitude: Float = 0.08, duration: Double = 4, secondAmplitude: Float? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-test-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000)))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            let scale = index >= Int(buffer.frameLength) / 2 ? secondAmplitude ?? amplitude : amplitude
            data[index] = scale * Float(sin(2 * Double.pi * 440 * Double(index) / 48000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func asset(_ url: URL, purpose: RecordingPurpose? = .audioDescription, duration: Double = 4) -> MediaAssetRecord {
        var asset = MediaAssetRecord(name: "Voice", originalPath: url.path, duration: ProjectTime(seconds: duration),
            hasAudio: true, sourceEdit: [segment(0, duration)])
        asset.recordingPurpose = purpose
        return asset
    }

    private func segment(_ start: Double, _ duration: Double) -> SourceSegment {
        SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: start), duration: ProjectTime(seconds: duration)))
    }

    @Test func smoothingReducesLevelDifferencesForQuietAndLoudTakes() async throws {
        for amplitude: Float in [0.02, 0.2] {
            let source = try fixture(amplitude: amplitude / 4, secondAmplitude: amplitude)
            defer { try? FileManager.default.removeItem(at: source) }
            let quiet = [segment(0.5, 1)], loud = [segment(2.8, 1)]
            let originalDifference = try await VoiceAudioProcessor.measure(source, segments: loud) - VoiceAudioProcessor.measure(source, segments: quiet)
            var previous = originalDifference
            for amount in [0.0, 50.0, 100.0] {
                let output = try await VoiceAudioProcessor.render(source: source,
                    settings: VoiceAdjustment(evenOut: true, smoothingAmount: amount), segments: nil, trimOutput: false)
                defer { try? FileManager.default.removeItem(at: output) }
                let difference = try await VoiceAudioProcessor.measure(output, segments: loud) - VoiceAudioProcessor.measure(output, segments: quiet)
                if amount == 0 { #expect(abs(difference - originalDifference) < 0.3) }
                else { #expect(difference < previous - 0.3) }
                previous = difference
            }
        }
    }

    @Test func draftPreviewDoesNotChangeEditorOrProject() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var project = TrimatoProject()
        let record = asset(source)
        let id = project.putRecording(record, at: .zero)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: [segment(0, 4)])
        let originalProject = controller.project
        let originalAudio = context.audioSettings
        let voice = VoiceAdjustment(targetLoudness: -25, evenOut: true)
        let view = FilterAuditionView(context: context, work: VoiceAdjustmentWork(), candidate: nil, voice: voice, voiceMatching: true, beforePlayback: {})
        let (filters, audio) = view.settings(enabled: true)
        let (_, bypass) = view.settings(enabled: false)
        #expect(bypass?.voice?.targetLoudness == nil)
        #expect(bypass?.voice?.evenOut == true)
        let url = try await context.voiceMixedPreview(filters: filters, audio: audio)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(abs(try await VoiceAudioProcessor.measure(url) - (-25)) < 0.5)
        #expect(context.audioSettings == originalAudio)
        #expect(controller.project == originalProject)
    }

    @Test func olderAudioSettingsDecodeAndVoiceSettingsRoundTrip() throws {
        let data = try JSONEncoder().encode(AudioClipSettings.neutral)
        let decoded = try JSONDecoder().decode(AudioClipSettings.self, from: data)
        #expect(decoded.voice == nil)
        var audio = decoded
        audio.voice = VoiceAdjustment(targetLoudness: -23, referenceStart: 2, referenceEnd: 8, evenOut: true, level: 1)
        #expect(!audio.isNeutral)
        #expect(try JSONDecoder().decode(AudioClipSettings.self, from: JSONEncoder().encode(audio)) == audio)
        #expect(ClipFilter.legacyTone(audio) == nil)
    }

    @Test func invalidMeasurementsAndSettingsAreRejected() throws {
        for value in ["-inf", "nan", "-90", "4"] {
            #expect(throws: (any Error).self) { try VoiceAudioProcessor.loudness(from: "{\"input_i\":\"\(value)\"}") }
        }
        #expect(try VoiceAudioProcessor.loudness(from: "log\n{\"input_i\":\"-23.45\"}\n") == -23.45)
        #expect(throws: (any Error).self) { try VoiceAdjustment(level: .nan).validate() }
    }

    @Test func differentTakesReachTheSameLoudnessWithoutChangingOriginals() async throws {
        let quiet = try fixture(amplitude: 0.025), loud = try fixture(amplitude: 0.2)
        defer { for url in [quiet, loud] { try? FileManager.default.removeItem(at: url) } }
        let originals = try [Data(contentsOf: quiet), Data(contentsOf: loud)]
        for (index, source) in [quiet, loud].enumerated() {
            let output = try await VoiceAudioProcessor.render(source: source,
                settings: VoiceAdjustment(targetLoudness: -23, evenOut: true), segments: [segment(0, 4)], trimOutput: true)
            defer { try? FileManager.default.removeItem(at: output) }
            #expect(abs(try await VoiceAudioProcessor.measure(output) - (-23)) < 0.5)
            #expect(try Data(contentsOf: source) == originals[index])
            #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 4) < 0.002)
        }
    }

    @Test func matchingMeasuresOnlyTheEditedSegmentsAndProjectPreparationAgrees() async throws {
        let source = try fixture(amplitude: 0.015, secondAmplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: source) }
        let edit = [segment(0, 1), segment(1, 1)]
        var audio = AudioClipSettings.neutral
        audio.voice = VoiceAdjustment(targetLoudness: -25, evenOut: true, level: 1)
        let preview = try await ClipFilterRenderer.render(source: source, filters: [], audio: true,
            duration: 4, segments: edit, audioSettings: audio)
        defer { try? FileManager.default.removeItem(at: preview) }
        let level = try await VoiceAudioProcessor.measure(preview)
        #expect(abs(level - (-24)) < 0.5)
        var project = TrimatoProject()
        let record = asset(source)
        let id = project.putRecording(record, at: .zero)
        try project.updateTrackClip(id: id, segments: edit)
        try project.setClipEffects(id: id, audio: audio, filters: nil)
        let (prepared, urls, files) = try await ClipFilterRenderer.prepare(project: project, urls: [record.id: source])
        defer { for url in files { try? FileManager.default.removeItem(at: url) } }
        let clip = try #require(prepared.timelineClip(id: id))
        #expect(clip.audioSettings.isNeutral)
        let processed = try #require(urls[clip.assetID])
        #expect(abs(try await VoiceAudioProcessor.measure(processed, segments: edit) - level) < 0.2)
        #expect(clip.segments == edit)
    }

    @Test func silentReferenceAndTakeFailWithoutMutatingProject() async throws {
        let silent = try fixture(amplitude: 0)
        defer { try? FileManager.default.removeItem(at: silent) }
        await #expect(throws: (any Error).self) { try await VoiceAudioProcessor.measure(silent) }
        var project = TrimatoProject()
        let id = project.putRecording(asset(silent), at: .zero)
        let track = try #require(project.tracks.first { $0.clips.contains { $0.id == id } })
        let controller = ProjectController(document: ProjectDocument(project: project))
        await #expect(throws: (any Error).self) {
            try await controller.applyVoiceToTrack(track.id, settings: VoiceAdjustment(targetLoudness: -23))
        }
        #expect(controller.project == project)
        #expect(!controller.document.hasUnsavedChanges)
    }

    @Test func trackApplicationPreservesOtherEffectsAndSupportsSaveAndUndo() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var project = TrimatoProject()
        let first = project.putRecording(asset(source), at: .zero)
        let second = project.putRecording(asset(source), at: ProjectTime(seconds: 4))
        let other = project.putRecording(asset(source, purpose: .voiceOver), at: .zero)
        var audio = AudioClipSettings.neutral
        audio.gainDecibels = -2
        let tone = ClipFilter(kind: .tone)
        try project.setClipEffects(id: first, audio: audio, filters: [tone])
        let track = try #require(project.tracks.first { $0.clips.contains { $0.id == first } })
        let document = ProjectDocument(project: project)
        let controller = ProjectController(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let voice = VoiceAdjustment(targetLoudness: -23, evenOut: true)
        undo.beginUndoGrouping()
        try await controller.applyVoiceToTrack(track.id, settings: voice)
        undo.endUndoGrouping()
        #expect(controller.project.timelineClip(id: first)?.audioSettings.voice == voice)
        #expect(controller.project.timelineClip(id: second)?.audioSettings.voice == voice)
        #expect(controller.project.timelineClip(id: other)?.audioSettings.voice == nil)
        #expect(controller.project.timelineClip(id: first)?.audioSettings.gainDecibels == -2)
        #expect(controller.project.timelineClip(id: first)?.filters == [tone])
        #expect(document.hasUnsavedChanges)
        let saved = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(controller.project))
        #expect(saved == controller.project)
        undo.undo()
        #expect(controller.project == project)
        #expect(!document.hasUnsavedChanges)
    }

    @Test func referenceExcludesNarrationAndDucking() throws {
        var project = TrimatoProject()
        project.putRecording(asset(URL(fileURLWithPath: "/ad.wav")), at: .zero)
        project.putRecording(asset(URL(fileURLWithPath: "/vo.wav"), purpose: .voiceOver), at: .zero)
        let show = asset(URL(fileURLWithPath: "/show.wav"), purpose: nil)
        let id = project.putRecording(show, at: ProjectTime(seconds: 4))
        let reference = VoiceReferenceAudio.showOnly(project)
        #expect(reference.tracks.flatMap(\.clips).map(\.id) == [id])
        #expect(!reference.descriptionDucking.enabled)
        #expect(project.tracks.flatMap(\.clips).count == 3)
    }

    @Test func editorPreservesVoiceDuringRefreshAndExistingClipUpdates() throws {
        var project = TrimatoProject()
        let record = asset(URL(fileURLWithPath: "/voice.wav"))
        let id = project.putRecording(record, at: .zero)
        var audio = AudioClipSettings.neutral
        audio.voice = VoiceAdjustment(targetLoudness: -23)
        audio.lowGainDecibels = 1
        try project.setClipEffects(id: id, audio: audio, filters: nil)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: record.sourceEdit)
        #expect(context.audioSettings?.voice == audio.voice)
        #expect(context.narrationTrack != nil)
        context.refreshCommittedEffects()
        #expect(context.audioSettings?.voice == audio.voice)
        context.audioSettings?.voice?.level = 2
        #expect(context.hasUncommittedChanges)
        #expect(context.performUpdate())
        #expect(controller.project.timelineClip(id: id)?.audioSettings.voice?.level == 2)
        #expect(controller.document.hasUnsavedChanges)
    }
    @Test func referenceAndFinalExportUseTheSamePerceivedLevel() async throws {
        let source = try fixture(amplitude: 0.1), voiceSource = try fixture(amplitude: 0.025)
        defer { for url in [source, voiceSource] { try? FileManager.default.removeItem(at: url) } }
        var project = TrimatoProject()
        let show = asset(source, purpose: nil), voice = asset(voiceSource)
        project.putRecording(show, at: .zero)
        let id = project.putRecording(voice, at: ProjectTime(seconds: 4))
        let urls = [show.id: source, voice.id: voiceSource]
        let reference = try await VoiceReferenceAudio.render(project: project, urls: urls, start: 0, end: 4)
        defer { try? FileManager.default.removeItem(at: reference) }
        let target = try await VoiceAudioProcessor.measure(reference)
        var audio = AudioClipSettings.neutral
        audio.voice = VoiceAdjustment(targetLoudness: target, evenOut: true)
        try project.setClipEffects(id: id, audio: audio, filters: nil)
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls, purpose: .finalExport)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let export = FileManager.default.temporaryDirectory.appendingPathComponent("voice-export-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: export) }
        try await AudioOnlyExporter.export(asset: result.composition, audioMix: result.audioMix,
            timeRange: CMTimeRange(start: CMTime(seconds: 4, preferredTimescale: 48000), duration: CMTime(seconds: 4, preferredTimescale: 48000)),
            format: .wav24, to: export, progress: { _ in })
        #expect(abs(try await VoiceAudioProcessor.measure(export) - target) < 0.5)
    }

    @Test func cancellationKeepsAllTrackSettingsIntact() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var project = TrimatoProject()
        let id = project.putRecording(asset(source), at: .zero)
        let track = try #require(project.tracks.first { $0.clips.contains { $0.id == id } })
        let controller = ProjectController(document: ProjectDocument(project: project))
        let task = Task { try await controller.applyVoiceToTrack(track.id, settings: VoiceAdjustment(targetLoudness: -23)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(controller.project == project)
    }

    @Test func limiterProtectsLoudTakesAndKeepsTheirDuration() async throws {
        let source = try fixture(amplitude: 0.8)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await VoiceAudioProcessor.render(source: source, settings: VoiceAdjustment(level: 12), segments: nil, trimOutput: false)
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
        #expect(peak < 0.9)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 4) < 0.002)
    }

    @Test func voiceControlsExposeNativeFieldsAndSliderArrowActions() async throws {
        let controller = ProjectController(document: ProjectDocument())
        let work = VoiceAdjustmentWork()
        var settings = VoiceAdjustment()
        let host = NSHostingView(rootView: VoiceAdjustmentControls(
            settings: Binding(get: { settings }, set: { settings = $0 }), controller: controller,
            work: work, track: nil, validateTake: { _ in }, applyTrack: { _ in }, beforePlayback: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { work.stopKeyboard(); work.cancel(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func attribute(_ item: NSObject, _ key: String) -> Any? {
            item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
        }
        func descendants(_ item: NSObject) -> [NSObject] {
            [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
        }
        let elements = descendants(host)
        for name in ["Dialogue reference In", "Dialogue reference Out"] {
            let label = try #require(elements.first { attribute($0, "accessibilityValue") as? String == name })
            let targets = try #require(attribute(label, "accessibilityServesAsTitleForUIElements") as? [NSObject])
            #expect(targets.count == 1)
            let field = try #require(descendants(targets[0]).first { attribute($0, "accessibilityRole") as? String == "AXTextField" })
            #expect((attribute(field, "accessibilityPlaceholderValue") as? String ?? "").isEmpty)
        }
        let slider = try #require(elements.first { attribute($0, "accessibilityIdentifier") as? String == "trimato.voice.level" })
        #expect(attribute(slider, "accessibilityRole") as? String == "AXSlider")
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
        #expect(SettingsSliderKeyboard.handle(up, focused: slider, identifier: "trimato.voice.level") == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(settings.level > 0)
    }

}
