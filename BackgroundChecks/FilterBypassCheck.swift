import AVFoundation
import Foundation
@testable import Trimato

@main struct FilterBypassCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("voice.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let amplitude = index < 96000 ? 0.03 : 0.18
            buffer.floatChannelData![0][index] = Float(amplitude * sin(2 * .pi * 440 * Double(index) / 48000))
        }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let legacy = try JSONDecoder().decode(VoiceAdjustment.self,
            from: Data(#"{"targetLoudness":-23,"referenceStart":0,"referenceEnd":5,"evenOut":true,"level":0}"#.utf8))
        precondition(legacy.matchingActive && legacy.smoothingActive)
        var bypassed = legacy
        bypassed.matchingBypassed = true
        bypassed.smoothingBypassed = true
        let saved = try JSONEncoder().encode(bypassed)
        let restored = try JSONDecoder().decode(VoiceAdjustment.self, from: saved)
        precondition(restored == bypassed && !restored.isActive)
        precondition(restored.targetLoudness == -23 && restored.evenOut)
        let baseline = try await VoiceAudioProcessor.measure(source)
        let quiet = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.5), duration: ProjectTime(seconds: 1)))]
        let loud = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 2.5), duration: ProjectTime(seconds: 1)))]
        let originalDifference = try await VoiceAudioProcessor.measure(source, segments: loud) - VoiceAudioProcessor.measure(source, segments: quiet)
        for enabled in [false, true] {
            var voice = restored
            voice.matchingBypassed = !enabled
            voice.smoothingBypassed = !enabled
            for highPrecision in [false, true] {
                let output = try await ClipFilterRenderer.render(source: source, filters: [], audio: true,
                    duration: 4, audioSettings: AudioClipSettings(voice: voice), highPrecision: highPrecision)
                defer { try? FileManager.default.removeItem(at: output) }
                let level = try await VoiceAudioProcessor.measure(output)
                let difference = try await VoiceAudioProcessor.measure(output, segments: loud) - VoiceAudioProcessor.measure(output, segments: quiet)
                if enabled {
                    precondition(abs(level - (-23)) < 0.6, "Enabled matching did not reach its saved target")
                    precondition(difference < originalDifference - 0.5, "Enabled smoothing did not reduce the level difference")
                } else {
                    precondition(abs(level - baseline) < 0.3, "Disabled matching changed loudness")
                    precondition(abs(difference - originalDifference) < 0.3, "Disabled smoothing changed dynamics")
                }
            }
        }
        print("Legacy decoding, saved bypass states, retained settings, and enabled/disabled matching and smoothing passed in standard and high-precision renders. No audio was played.")
    }
}
