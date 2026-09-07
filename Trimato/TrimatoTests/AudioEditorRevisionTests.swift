import AVFoundation
import AppKit
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct AudioEditorRevisionTests {
    func fixture(duration: Double = 2, sample: (Double) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-revision-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { channel[index] = sample(Double(index) / 48000) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
    func samples(_ url: URL) async throws -> [Float] {
        let decoded = FileManager.default.temporaryDirectory.appendingPathComponent("audio-samples-\(UUID()).f32")
        defer { try? FileManager.default.removeItem(at: decoded) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-i", url.path,
            "-map", "0:a:0", "-af", "pan=mono|c0=c0", "-ac", "1", "-ar", "48000", "-f", "f32le", decoded.path])
        let data = try Data(contentsOf: decoded)
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
    }
    func power(_ samples: [Float], start: Double, end: Double) -> Double {
        let section = samples[Int(start * 48000)..<min(samples.count, Int(end * 48000))]
        return section.reduce(0) { $0 + Double($1 * $1) } / Double(section.count)
    }
    func segment(_ duration: Double) -> SourceSegment {
        SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: duration)))
    }
    @Test(arguments: [100.0, 1000.0, 8000.0])
    func mainEqualizerChangesTheSelectedBand(frequency: Double) async throws {
        let source = try fixture { Float(0.02 * sin(2 * .pi * frequency * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try await samples(source)
        for gain in [-6.0, 6.0] {
            var settings = AudioClipSettings.neutral
            if frequency == 100 { settings.lowGainDecibels = gain }
            if frequency == 1000 { settings.midGainDecibels = gain }
            if frequency == 8000 { settings.highGainDecibels = gain }
            let output = try await ClipFilterRenderer.render(source: source, filters: [], audio: true, duration: 2,
                segments: [segment(2)], audioSettings: settings, highPrecision: true)
            defer { try? FileManager.default.removeItem(at: output) }
            let processed = try await samples(output)
            let change = 10 * log10(power(processed, start: 0.5, end: 1.5) / power(original, start: 0.5, end: 1.5))
            #expect(abs(change - gain) < 0.25)
        }
    }
    @Test func oldToneMovesToMainEqualizerWithoutDoublingOrDirtyingProject() throws {
        var project = TrimatoProject()
        let record = MediaAssetRecord(name: "Voice", originalPath: "/tmp/voice.wav", duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: [segment(2)])
        let id = project.putRecording(record, at: .zero)
        var tone = ClipFilter(kind: .tone)
        tone.values["low"] = 6
        var audio = AudioClipSettings.neutral
        audio.gainDecibels = -3
        try project.setClipEffects(id: id, audio: audio, filters: [tone])
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: record.sourceEdit)
        #expect(context.audioSettings?.lowGainDecibels == 6)
        #expect(context.audioSettings?.gainDecibels == -3)
        #expect(context.filters.isEmpty)
        #expect(!context.hasUncommittedChanges)
        context.refreshCommittedEffects()
        #expect(context.audioSettings?.lowGainDecibels == 6)
        #expect(!controller.document.hasUnsavedChanges)
        audio.lowGainDecibels = 2
        let preserved = ClipPlacementCommandContext.mainEqualizer(audio: audio, filters: [tone])
        #expect(preserved.0 == audio)
        #expect(preserved.1 == [tone])
    }
    @Test func presetsPreserveOtherAudioSettings() {
        var audio = AudioClipSettings.neutral
        audio.gainDecibels = -4
        audio.voice = VoiceAdjustment(targetLoudness: -25)
        EqualizerPreset.clearer.apply(to: &audio)
        #expect(audio.lowGainDecibels == -2 && audio.midGainDecibels == 3 && audio.highGainDecibels == 2)
        #expect(audio.gainDecibels == -4 && audio.voice?.targetLoudness == -25)
        EqualizerPreset.flat.apply(to: &audio)
        #expect(audio.lowGainDecibels == 0 && audio.midGainDecibels == 0 && audio.highGainDecibels == 0)
    }
    @Test func roomAndEchoHaveAudibleTailsWithoutChangingDuration() async throws {
        let source = try fixture(duration: 3) { t in
            t >= 0.1 && t < 0.11 ? Float(0.4 * sin(2 * .pi * 1700 * t)) : 0
        }
        defer { try? FileManager.default.removeItem(at: source) }
        for kind in [ClipFilterKind.reverb, .echo] {
            var filter = ClipFilter(kind: kind)
            filter.values["amount"] = 60
            filter.values["room"] = 2
            let output = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: true, duration: 3, highPrecision: true)
            defer { try? FileManager.default.removeItem(at: output) }
            let data = try await samples(output)
            let actualDuration = try await AVURLAsset(url: output).load(.duration).seconds
            #expect(abs(actualDuration - 3) < 0.002)
            #expect(abs(Double(data.count) / 48000 - 3) < 0.002)
            #expect(power(data, start: 0.3, end: 0.5) > 0.00000001)
            #expect(power(data, start: 2.5, end: 2.9) < power(data, start: 0.3, end: 0.5))
        }
    }
    @Test func peakLimiterActuallyReducesPeaks() async throws {
        let source = try fixture { Float(0.8 * sin(2 * .pi * 1000 * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        var filter = ClipFilter(kind: .limitPeaks)
        filter.values["ceiling"] = -9
        let output = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: true, duration: 2, highPrecision: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let peak = try await samples(output).map { abs($0) }.max() ?? 1
        #expect(peak < 0.37 && peak > 0.3)
    }
    @Test func speechSofteningAndNoiseReductionChangeRelevantAudio() async throws {
        let source = try fixture { t in Float(0.025 * sin(2 * .pi * 800 * t) + 0.2 * sin(2 * .pi * 8000 * t)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try await samples(source)
        var filter = ClipFilter(kind: .softenS)
        filter.values["amount"] = 90
        let output = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: true, duration: 2, highPrecision: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let processed = try await samples(output)
        #expect(power(processed, start: 0.5, end: 1.5) < power(original, start: 0.5, end: 1.5) * 0.9)
        let noise = try fixture { t in
            let hashed = sin(t * 48000 * 12.9898) * 43758.5453
            return Float(0.006 * (2 * (hashed - floor(hashed)) - 1))
        }
        defer { try? FileManager.default.removeItem(at: noise) }
        let reduced = try await ClipFilterRenderer.render(source: noise, filters: [ClipFilter(kind: .backgroundNoise)], audio: true, duration: 2, highPrecision: true)
        defer { try? FileManager.default.removeItem(at: reduced) }
        #expect(power(try await samples(reduced), start: 0.5, end: 1.5) < power(try await samples(noise), start: 0.5, end: 1.5) * 0.9)
    }

    @Test(arguments: ClipFilterKind.allCases.filter { $0.isAudio })
    func everyAudioEffectAgreesBetweenClipPreviewAndFinalOutput(kind: ClipFilterKind) async throws {
        let source = try fixture { t in
            let h = sin(t * 48000 * 12.9898) * 43758.5453
            return Float((t < 1 ? 0.035 : 0.12) * sin(2 * .pi * 800 * t) + 0.02 * (2 * (h - floor(h)) - 1))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        var filter = ClipFilter(kind: kind)
        if kind == .tone { filter.values["mid"] = 6 }
        var audio = AudioClipSettings.neutral
        audio.lowGainDecibels = 3
        let preview = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: true,
            duration: 2, segments: [segment(2)], audioSettings: audio)
        defer { try? FileManager.default.removeItem(at: preview) }
        var project = TrimatoProject()
        let record = MediaAssetRecord(name: "Comparison", originalPath: source.path, duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: [segment(2)])
        let id = project.putRecording(record, at: .zero)
        try project.setClipEffects(id: id, audio: audio, filters: [filter])
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [record.id: source], purpose: .finalExport)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let export = FileManager.default.temporaryDirectory.appendingPathComponent("effect-export-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: export) }
        try await AudioOnlyExporter.export(asset: result.composition, audioMix: result.audioMix,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48000)),
            format: .wav24, to: export, progress: { _ in })
        let expected = try await samples(preview), actual = try await samples(export)
        #expect(abs(actual.count - expected.count) < 100)
        let count = min(actual.count, expected.count)
        let error = (0..<count).reduce(0.0) { $0 + pow(Double(actual[$1] - expected[$1]), 2) } / Double(count)
        #expect(error < 0.00001)
    }

    @Test func reverbAmountProducesUsefulReflectedLevel() async throws {
        let source = try fixture { t in t < 1 ? Float(0.1 * sin(2 * .pi * 800 * t)) : 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        var energies: [Double] = []
        for amount in [25.0, 75.0] {
            var effect = ClipFilter(kind: .reverb)
            effect.values["amount"] = amount
            effect.values["room"] = 2
            let output = try await ClipFilterRenderer.render(source: source, filters: [effect], audio: true, duration: 2, highPrecision: true)
            defer { try? FileManager.default.removeItem(at: output) }
            let signal = try await samples(output)
            energies.append(power(signal, start: 1.02, end: 1.2))
        }
        #expect(energies[0] > 0.000001)
        #expect(energies[1] > energies[0] * 5)
    }

    @Test func draftActionsDoNotDependOnAuditionOrWindowFocus() {
        var project = TrimatoProject()
        let record = MediaAssetRecord(name: "Voice", originalPath: "/tmp/voice.wav", duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: [segment(2)])
        let id = project.putRecording(record, at: .zero)
        let context = ClipPlacementCommandContext(controller: ProjectController(document: ProjectDocument(project: project)), editSelection: .timelineClip(id), segments: record.sourceEdit)
        context.audioSettings?.gainDecibels = 3
        context.effectsReady = false
        context.voiceWorkBusy = true
        context.setKeyWindow(false)
        #expect(context.canPlace && context.canUpdate)
    }

    @Test func mainPlaybackWaitsForTheLatestPreviewInsteadOfPlayingOldAudio() async throws {
        let source = try fixture { Float(0.02 * sin(2 * .pi * 440 * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let model = VideoPlayerViewModel()
        defer { model.closeMedia() }
        model.duration = 2
        model.player.replaceCurrentItem(with: AVPlayerItem(url: source))
        var ready = false
        model.preparePlayback = { ready }
        model.togglePlayPause()
        #expect(model.waitingForClipPreview && model.player.rate == 0)
        var audio = AudioClipSettings.neutral
        audio.midGainDecibels = 9
        let processed = try await ClipFilterRenderer.render(source: source, filters: [], audio: true, duration: 2, audioSettings: audio)
        model.installFilteredPreview(asset: AVURLAsset(url: processed), url: processed, audio: true)
        ready = true
        model.completePreviewPreparation(ready: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.waitingForClipPreview)
        #expect((model.player.currentItem?.asset as? AVURLAsset)?.url == processed)
        #expect(model.player.rate > 0)
    }

    @Test func nativeAudioSliderRespondsToVoiceOverArrows() async throws {
        var value = 0.0
        let host = NSHostingView(rootView: AudioValueSlider(label: "Bass", value: Binding(get: { value }, set: { value = $0 }),
            range: -12...12, step: 0.5, unit: "dB", identifier: "trimato.test.bass"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        func attr(_ item: NSObject, _ key: String) -> Any? { item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil }
        func children(_ item: NSObject) -> [NSObject] { [item] + ((attr(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(children) }
        let slider = try #require(children(host).first { attr($0, "accessibilityIdentifier") as? String == "trimato.test.bass" })
        #expect(attr(slider, "accessibilityRole") as? String == "AXSlider")
        for key: UInt16 in [126, 125] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            #expect(SettingsSliderKeyboard.handle(event, focused: slider, identifier: "trimato.test.bass") == nil)
            #expect(abs(value - (key == 126 ? 0.5 : 0)) < 0.01)
        }
    }
    @Test func playbackRestartsAtInAfterOutAndResumesMidClip() async throws {
        let source = try fixture { Float(0.02 * sin(2 * .pi * 440 * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let model = VideoPlayerViewModel()
        defer { model.closeMedia() }
        model.duration = 2
        model.player.replaceCurrentItem(with: AVPlayerItem(url: source))
        model.setInMarker(at: CMTime(seconds: 0.4, preferredTimescale: 48000))
        model.setOutMarker(at: CMTime(seconds: 1.2, preferredTimescale: 48000))
        await model.player.seek(to: CMTime(seconds: 1.2, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        model.togglePlayPause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.player.currentTime().seconds >= 0.4 && model.player.currentTime().seconds < 0.9)
        model.togglePlayPause()
        await model.player.seek(to: CMTime(seconds: 0.8, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        model.togglePlayPause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.player.currentTime().seconds >= 0.8)
    }
}
