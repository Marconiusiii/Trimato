import AppKit
import AVFoundation
@testable import Trimato

@main struct MixerWaveformTimingCheck {
    @MainActor static func main() async throws {
        precondition(NSApp == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("impulse.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<2 {
            for frame in 0..<48000 {
                buffer.floatChannelData![channel][frame] = (12000..<12480).contains(frame) ? 0.5 : 0
            }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buffer) }
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
        let primary = MediaAssetRecord(name: "Primary", originalPath: url.path, duration: ProjectTime(seconds: 1),
            hasAudio: true, sourceEdit: [segment], playbackMode: .nativePassthrough)
        var description = primary
        description.id = UUID()
        description.name = "Description"
        description.recordingPurpose = .audioDescription
        let showClip = TimelineClip(assetID: primary.id, name: "Primary", segments: [segment])
        var descriptionClip = TimelineClip(assetID: description.id, name: "Description", segments: [segment])
        descriptionClip.timelineStart = ProjectTime(seconds: 1)
        var project = TrimatoProject(name: "Offline synchronization check")
        project.media = [primary, description]
        project.tracks = [TimelineTrack(name: "Primary", kind: .audio, clips: [showClip]),
            TimelineTrack(name: "Description", kind: .audio, clips: [descriptionClip])]
        let urls = [primary.id: url, description.id: url]
        let before = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        let first = try await AudioWaveformAnalyzer.analyzeProject(asset: before.playbackAsset, audioMix: before.audioMix)
        project.tracks[1].mix.volumeDB = -6
        project.tracks[0].mix.pan = -0.2
        let after = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        let second = try await AudioWaveformAnalyzer.analyzeProject(asset: after.playbackAsset, audioMix: after.audioMix)
        let descriptionBucket = Int(1.25 / second.duration * Double(second.samples.count))
        let descriptionPeak = second.samples[max(descriptionBucket - 2, 0)..<min(descriptionBucket + 16, second.samples.count)].max() ?? 0
        precondition(descriptionPeak < 0.8 && descriptionPeak > 0.3, "Waveform ignored the description track mix")
        // Updating the existing processing taps must also preserve track timing.
        for processor in before.mixProcessors {
            processor.update(StereoMixMatrix(ll: 0.5, lr: 0, rl: 0, rr: 0.5))
        }
        let updated = try await AudioWaveformAnalyzer.analyzeProject(asset: before.playbackAsset, audioMix: before.audioMix)
        for waveform in [first, second, updated] {
            precondition(abs(waveform.duration - 2) < 0.001)
            let active = waveform.samples.enumerated().filter { $0.element > 0.1 }.map { Double($0.offset) / Double(waveform.samples.count) * waveform.duration }
            precondition(active.contains { abs($0 - 0.25) < 0.02 }, "Primary impulse missing or shifted")
            precondition(active.contains { abs($0 - 1.25) < 0.02 }, "Description impulse missing or shifted")
            precondition(active.allSatisfy { abs($0 - 0.25) < 0.02 || abs($0 - 1.25) < 0.02 }, "Audio drift outside expected ranges")
        }
        precondition(NSApp == nil)
        print("PASS: full-project waveform contains both tracks, impulse alignment survives rebuilt and in-place mix changes; offline decoding only")
    }
}
