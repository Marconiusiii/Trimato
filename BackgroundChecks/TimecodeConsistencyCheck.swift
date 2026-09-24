import AppKit
import Combine
import SwiftUI
import AVFoundation
@testable import Trimato

@main struct TimecodeConsistencyCheck {
    @MainActor static func main() async throws {
        precondition(NSApp == nil)
        setbuf(stdout, nil)
        // Volatile, process-local preferences do not modify the running app's settings.
        func preferences(_ milliseconds: Bool, _ style: TimecodeStyle = .timeUnits, _ feedback: TimecodeFeedback = .whenStopped) {
            UserDefaults.standard.setVolatileDomain([
                AppPreferenceKey.showMilliseconds: milliseconds,
                AppPreferenceKey.timecodeStyle: style.rawValue,
                AppPreferenceKey.timecodeFeedback: feedback.rawValue
            ], forName: UserDefaults.argumentDomain)
        }
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        precondition(AppPreferenceKey.showMilliseconds == AppPreferenceKey.precisionTimecode)
        let legacyName = "StoppedFeedbackMigration.\(UUID())"
        let legacy = UserDefaults(suiteName: legacyName)!
        defer { legacy.removePersistentDomain(forName: legacyName) }
        for (raw, expected) in [("live", TimecodeFeedback.whenStopped), ("off", .onDemand), ("whenStopped", .whenStopped), ("onDemand", .onDemand)] {
            legacy.set(raw, forKey: AppPreferenceKey.timecodeFeedback)
            precondition(AppPreferences.timecodeFeedback(in: legacy) == expected)
        }
        for precise in [false, true] {
            preferences(precise)
            precondition(AppPreferences.showMilliseconds() == precise)
            for (seconds, whole, exact) in [(0.0,"00:00","00:00.000"), (12.347,"00:12","00:12.347"),
                (59.999,"00:59","00:59.999"), (60.0,"01:00","01:00.000"),
                (3599.999,"59:59","59:59.999"), (3600.0,"01:00:00","01:00:00.000")] {
                let expected = precise ? exact : whole
                let time = ProjectTime(seconds: seconds)
                precondition(AppPreferences.passiveTimecode(seconds: seconds) == expected)
                precondition(ProjectTimecodeFormatter.string(time) == expected)
                let format = RecordingTimeFormat(milliseconds: precise, originalValue: seconds)
                precondition(format.format(seconds) == expected)
                let unchanged = try format.parseStrategy.parse(expected)
                precondition(abs(unchanged - seconds) < 0.000001, "Hidden fraction was discarded")
                let changed = try format.parseStrategy.parse("23.456")
                precondition(abs(changed - 23.456) < 0.000001)
                let spoken = AppPreferences.spokenTimecode(seconds: seconds, frameRate: 30)
                precondition(spoken.contains("millisecond") == (precise && seconds.truncatingRemainder(dividingBy: 1) > 0))
                precondition(ProjectInfoTimeFormatter.string(time) == spoken)
                let row = ProjectInfoRow("Position", time: time)
                precondition(row.displayValue(milliseconds: precise) == spoken)
                let decoded = try JSONDecoder().decode(ProjectInfoRow.self, from: JSONEncoder().encode(row))
                precondition(decoded.time == time)
            }
            precondition(AppPreferences.spokenTimecode(seconds: 12.347, frameRate: 30, verbosity: .short) == (precise ? "12 seconds, 347 milliseconds" : "12 seconds"))
            precondition(AppPreferences.spokenTimecode(seconds: 62.347, frameRate: 30, verbosity: .short) == (precise ? "1 minute, 2 seconds, 347 milliseconds" : "1 minute, 2 seconds"))
            precondition(AppPreferences.spokenTimecode(seconds: 1.5, frameRate: 30, verbosity: .frames) == "Frame 45")
            let point = ProjectEditPoint(time: ProjectTime(seconds: 12.347), hasVideo: true, hasAudio: false)
            let announcement = ProjectPlayerViewModel.navigationAnnouncement(destination: point.time,
                duration: ProjectTime(seconds: 20), inMarker: nil, outMarker: nil, frameRate: 30, editPoint: point)
            precondition(announcement.hasPrefix("Video edit point, "))
            precondition(announcement.contains("347 milliseconds") == precise)
        }
        precondition(AppPreferences.passiveTimecode(seconds: 3599.9996, precision: true) == "01:00:00.000")
        precondition(AppPreferences.passiveTimecode(seconds: 3599.9996, precision: false) == "59:59")
        print("PASS: visible/spoken formats, boundaries, Short/Frames, preference compatibility, exact unchanged edits and explicit fractional input")
        preferences(true)
        let project = ProjectPlayerViewModel()
        let clip = VideoPlayerViewModel()
        project.stageInsertionPlayhead(ProjectTime(seconds: 12.347), duration: ProjectTime(seconds: 60))
        clip.currentTime = 12.347
        clip.setInMarker(at: CMTime(seconds: 12.347, preferredTimescale: 1000))
        clip.setOutMarker(at: CMTime(seconds: 23.456, preferredTimescale: 1000))
        let exactIn = clip.inMarker, exactOut = clip.outMarker
        let presentation = MixerPlaybackPresentation(player: project)
        try await Task.sleep(for: .milliseconds(50))
        clip.currentTime = 12.347 // Initial AVPlayer rate delivery has now settled.
        preferences(false)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(100))
        precondition(project.accessibilityTimecodeLabel == "12 seconds")
        precondition(clip.accessibilityTimecodeLabel == "12 seconds")
        precondition(clip.inMarkerDisplay == "00:12" && clip.outMarkerDisplay == "00:23")
        precondition(!presentation.state.milliseconds)
        precondition(clip.inMarker == exactIn && clip.outMarker == exactOut)
        for style in TimecodeStyle.allCases {
            for feedback in TimecodeFeedback.allCases {
                preferences(true, style, feedback)
                project.refreshTimecodePreference(); clip.refreshTimecodePreference()
                let requested = project.currentTimecodeForAnnouncement
                precondition(!requested.isEmpty)
                precondition(project.playheadAccessibilityValue == (feedback == .whenStopped ? requested : ""))
                precondition(clip.playheadAccessibilityValue == (feedback == .whenStopped ? clip.accessibilityTimecodeLabel : ""))
                precondition(!clip.inMarkerDisplay.isEmpty && !clip.outMarkerDisplay.isEmpty)
                precondition(!ProjectInfoTimeFormatter.string(ProjectTime(seconds: 12.347)).isEmpty)
            }
        }
        preferences(false)
        project.refreshTimecodePreference(); clip.refreshTimecodePreference()
        try await Task.sleep(for: .milliseconds(50))
        precondition(FadeTransitionLabels.duration(edge: .intro) == "Fade In Duration in seconds")
        precondition(FadeTransitionLabels.duration(edge: .outro) == "Fade Out Duration in seconds")
        print("PASS: all style/feedback combinations preserve requested times and other time values; On Demand produces empty model values; fade duration units restored")
        var updates = 0
        let observation = project.objectWillChange.sink { updates += 1 }
        for tick in 1...200 { project.playbackClock.update(ProjectTime(seconds: Double(tick) / 10 + 0.123), frameRate: 30) }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(50))
        precondition(updates == 0, "Clock or unchanged preference invalidated the player")
        preferences(true)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(100))
        precondition(project.accessibilityTimecodeLabel.contains("millisecond"))
        precondition(clip.inMarkerDisplay == "00:12.347")
        precondition(clip.inMarker == exactIn && clip.outMarker == exactOut)
        withExtendedLifetime(observation) {}
        print("PASS: open player caches and Mixer state refresh on explicit preference changes; clock updates remain isolated; exact In/Out values preserved")
        for (topic, label) in [(TrimatoHelp.Topic.generalSettings,"General"), (.audioSettings,"Audio"), (.videoSettings,"Video"), (.accessibilitySettings,"Accessibility"), (.storageSettings,"Storage")] {
            precondition(SettingsHelpPage(topic: topic) { EmptyView() }.scrollAreaLabel == label)
        }
        precondition(NSApp == nil)
        print("PASS: all five Settings tab labels mapped; no application, window, audio playback or focus changes")
    }
}
