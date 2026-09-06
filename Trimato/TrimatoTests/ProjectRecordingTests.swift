import AppKit
import AVFoundation
import Testing
import SwiftUI
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ProjectRecordingTests {
    func asset(_ purpose: RecordingPurpose, duration: Double = 2) -> MediaAssetRecord {
        let length = ProjectTime(seconds: duration)
        var asset = MediaAssetRecord(name: purpose.title, originalPath: "/recording.wav", duration: length,
                                     hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: length))])
        asset.recordingPurpose = purpose
        asset.recordingRelativePath = "Recordings/recording.wav"
        return asset
    }

    @Test func recordingsRoundTripAsEditableAudioAndSeparateTranscript() throws {
        var project = TrimatoProject()
        let voice = asset(.voiceOver)
        let description = asset(.audioDescription)
        let voiceID = project.putRecording(voice, at: ProjectTime(seconds: 7))
        project.putRecording(description, at: ProjectTime(seconds: 3))
        let cue = CaptionCue(start: ProjectTime(seconds: 3), end: ProjectTime(seconds: 5), text: "A door opens.")
        try project.putDescription(cue)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Hello.")])
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.timelineClip(id: voiceID)?.isIndependentAudio == true)
        #expect(decoded.timelineClip(id: voiceID)?.timelineStart == ProjectTime(seconds: 7))
        #expect(decoded.captionTrack?.captionCues.map(\.text) == ["Hello."])
        #expect(decoded.descriptionTranscriptTrack?.captionCues.map(\.text) == ["A door opens."])
        #expect(decoded.descriptionTranscriptTrack?.captionCues.first?.displayName == "Description: A door opens.")
        #expect(decoded.asset(id: voice.id)?.recordingRelativePath == "Recordings/recording.wav")
    }

    @Test func duckingUsesOnlyAudibleDescriptionClipsAndFollowsTheirTiming() {
        var project = TrimatoProject()
        project.putRecording(asset(.voiceOver), at: .zero)
        let id = project.putRecording(asset(.audioDescription), at: ProjectTime(seconds: 3))
        let settings = project.descriptionDucking
        var ranges = settings.ranges(in: project)
        #expect(ranges == [ProjectTimeRange(start: ProjectTime(seconds: 3), duration: ProjectTime(seconds: 2))])
        #expect(settings.volume(at: ProjectTime(seconds: 1), ranges: ranges) == 1)
        #expect(abs(settings.volume(at: ProjectTime(seconds: 4), ranges: ranges) - Float(pow(10, -5.0 / 20))) < 0.0001)
        let fading = settings.volume(at: ProjectTime(seconds: 2.875), ranges: ranges)
        #expect(fading > settings.volume && fading < 1)
        let index = project.tracks.firstIndex { $0.clips.contains { $0.id == id } }!
        project.tracks[index].clips[0].timelineStart = ProjectTime(seconds: 8)
        ranges = settings.ranges(in: project)
        #expect(ranges.first?.start == ProjectTime(seconds: 8))
        project.tracks[index].isMuted = true
        #expect(settings.ranges(in: project).isEmpty)
    }

    @Test func overlappingDescriptionsDoNotDoubleDuck() {
        let settings = DescriptionDucking()
        let ranges = [ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)),
                      ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 3))]
        #expect(settings.volume(at: ProjectTime(seconds: 2), ranges: ranges) == settings.volume)
    }

    @Test func upAndDownInvokeNativeSliderActionsWithoutKeyboardFocus() throws {
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.setAccessibilityIdentifier(SettingsSliderKeyboard.identifier)
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code))
        }
        #expect(SettingsSliderKeyboard.handle(try key(126), focused: slider) == nil)
        #expect(slider.doubleValue > 50)
        #expect(SettingsSliderKeyboard.handle(try key(125), focused: slider) == nil)
        #expect(abs(slider.doubleValue - 50) < 0.001)
        #expect(SettingsSliderKeyboard.handle(try key(126, modifiers: .command), focused: slider) != nil)
        slider.setAccessibilityIdentifier("another-slider")
        #expect(SettingsSliderKeyboard.handle(try key(126), focused: slider) != nil)
    }

    @Test func newProjectIncludesRecordingsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectDocument.writeNewProject(TrimatoProject(name: "Test"), toFolderAt: root)
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings").path, isDirectory: &directory))
        #expect(directory.boolValue)
    }

    @Test func olderProjectsDefaultDuckingAndNoDescriptionTrack() throws {
        let data = Data(#"{"schemaVersion":4,"name":"Old project"}"#.utf8)
        let project = try JSONDecoder().decode(TrimatoProject.self, from: data)
        #expect(project.descriptionDucking == DescriptionDucking())
        #expect(project.descriptionTranscriptTrack == nil)
    }

    @Test func addingRecordingAndTranscriptIsOneUndoableProjectChange() throws {
        let document = ProjectDocument(project: TrimatoProject())
        let controller = ProjectController(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let before = document.project
        let recording = asset(.audioDescription)
        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "A door opens.")
        undo.beginUndoGrouping()
        try controller.addProjectRecording(asset: recording, at: .zero, cue: cue, ducking: DescriptionDucking())
        undo.endUndoGrouping()
        #expect(document.project.media.count == 1)
        #expect(document.project.descriptionTranscriptTrack?.captionCues.count == 1)
        undo.undo()
        #expect(document.project == before)
        undo.redo()
        #expect(document.project.media.first?.id == recording.id)
    }

    @Test func voicerKeepsItsInsertionPointAndHasNoSettingsTestLimit() {
        let controller = ProjectController(document: ProjectDocument())
        controller.timelinePlayhead = ProjectTime(seconds: 12)
        let session = ProjectRecordingSession(controller: controller, purpose: .voiceOver)
        defer { session.close() }
        controller.timelinePlayhead = ProjectTime(seconds: 30)
        #expect(session.start == 12)
        #expect(session.capture.maximumDuration == nil)
    }

    @Test func closingDescriptionEditingRestoresItsTimelineOrigin() throws {
        var project = TrimatoProject()
        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "A door opens.")
        try project.putDescription(cue)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.requestRecording(.audioDescription, cue: cue)
        controller.dismissRecording()
        controller.recordingWindowDidDismiss()
        #expect(controller.timelineFocusRestoreTarget == .caption(cue.id))
        #expect(controller.activeTimelineTrackID == project.descriptionTranscriptTrack?.id)
    }

    private func tone(at url: URL, seconds: Double, frequency: Double = 440) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { channel[index] = Float(sin(Double(index) * 2 * .pi * frequency / 48_000) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test func speedToFitPreservesPitchAndNeverLengthensShortTakes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try tone(at: url, seconds: 2)
        let unchanged = try await RecordingTakeProcessor.prepare(url: url, duration: 2, available: 4, speedUp: true, trim: false)
        #expect(unchanged.url == url)
        #expect(unchanged.duration == 2)
        let fitted = try await RecordingTakeProcessor.prepare(url: url, duration: 2, available: 1, speedUp: true, trim: false)
        defer { try? FileManager.default.removeItem(at: fitted.url) }
        #expect(fitted.duration > 0.9 && fitted.duration <= 1)
        let file = try AVAudioFile(forReading: fitted.url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        let lower = Int(buffer.frameLength) / 5
        let upper = Int(buffer.frameLength) * 4 / 5
        let crossings = (lower..<upper).filter { samples[$0] <= 0 && samples[$0 + 1] > 0 }.count
        let frequency = Double(crossings) / (Double(upper - lower) / file.processingFormat.sampleRate)
        #expect(abs(frequency - 440) < 10)
    }

    @Test func descriptionMixDucksShowAndExportsAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let showURL = root.appendingPathComponent("show.wav")
        let descriptionURL = root.appendingPathComponent("description.wav")
        try tone(at: showURL, seconds: 4)
        try tone(at: descriptionURL, seconds: 2, frequency: 660)
        var show = asset(.voiceOver, duration: 4)
        show.originalPath = showURL.path
        show.playbackMode = .nativePassthrough
        var description = asset(.audioDescription)
        description.originalPath = descriptionURL.path
        description.playbackMode = .nativePassthrough
        var project = TrimatoProject()
        project.putRecording(show, at: .zero)
        project.putRecording(description, at: ProjectTime(seconds: 1))
        let urls = [show.id: showURL, description.id: descriptionURL]
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let parameters = try #require(result.audioMix?.inputParameters)
        var levels: [Float] = []
        for input in parameters {
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            #expect(input.getVolumeRamp(for: ProjectTime(seconds: 2).cmTime, startVolume: &start, endVolume: &end, timeRange: &range))
            levels.append(start)
        }
        #expect(levels.contains { abs($0 - project.descriptionDucking.volume) < 0.001 })
        #expect(levels.contains { abs($0 - 1) < 0.001 })
        let output = root.appendingPathComponent("mixed.wav")
        try await ProjectExporter.export(project: project, mediaURLs: urls, format: .wav, to: output, progress: { _ in })
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 4) < 0.1)
    }

    @Test func mixedTrackCrossfadeKeepsDescriptionOutsideDucking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let showURL = root.appendingPathComponent("show.wav")
        let descriptionURL = root.appendingPathComponent("description.wav")
        try tone(at: showURL, seconds: 6)
        try tone(at: descriptionURL, seconds: 6, frequency: 660)
        var show = asset(.voiceOver, duration: 6)
        var description = asset(.audioDescription, duration: 6)
        show.originalPath = showURL.path
        description.originalPath = descriptionURL.path
        show.playbackMode = .nativePassthrough
        description.playbackMode = .nativePassthrough
        let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 2)))]
        show.sourceEdit = segments
        description.sourceEdit = segments
        var project = TrimatoProject()
        let leading = project.putRecording(show, at: .zero)
        let trailing = project.putRecording(description, at: ProjectTime(seconds: 2))
        project.tracks[0].clips.append(contentsOf: project.tracks[1].clips)
        project.tracks.remove(at: 1)
        try project.addTransition(TimelineTransition(trackID: project.tracks[0].id, edge: .between, kind: .audio(.crossFade),
                                                      duration: ProjectTime(seconds: 1), leadingClipID: leading, trailingClipID: trailing))
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [show.id: showURL, description.id: descriptionURL])
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let inputs = try #require(result.audioMix?.inputParameters)
        #expect(inputs.count == 4)
        var levels: [Float] = []
        for input in inputs {
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            #expect(input.getVolumeRamp(for: ProjectTime(seconds: 2).cmTime, startVolume: &start, endVolume: &end, timeRange: &range))
            levels.append(start)
        }
        #expect(levels.filter { $0 == 0 }.count == 2)
        #expect(levels.contains { abs($0 - project.descriptionDucking.volume) < 0.001 })
        #expect(levels.contains { abs($0 - 1) < 0.001 })
    }

    @Test func overlappingTakesUseSeparateTracksAndKeepInsertionTimes() {
        var project = TrimatoProject()
        let first = project.putRecording(asset(.voiceOver), at: .zero)
        let second = project.putRecording(asset(.voiceOver), at: ProjectTime(seconds: 1))
        #expect(project.tracks.filter { $0.kind == .audio }.count == 2)
        #expect(project.timelineClip(id: first)?.timelineStart == .zero)
        #expect(project.timelineClip(id: second)?.timelineStart == ProjectTime(seconds: 1))
    }

    @Test func nativeSwiftUIMicrophoneSliderRespondsToVerticalArrows() async throws {
        var latest = 50.0
        let host = NSHostingView(rootView: TestMicrophoneVolume { latest = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ element: NSObject) -> NSObject? {
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               element.value(forKey: "accessibilityIdentifier") as? String == SettingsSliderKeyboard.identifier {
                return element
            }
            guard element.responds(to: NSSelectorFromString("accessibilityChildren")),
                  let children = element.value(forKey: "accessibilityChildren") as? [NSObject] else { return nil }
            return children.lazy.compactMap(find).first
        }
        let slider = try #require(find(host))
        #expect(slider.value(forKey: "accessibilityRole") as? String == "AXSlider")
        for (key, expected) in [(UInt16(126), 51.0), (125, 50.0)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            #expect(SettingsSliderKeyboard.handle(event, focused: slider) == nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(latest == expected)
        }
    }

}

private struct TestMicrophoneVolume: View {
    @State private var value = 50.0
    let changed: (Double) -> Void
    var body: some View {
        MicrophoneVolumeSlider(value: $value).onChange(of: value) { _, value in changed(value) }
    }
}
