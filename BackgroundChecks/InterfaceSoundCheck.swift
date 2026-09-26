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
        let completion = cues.last!
        let completionURL = FileManager.default.temporaryDirectory.appendingPathComponent("completion-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: completionURL) }
        try completion.write(to: completionURL)
        let completionFile = try AVAudioFile(forReading: completionURL)
        precondition(completionFile.processingFormat.sampleRate == 48000)
        precondition(completionFile.processingFormat.channelCount == 1)
        let duration = Double(completionFile.length) / completionFile.processingFormat.sampleRate
        precondition((1.15...1.25).contains(duration), "Completion cue is too long or short")
        let buffer = AVAudioPCMBuffer(pcmFormat: completionFile.processingFormat,
            frameCapacity: AVAudioFrameCount(completionFile.length))!
        try completionFile.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        precondition(samples.allSatisfy { $0.isFinite })
        let peak = samples.map { abs($0) }.max()!
        precondition((0.38...0.42).contains(peak), "Completion cue level changed or clipped")
        precondition(samples.first == 0 && abs(samples.last!) < 0.0001, "Abrupt waveform boundary")
        let largestStep = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max()!
        precondition(largestStep < 0.105, "Completion cue has a discontinuity")
        func rms(from start: Double, to end: Double) -> Double {
            let region = samples[Int(start * 48000)..<Int(end * 48000)]
            return sqrt(region.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(region.count))
        }
        let sustain = rms(from: 0.7, to: 0.85)
        let tail = rms(from: 1.0, to: 1.15)
        precondition(sustain > 0.002, "Final note loses its sustain too early")
        precondition(tail > 0.0001 && tail < sustain * 0.4, "Final note does not dissipate gently")
        // Optional preview is the exact data supplied to playback, never played by this check.
        if let preview = ProcessInfo.processInfo.environment["TRIMATO_EXPORT_SOUND_PREVIEW"] {
            try completion.write(to: URL(fileURLWithPath: preview))
        }
        print("Completion PCM: \(duration) seconds, peak \(peak), smooth boundaries, no clipping")
        defaults.set(false, forKey: AppPreferenceKey.exportCompletionSound)
        sounds.exportCompleted()
        precondition(cues.count == count + 1)
        let beforeMarker = cues.count
        sounds.markerCreated()
        precondition(cues.count == beforeMarker + 1, "Marker feedback was coupled to other sound settings")
        defaults.set(false, forKey: AppPreferenceKey.markerAudio)
        sounds.markerCreated()
        precondition(cues.count == beforeMarker + 1, "Marker audio setting was ignored")
        defaults.set(true, forKey: AppPreferenceKey.markerAudio)
        sounds.capture(capture, active: true)
        sounds.markerCreated()
        precondition(cues.count == beforeMarker + 1, "Marker cue leaked into capture")
        sounds.capture(capture, active: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sound-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try cues.last!.write(to: url)
        let file = try AVAudioFile(forReading: url)
        precondition(file.processingFormat.sampleRate == 48000 && file.length > 0)
        print("Sound feedback: delayed onset, shared repeat, cancellation, capture suppression, independent settings, and valid PCM passed without audible playback")
    }
}
