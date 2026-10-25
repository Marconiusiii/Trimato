import AVFoundation
import CoreImage
import Darwin
import Testing
@testable import Trimato

/// Fixed disposable workloads, run in Release before and after media-engine changes.
@MainActor
@Suite(.serialized)
struct FasterPerformanceTests {
    @Test func mediaWorkloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-performance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var metrics: [String: Double] = [:]
        func elapsed(_ start: ContinuousClock.Instant) -> Double {
            let value = start.duration(to: .now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
        let folder = root.appendingPathComponent("import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2_000 { try Data().write(to: folder.appendingPathComponent("clip-\(index).mov")) }
        var start = ContinuousClock.now
        let discovery = try await ProjectImportCoordinator.discover(folder)
        #expect(discovery.media.count == 2_000)
        #expect(discovery.captions.isEmpty)
        metrics["folder_discovery_seconds"] = elapsed(start)

        let video = root.appendingPathComponent("source.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=640x360:rate=60:duration=60", "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000:duration=60",
            "-c:v", "mpeg4", "-q:v", "6", "-c:a", "pcm_s16le", "-shortest", video.path])
        start = .now
        let index = try await FFmpegMediaProbe.frameTimestamps(url: video, duration: 60)
        metrics["frame_index_cold_seconds"] = elapsed(start)
        #expect(index.count == 3_600)
        start = .now
        let warm = try await FFmpegMediaProbe.frameTimestamps(url: video, duration: 60)
        metrics["frame_index_warm_seconds"] = elapsed(start)
        #expect(warm == index)
        start = .now
        let windows = FrameWindowIndex(asset: AVURLAsset(url: video), duration: CMTime(seconds: 60, preferredTimescale: 600))
        let frameTarget = try await windows.target(from: .zero, forward: true, count: 1)
        metrics["first_frame_window_seconds"] = elapsed(start)
        #expect(abs(frameTarget.seconds - 1.0 / 60) < 0.00001)
        start = .now
        var stepped = frameTarget
        for _ in 0..<200 { stepped = try await windows.target(from: stepped, forward: true, count: 1) }
        metrics["frame_window_200_steps_seconds"] = elapsed(start)
        #expect(abs(stepped.seconds - 201.0 / 60) < 0.00001)
        start = .now
        _ = try await windows.target(from: CMTime(seconds: 55, preferredTimescale: 600), forward: true, count: 1)
        metrics["late_frame_window_seconds"] = elapsed(start)

        let largeIndex = (0..<432_000).map { CMTime(value: Int64($0), timescale: 120) }
        start = .now
        var total = 0
        for offset in 0..<200 {
            let time = largeIndex[400_000 + offset]
            total += FrameTimestampSearch.firstAfter(time, in: largeIndex) ?? 0
        }
        metrics["frame_lookup_200_seconds"] = elapsed(start)
        #expect(total > 0)

        let fixture = AudioEditorRevisionTests()
        let audio = try fixture.fixture(duration: 60) { Float(0.1 * sin(2 * .pi * 220 * $0)) }
        defer { try? FileManager.default.removeItem(at: audio) }
        let record = MediaAssetRecord(name: "Long source", originalPath: audio.path,
            duration: ProjectTime(seconds: 60), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 60)))],
            playbackMode: .nativePassthrough)
        var project = TrimatoProject()
        project.media = [record]
        let clipID = try project.append(asset: record, segments: [SourceSegment(sourceRange:
            ProjectTimeRange(start: ProjectTime(seconds: 45), duration: ProjectTime(seconds: 2)))])
        try project.setClipEffects(id: clipID, audio: nil, filters: [ClipFilter(kind: .reverb)])
        start = .now
        for _ in 0..<2 {
            let (_, _, files) = try await ClipFilterRenderer.prepare(project: project, urls: [record.id: audio])
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        metrics["filtered_project_two_preparations_seconds"] = elapsed(start)

        start = .now
        let output = root.appendingPathComponent("excerpt.mov")
        try await FFmpegClipExporter.export(sourceURL: video,
            sourceRanges: [CMTimeRange(start: CMTime(seconds: 55, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))],
            hasAudio: true, format: .proRes422LT, to: output, progress: { _ in })
        metrics["late_excerpt_export_seconds"] = elapsed(start)
        var editingUsage = rusage(); getrusage(RUSAGE_SELF, &editingUsage)
        metrics["editing_host_peak_resident_bytes"] = Double(editingUsage.ru_maxrss)
        // Compare a native GPU prototype with the existing SDR filter pipeline before choosing a live-preview path.
        let silent = root.appendingPathComponent("silent.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-i", video.path,
            "-map", "0:v:0", "-c:v", "copy", silent.path])
        let filter = ClipFilter(kind: .blackAndWhite)
        let selection = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        start = .now
        let software = try await ClipFilterRenderer.render(source: silent, filters: [filter], audio: false, duration: 60,
            segments: [SourceSegment(sourceRange: ProjectTimeRange(selection))])
        defer { try? FileManager.default.removeItem(at: software) }
        metrics["sdr_software_filter_seconds"] = elapsed(start)
        start = .now
        let native = root.appendingPathComponent("native-filter.mov")
        let nativeAsset = AVURLAsset(url: silent)
        let nativeContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false
        ])
        let nativeComposition = AVMutableVideoComposition(asset: nativeAsset, applyingCIFiltersWithHandler: { request in
            request.finish(with: HDRVideoRenderer.apply(filter, to: request.sourceImage), context: nativeContext)
        })
        nativeComposition.renderSize = CGSize(width: 640, height: 360)
        nativeComposition.frameDuration = CMTime(value: 1, timescale: 60)
        VideoColorPolicy.sdr.apply(to: nativeComposition)
        try await CustomMovieExporter.export(asset: nativeAsset, videoComposition: nativeComposition, audioMix: nil,
            timeRange: selection, format: .proRes422LT, to: native, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: native) }
        metrics["sdr_native_gpu_filter_seconds"] = elapsed(start)
        func pixels(_ url: URL) async throws -> Data {
            try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-i", url.path,
                "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]).standardOutput
        }
        let cpuPixels = try await pixels(software)
        let gpuPixels = try await pixels(native)
        #expect(cpuPixels.count == gpuPixels.count && !cpuPixels.isEmpty)
        metrics["sdr_native_software_mean_pixel_difference"] = zip(cpuPixels, gpuPixels).reduce(0.0) {
            $0 + Double(abs(Int($1.0) - Int($1.1)))
        } / Double(max(cpuPixels.count, 1))

        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        metrics["host_peak_resident_bytes"] = Double(usage.ru_maxrss)
        var children = rusage(); getrusage(RUSAGE_CHILDREN, &children)
        metrics["child_peak_resident_bytes"] = Double(children.ru_maxrss)
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-faster-benchmark.json")
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: report)
        Attachment.record(Array(data), named: "trimato-performance.json")
        print("Trimato performance report: \(report.path)\n\(metrics)")
    }
}
