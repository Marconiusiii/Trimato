import AppKit
import AVFoundation
@testable import Trimato

/// Constructs a composition from a synthetic file; never plays or renders audio.
@main struct AbsoluteCompositionCheck {
    @MainActor static func main() async throws {
        precondition(NSApp == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
        buffer.frameLength = 96000
        for channel in 0..<2 { for frame in 0..<96000 { buffer.floatChannelData![channel][frame] = 0 } }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buffer) }
        for purpose: RecordingPurpose in [.audioDescription, .voiceOver] {
            let whole = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))
            var asset = MediaAssetRecord(name: "Recording", originalPath: url.path, duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: [whole], playbackMode: .nativePassthrough)
            asset.recordingPurpose = purpose
            var project = TrimatoProject(name: "Absolute composition")
            project.media = [asset]
            let clips = [10.0, 30, 60].map { TimelineClip(assetID: asset.id, name: "Recording", segments: [whole], timelineStart: ProjectTime(seconds: $0)) }
            project.tracks = [TimelineTrack(name: "Recorded audio", kind: .audio, clips: clips, recordingPurpose: purpose)]
            try project.updateTrackClip(id: clips[0].id, segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
            let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [asset.id: url])
            defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
            var intervals: [(Double, Double)] = []
            for track in try await result.composition.loadTracks(withMediaType: .audio) {
                for segment in try await track.load(.segments) where !segment.isEmpty {
                    intervals.append((segment.timeMapping.target.start.seconds, segment.timeMapping.target.duration.seconds))
                }
            }
            intervals.sort { $0.0 < $1.0 }
            precondition(intervals.count == 3)
            for (actual, expected) in zip(intervals, [(10.0, 1.0), (30.0, 2.0), (60.0, 2.0)]) {
                precondition(abs(actual.0 - expected.0) < 0.001 && abs(actual.1 - expected.1) < 0.001, "Composition changed absolute recording timing")
            }
            print("PASS: \(purpose.rawValue) composition retains starts 10, 30, 60 after shortening the first recording; no playback")
        }
        precondition(NSApp == nil)
    }
}
