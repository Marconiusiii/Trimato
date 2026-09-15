import AppKit
import AVFoundation
@testable import Trimato

/// Paused seeks only: never calls play, sets a nonzero rate, or creates NSApplication.
@main struct StoppedPlayheadCheck {
    @MainActor static func main() async throws {
        precondition(NSApp == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silent.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for frame in 0..<48000 { buffer.floatChannelData![0][frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let clip = VideoPlayerViewModel()
        clip.duration = 1
        clip.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let project = ProjectPlayerViewModel()
        project.stageInsertionPlayhead(.zero, duration: ProjectTime(seconds: 1))
        project.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while clip.player.currentItem?.status != .readyToPlay || project.player.currentItem?.status != .readyToPlay {
            precondition(ContinuousClock.now < deadline, "Paused test assets did not become ready")
            try await Task.sleep(for: .milliseconds(20))
        }
        for position in [0.2, 0.7, 0.3] {
            let oldClipValue = clip.accessibilityTimecodeLabel
            let oldProjectValue = project.accessibilityTimecodeLabel
            clip.seek(to: position)
            project.seek(to: ProjectTime(seconds: position))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            // Do not request a focus refresh: completed seeks must update values themselves.
            while abs(clip.currentTime - position) > 0.001 ||
                  abs(project.currentTime.seconds - position) > 0.001 ||
                  clip.accessibilityTimecodeLabel == oldClipValue ||
                  project.accessibilityTimecodeLabel == oldProjectValue {
                precondition(ContinuousClock.now < deadline, "A paused seek left a stale clock or accessible value")
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(clip.accessibilityTimecodeLabel == AppPreferences.spokenTimecode(seconds: clip.currentTime, frameRate: 30))
            precondition(project.accessibilityTimecodeLabel == project.currentTimecodeForAnnouncement)
            precondition(clip.player.rate == 0 && project.player.rate == 0)
        }
        // Rapid replacement seeks must leave both models on the latest request.
        for position in [0.2, 0.8, 0.4] {
            clip.seek(to: position)
            project.seek(to: ProjectTime(seconds: position))
        }
        let seekDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while abs(clip.currentTime - 0.4) > 0.001 || abs(project.currentTime.seconds - 0.4) > 0.001 {
            precondition(ContinuousClock.now < seekDeadline, "Rapid seeks lost the latest target")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(abs(clip.currentTime - 0.4) < 0.001 && abs(project.currentTime.seconds - 0.4) < 0.001)
        precondition(clip.accessibilityTimecodeLabel == AppPreferences.spokenTimecode(seconds: clip.currentTime, frameRate: 30))
        precondition(project.accessibilityTimecodeLabel == project.currentTimecodeForAnnouncement)
        let stopped = clip.accessibilityTimecodeLabel
        clip.currentTime = 0 // Simulate a stale display tick without changing the actual paused position.
        clip.isPlaying = true // Simulate the published rate notification arriving late.
        clip.refreshAccessibilityValueForFocus()
        precondition(clip.accessibilityTimecodeLabel == stopped && abs(clip.currentTime - 0.4) < 0.001)
        precondition(NSApp == nil && clip.player.rate == 0 && project.player.rate == 0)
        print("PASS: forward and backward paused seeks refresh both editors without focus changes; actual stopped position overrides stale display state; no playback or application created")
    }
}
