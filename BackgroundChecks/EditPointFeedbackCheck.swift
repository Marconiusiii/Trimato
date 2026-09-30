import AppKit
import AVFoundation
@testable import Trimato

/// Exercises the real command handler and AVPlayer seeks without windows or audible output.
@main struct EditPointFeedbackCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        let url = directory.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        func time(_ seconds: Double) -> ProjectTime { ProjectTime(seconds: seconds) }
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: time(8)))
        let asset = MediaAssetRecord(name: "Silent fixture", originalPath: url.path, duration: time(8),
            naturalWidth: 0, naturalHeight: 0, frameRate: 30, hasAudio: true,
            sourceEdit: [segment], playbackMode: .nativePassthrough)
        let clips = (0..<4).map { index in
            TimelineClip(assetID: asset.id, name: "Clip \(index + 1)",
                segments: [SourceSegment(sourceRange: ProjectTimeRange(start: time(Double(index * 2)), duration: time(2)))],
                timelineStart: time(Double(index * 2)))
        }
        let audio = TimelineTrack(name: "Audio", kind: .audio, role: .primaryAudio, clips: clips)
        var document = TrimatoProject(name: "Edit feedback check")
        document.media = [asset]
        document.tracks = [audio]
        var messages: [String] = []
        var positions: [Double] = []
        var model: ProjectPlayerViewModel!
        model = ProjectPlayerViewModel(announcementHandler: { message in
            messages.append(message)
            positions.append(model.player.currentTime().seconds)
        })
        model.player.volume = 0
        model.player.isMuted = true
        model.scopeKeyboardCommands(to: { true })
        model.prepare(project: document, mediaURLs: [asset.id: url])
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !condition() {
                precondition(ContinuousClock.now < deadline, "Timed out: \(String(describing: model.errorMessage))")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait { model.canControlPlayback }
        func press(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
            precondition(model.handleEditorKeyEvent(event) == nil, "Command was not handled")
        }
        func reset() async throws {
            model.seek(to: .zero)
            try await wait { abs(model.player.currentTime().seconds) < 0.001 }
            try await Task.sleep(for: .milliseconds(100))
            messages.removeAll(); positions.removeAll()
        }
        for feedback in TimecodeFeedback.allCases {
            UserDefaults.standard.setVolatileDomain([
                AppPreferenceKey.timecodeFeedback: feedback.rawValue,
                AppPreferenceKey.timecodeStyle: TimecodeStyle.timeUnits.rawValue,
                AppPreferenceKey.showMilliseconds: false
            ], forName: UserDefaults.argumentDomain)
            model.refreshTimecodePreference()
            for kind in [TimelineTrackKind.video, .audio, .markers] {
                let track = TimelineTrack(name: "Points", kind: kind, clips: kind == .markers ? [] : clips,
                    markers: kind == .markers ? [TimelineMarker(index: 1, time: time(2), title: "Marker 1"),
                        TimelineMarker(index: 2, time: time(4), title: "Marker 2")] : [])
                var navigation = document
                navigation.tracks.append(track)
                model.selectEditPointTrack(track.id, in: navigation)
                try await reset()
                let label = kind == .video ? "Video edit point: Clip 2" : kind == .audio ? "Audio edit point: Clip 2" : "Marker 1"
                press(124)
                precondition(messages.isEmpty, "Announced before seek completion")
                try await wait { messages.count == 1 }
                precondition(messages[0] == label + (feedback == .whenStopped ? ", 2 seconds" : ""), "Wrong feedback: \(messages)")
                precondition(abs(positions[0] - 2) < 0.001, "Announced at the old position")
                precondition(!model.announcesPlayheadValueChanges, "Jump also requested slider feedback")
                try await Task.sleep(for: .milliseconds(350))
                precondition(messages.count == 1, "Duplicate announcement")
                // Multiple commands before the main actor can deliver seek completions.
                messages.removeAll(); positions.removeAll()
                press(124); press(123)
                precondition(messages.isEmpty, "Rapid jump announced synchronously")
                try await wait { messages.count == 1 }
                precondition(abs(positions[0] - 2) < 0.001 && messages[0].hasPrefix(label), "Superseded jump spoke")
                messages.removeAll()
                press(123)
                try await wait { messages.count == 1 }
                precondition(messages[0] == (feedback == .whenStopped ? "Start, 0 seconds" : "Start"))
                messages.removeAll()
                press(124)
                model.seek(to: time(1))
                try await wait { abs(model.player.currentTime().seconds - 1) < 0.001 }
                try await Task.sleep(for: .milliseconds(350))
                precondition(messages.isEmpty, "Cancelled jump spoke after a different seek")
                precondition(model.announcesPlayheadValueChanges, "Ordinary seeks lost slider feedback")
            }
        }
        for feedback in TimecodeFeedback.allCases {
            UserDefaults.standard.setVolatileDomain([
                AppPreferenceKey.timecodeFeedback: feedback.rawValue,
                AppPreferenceKey.timecodeStyle: TimecodeStyle.timeUnits.rawValue,
                AppPreferenceKey.showMilliseconds: false
            ], forName: UserDefaults.argumentDomain)
            model.refreshTimecodePreference()
            let cases: [(TimelineTrackKind, TimelineTrackRole, RecordingPurpose?, String)] = [
                (.video, .primaryVideo, nil, "Video edit point"),
                (.audio, .primaryAudio, nil, "Audio edit point"),
                (.video, .additional, nil, "Video edit point"),
                (.audio, .additional, nil, "Audio edit point"),
                (.audio, .additional, .voiceOver, "Voice over"),
                (.audio, .additional, .audioDescription, "Audio description")
            ]
            for (kind, role, purpose, prefix) in cases {
                for identifyByTrack in (purpose == nil ? [false] : [false, true]) {
                    var descriptionAsset = asset
                    descriptionAsset.id = UUID()
                    descriptionAsset.recordingPurpose = identifyByTrack ? nil : purpose
                    func description(_ name: String, _ start: Double, _ duration: Double, renamed: String? = nil) -> TimelineClip {
                        TimelineClip(assetID: descriptionAsset.id, name: name,
                            segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: time(duration)))],
                            customName: renamed, timelineStart: time(start))
                    }
                    let first = description("Door opens", 1, 1)
                    let second = description("Original name", 2, 2, renamed: "Cat enters")
                    let third = description("Cat rests", 5, 1)
                    let track = TimelineTrack(name: "Named clips", kind: kind, role: role,
                        clips: [third, second, first], recordingPurpose: identifyByTrack ? purpose : nil)
                    var navigation = document
                    navigation.media.append(descriptionAsset)
                    navigation.tracks.append(track)
                    let points = ProjectPlayerViewModel.editPoints(in: navigation, trackID: track.id)
                    let expected: [(Double, String)] = [(1, "Door opens"), (2, "Cat enters"),
                        (4, "Cat enters"), (5, "Cat rests"), (6, "Cat rests")]
                    for (seconds, name) in expected {
                        precondition(points.first { $0.time == time(seconds) }?.spokenName == "\(prefix): \(name)")
                    }
                    model.selectEditPointTrack(track.id, in: navigation)
                    try await reset()
                    for (seconds, name) in expected {
                        messages.removeAll(); positions.removeAll()
                        press(124)
                        try await wait { messages.count == 1 }
                        precondition(messages[0] == "\(prefix): \(name)" +
                            (feedback == .whenStopped ? ", \(Int(seconds)) \(seconds == 1 ? "second" : "seconds")" : ""), "Wrong description: \(messages)")
                        precondition(abs(positions[0] - seconds) < 0.001)
                    }
                    messages.removeAll()
                    press(123)
                    try await wait { messages.count == 1 }
                    precondition(messages[0].hasPrefix("\(prefix): Cat rests"))
                    // A user rename must reach the next navigation snapshot.
                    navigation.tracks[navigation.tracks.count - 1].clips[1].customName = "Cat returns"
                    model.selectEditPointTrack(track.id, in: navigation)
                    messages.removeAll()
                    press(123)
                    try await wait { messages.count == 1 }
                    precondition(messages[0].hasPrefix("\(prefix): Cat returns"))
                    for (seconds, name) in [(2.0, "Cat returns"), (1.0, "Door opens")] {
                        messages.removeAll(); positions.removeAll()
                        press(123)
                        try await wait { messages.count == 1 }
                        precondition(messages[0].hasPrefix("\(prefix): \(name)") &&
                            abs(positions[0] - seconds) < 0.001, "Backward cut chose the outgoing clip")
                    }
                    if !identifyByTrack, purpose != nil {
                        var mixed = navigation
                        mixed.tracks[mixed.tracks.count - 1].clips[1].assetID = asset.id
                        precondition(ProjectPlayerViewModel.editPoints(in: mixed, trackID: track.id)
                            .first { $0.time == time(2) }?.spokenName == "Audio edit point: Cat returns",
                            "Description name leaked into the ordinary audio clip beginning at the cut")
                    }
                }
            }
        }
        var labeled = clips[0]
        labeled.labelOrdinal = 1
        var next = clips[1]
        next.customName = "Incoming clip"
        var legacy = TrimatoProject(name: "Legacy timeline")
        legacy.tracks = []
        legacy.primaryTimeline = [labeled, next]
        let legacyPoints = ProjectPlayerViewModel.editPoints(in: legacy)
        precondition(legacyPoints.first { $0.time == .zero }?.spokenName == "Video edit point: Clip 1 B")
        precondition(legacyPoints.first { $0.time == time(2) }?.spokenName == "Video edit point: Incoming clip")
        let captions = TimelineTrack(name: "Captions", kind: .captions,
            captionCues: [CaptionCue(start: time(2), end: time(4), text: "The door opens")])
        var captionProject = document
        captionProject.tracks.append(captions)
        precondition(ProjectPlayerViewModel.editPoints(in: captionProject, trackID: captions.id)
            .first { $0.time == time(2) }?.spokenName == "Caption: The door opens")
        print("PASS: primary and added video/audio tracks, Voicer and descriptions; track and asset identification; displayed and renamed names; shared cuts independent of storage order; gaps and ends; real commands in both modes; caption labels preserved")
        precondition(model.player.rate == 0 && NSApp.windows.isEmpty && !NSApp.isActive)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Foreground changed")
        print("PASS: actual Command+Left/Right dispatch and paused AVPlayer seeks; video, audio and marker feedback in both modes; completion-only speech; rapid replacement and cancellation; ordinary slider feedback restored. No windows, activation or audio.")
    }
}
