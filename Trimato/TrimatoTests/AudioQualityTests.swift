import AVFoundation
import Foundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct AudioQualityTests {
    @Test func mixingRetainsHighestRateAndRejectsUnsupportedChannels() throws {
        let selected = try AudioProcessingFormat.select([
            .init(sampleRate: 44_100, channels: 1), .init(sampleRate: 96_000, channels: 2)
        ], stereoMix: true)
        #expect(selected == .init(sampleRate: 96_000, channels: 2))
        #expect(try AudioProcessingFormat.select([.init(sampleRate: 44_100, channels: 1)]).channels == 1)
        #expect(throws: AudioProcessingError.self) {
            try AudioProcessingFormat.select([.init(sampleRate: 96_000, channels: 6)])
        }
    }

    private func fixture(in directory: URL, rate: Int = 96_000) async throws -> URL {
        let source = directory.appendingPathComponent("source-\(rate).wav")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "aevalsrc=0.000004*sin(2*PI*\(rate > 48_000 ? 30000 : 1000)*t):s=\(rate):d=1", "-c:a", "pcm_s24le", source.path
        ])
        return source
    }

    private func verifyQuietAudio(_ url: URL, rate: Int = 96_000, channels: Int = 1) async throws {
        let report = try await FFmpegMediaProbe.inspect(url: url)
        #expect(report.audioStream?.sampleRate == String(rate))
        #expect(report.audioStream?.channels == channels)
        let decoded = url.deletingLastPathComponent().appendingPathComponent("\(UUID()).f32")
        defer { try? FileManager.default.removeItem(at: decoded) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-i", url.path, "-map", "0:a:0", "-f", "f32le", decoded.path
        ])
        let data = try Data(contentsOf: decoded)
        let samples = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        #expect(abs(samples.count - rate * channels) < 4 * channels)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.000003)
        #expect(peak < 0.000005)
        #expect(samples.allSatisfy { $0.isFinite })
    }

    @Test(arguments: [44_100, 96_000])
    func filtersAndExportPreparationRetainQuietHighRateAudio(rate: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory, rate: rate)
        var filter = ClipFilter(kind: .echo)
        filter.values["amount"] = 0
        let filtered = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: true, duration: 1)
        defer { try? FileManager.default.removeItem(at: filtered) }
        try await verifyQuietAudio(filtered, rate: rate)
        let intermediate = try await ProjectRenderMediaManager.createIntermediate(
            sourceURL: filtered, duration: 1, width: nil, height: nil, hasVideo: false, hasAudio: true)
        defer { try? FileManager.default.removeItem(at: intermediate) }
        try await verifyQuietAudio(intermediate, rate: rate)
    }

    @Test(arguments: [ExportFormat.wav24, .m4aAppleLossless, .flac])
    func losslessExportRetainsQuietHighRateMono(format: ExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        let output = directory.appendingPathComponent("output.\(format.fileExtension)")
        try await AudioOnlyExporter.export(asset: AVURLAsset(url: source), audioMix: nil, timeRange: nil,
                                           format: format, to: output, progress: { _ in })
        try await verifyQuietAudio(output)
    }

    @Test func projectFilteringAndStereoMixRetainHighRatePrecision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        var project = TrimatoProject(name: "Audio quality")
        let record = MediaAssetRecord(name: "Quiet", originalPath: source.path,
                                      duration: ProjectTime(seconds: 1), hasAudio: true,
                                      sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
        let id = project.putRecording(record, at: .zero)
        var filter = ClipFilter(kind: .echo)
        filter.values["amount"] = 0
        try project.setClipEffects(id: id, audio: .neutral, filters: [filter])
        let output = directory.appendingPathComponent("project.wav")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: source],
                                          format: .wav24, to: output, progress: { _ in })
        try await verifyQuietAudio(output, channels: 2)
    }
    @Test func highRateTransitionPreservesMonoAndExactDuration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
        let leading = TimelineClip(assetID: UUID(), name: "Leading", segments: [segment])
        let trailing = TimelineClip(assetID: UUID(), name: "Trailing", segments: [segment])
        let output = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
            leadingURL: source, trailingURL: source, leadingClip: leading, trailingClip: trailing,
            type: .crossFade, duration: ProjectTime(seconds: 0.2))
        defer { try? FileManager.default.removeItem(at: output) }
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(report.audioStream?.sampleRate == "96000")
        #expect(report.audioStream?.channels == 1)
        #expect(report.audioStream?.sampleFormat == "flt")
        #expect(abs(report.duration - 0.2) < 1.0 / 96_000)
    }

}
