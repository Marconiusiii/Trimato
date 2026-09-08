import Foundation
import AVFoundation
@testable import Trimato

@main struct InterfaceSoundCheck {
    @MainActor static func main() async throws {
        let suite = "trimato-sound-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var cues: [Data] = []
        var stops = 0
        let sounds = InterfaceSounds(defaults: defaults, playback: { cues.append($0) }, stopPlayback: { stops += 1 })
        let work = VoiceAdjustmentWork(processingSound: ProcessingSound(sounds: sounds))
        work.run { try await Task.sleep(for: .milliseconds(900)) }
        try await Task.sleep(for: .seconds(1))
        precondition(cues.isEmpty, "Automatic work played a processing sound")
        work.run(soundFeedback: true) { try await Task.sleep(for: .milliseconds(900)) }
        try await Task.sleep(for: .seconds(1))
        precondition(cues.count == 1, "Explicit slow action did not play a processing sound")
        work.cancel()
        cues.removeAll()
        let quick = sounds.begin(); sounds.end(quick)
        try await Task.sleep(for: .milliseconds(750))
        precondition(cues.isEmpty, "Immediate actions played a cue")
        let first = sounds.begin(), second = sounds.begin()
        try await Task.sleep(for: .milliseconds(750))
        precondition(cues.count == 1, "Overlapping actions stacked cues")
        sounds.end(first)
        try await Task.sleep(for: .seconds(2.4))
        precondition(cues.count == 2, "Pending operation did not repeat")
        sounds.end(second)
        let count = cues.count
        try await Task.sleep(for: .milliseconds(750))
        precondition(cues.count == count && stops > 0)
        let capture = UUID()
        sounds.capture(capture, active: true)
        let suppressed = sounds.begin()
        sounds.exportCompleted()
        try await Task.sleep(for: .milliseconds(750))
        precondition(cues.count == count, "A cue leaked into capture")
        sounds.end(suppressed); sounds.capture(capture, active: false)
        defaults.set(false, forKey: AppPreferenceKey.processingSounds)
        let muted = sounds.begin()
        try await Task.sleep(for: .milliseconds(750))
        precondition(cues.count == count)
        sounds.end(muted)
        sounds.exportCompleted()
        precondition(cues.count == count + 1, "Export preference was coupled to processing sounds")
        defaults.set(false, forKey: AppPreferenceKey.exportCompletionSound)
        sounds.exportCompleted()
        precondition(cues.count == count + 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sound-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try cues.last!.write(to: url)
        let file = try AVAudioFile(forReading: url)
        precondition(file.processingFormat.sampleRate == 48000 && file.length > 0)
        print("Sound feedback: delayed onset, shared repeat, cancellation, capture suppression, independent settings, and valid PCM passed without audible playback")
    }
}
