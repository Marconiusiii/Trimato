import AVFoundation
import Foundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct IPhoneMediaTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("appStore/test_videos")
    static let available = FileManager.default.fileExists(atPath: sources.appendingPathComponent("4K_30fps.MOV").path)

    @Test(.enabled(if: available), arguments: ["4K_30fps.MOV", "4K_60fps.mov", "4K_120fps.MOV"])
    func spatialAudioRecordingsExportHDR(name: String) async throws {
        let source = Self.sources.appendingPathComponent(name)
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count >= 2)
        let selected = try #require(try await AudioProcessingFormat.selectedTrack(in: asset))
        let audio = try await AudioProcessingFormat.inspect(tracks: [selected], stereoMix: false)
        #expect(audio.channels == 2)
        #expect(audio.sampleRate == 48_000)
        let project = try await project(source: source, selectionDuration: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-iphone-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(name + "-HDR.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source],
            format: .hevcMovie, to: output, progress: { _ in }, preserveHDR: true)
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(report.videoStream?.colorTransfer == "arib-std-b67")
        #expect(report.videoStream?.pixelFormat == "yuv420p10le")
        #expect(report.videoStream?.colorPrimaries == "bt2020")
        #expect(report.videoStream?.width == project.format.width)
        #expect(report.videoStream?.height == project.format.height)
        #expect(report.videoStream?.sideData?.contains { $0.dolbyVisionProfile == 8 } == true)
        #expect(report.audioStream?.channels == 2)
        #expect(abs(report.duration - project.duration.seconds) < 0.1)
    }

    @Test(.enabled(if: available))
    func explicitSDRAndProResExports() async throws {
        let source = Self.sources.appendingPathComponent("4K_30fps.MOV")
        let project = try await project(source: source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-iphone-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (format, hdr) in [(ExportFormat.h264MP4, false), (.proRes422LT, true), (.proRes422, true), (.proRes422HQ, true)] {
            let output = directory.appendingPathComponent("4K_30-\(format.rawValue).\(format.fileExtension)")
            try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source],
                format: format, to: output, progress: { _ in }, preserveHDR: hdr)
            let report = try await FFmpegMediaProbe.inspect(url: output)
            #expect(report.videoStream?.colorTransfer == (hdr ? "arib-std-b67" : "bt709"))
            #expect(report.videoStream?.width == 3840)
            if hdr { #expect(report.audioStream?.sampleFormat == "s32") }
        }
    }

    @Test func hdrSettingsDefaultAndFormatValidation() throws {
        let name = "HDR-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences.preserveHDR(in: defaults))
        defaults.set(false, forKey: AppPreferenceKey.preserveHDR)
        #expect(!AppPreferences.preserveHDR(in: defaults))
        #expect(throws: ProjectExporter.ExportError.self) { try VideoColorPolicy.hlg.validate(format: .h264MP4) }
        try VideoColorPolicy.hlg.validate(format: .hevcMovie)
    }

    @Test(.enabled(if: available))
    func hdrFiltersTransitionsAndCaptionsRetainColor() async throws {
        let source = Self.sources.appendingPathComponent("4K_30fps.MOV")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-iphone-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filter = ClipFilter(kind: .brightnessContrast)
        let filtered = try await HDRVideoRenderer.render(source: source, filters: [filter])
        defer { try? FileManager.default.removeItem(at: filtered) }
        let filteredReport = try await FFmpegMediaProbe.inspect(url: filtered)
        #expect(filteredReport.videoStream?.colorTransfer == "arib-std-b67")
        #expect(filteredReport.videoStream?.pixelFormat == "yuv422p10le")
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 1)))
        let leading = TimelineClip(assetID: UUID(), name: "Leading", segments: [segment])
        let trailing = TimelineClip(assetID: UUID(), name: "Trailing", segments: [segment])
        let transition = try await FFmpegTimelineEffectRenderer.renderVideoTransition(
            leadingURL: source, trailingURL: filtered, leadingClip: leading, trailingClip: trailing,
            type: .crossDissolve, duration: ProjectTime(seconds: 0.4), width: 3840, height: 2160, frameRate: 30)
        defer { try? FileManager.default.removeItem(at: transition) }
        let transitionReport = try await FFmpegMediaProbe.inspect(url: transition)
        #expect(transitionReport.videoStream?.colorTransfer == "arib-std-b67")
        #expect(transitionReport.videoStream?.pixelFormat == "yuv422p10le")
        #expect(try await VideoColorPolicy.resolve(asset: AVURLAsset(url: transition), preserveHDR: true) == .hlg)
        var project = try await project(source: source)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Fresh cuts")])
        let output = directory.appendingPathComponent("4K_30-HDR-captions.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source],
            format: .hevcMovie, to: output, progress: { _ in }, preserveHDR: true)
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(report.videoStream?.colorTransfer == "arib-std-b67")
        #expect(report.videoStream?.colorPrimaries == "bt2020")
        #expect(report.videoStream?.pixelFormat == "yuv420p10le")
    }

    @Test func brightHDRRampSurvivesNeutralFilterAndCaptionExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ramp.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "nullsrc=s=1280x720:r=30:d=1,format=yuv420p10le,geq=lum='640+300*X/W':cb=512:cr=512,setparams=range=limited:color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc",
            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", source.path])
        let filtered = try await HDRVideoRenderer.render(source: source, filters: [ClipFilter(kind: .brightnessContrast)])
        defer { try? FileManager.default.removeItem(at: filtered) }
        var project = try await project(source: source)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "HDR")])
        let captioned = directory.appendingPathComponent("captioned.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source],
            format: .hevcMovie, to: captioned, progress: { _ in }, preserveHDR: true)
        for output in [filtered, captioned] {
            let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
                "-hide_banner", "-nostdin", "-i", source.path, "-i", output.path,
                "-filter_complex", "[0:v]crop=1280:120:0:0,format=yuv420p10le[a];[1:v]crop=1280:120:0:0,format=yuv420p10le[b];[a][b]psnr",
                "-an", "-f", "null", "-"])
            let text = result.standardError
            let value = text.components(separatedBy: "average:").last?.split(separator: " ").first.map(String.init)
            let score = try #require(value.flatMap(Double.init))
            #expect(score > 38)
        }
    }

    private func project(source: URL, selectionDuration: Double? = 1) async throws -> TrimatoProject {
        let report = try await FFmpegMediaProbe.inspect(url: source)
        let stream = try #require(report.videoStream)
        let rateParts = (stream.averageFrameRate ?? "30/1").split(separator: "/").compactMap { Double($0) }
        let rate = ProjectFormat.stableFrameRate(rateParts.count == 2 ? rateParts[0] / rateParts[1] : 30)
        let record = MediaAssetRecord(name: source.lastPathComponent, originalPath: source.path,
            duration: ProjectTime(seconds: report.duration), naturalWidth: stream.width, naturalHeight: stream.height,
            frameRate: rate, hasAudio: report.hasAudio,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: selectionDuration ?? report.duration)))],
            playbackMode: .nativePassthrough)
        var result = TrimatoProject(name: "iPhone quality")
        result.format = ProjectFormat(mode: .custom, width: stream.width, height: stream.height, frameRate: rate)
        result.media = [record]
        _ = try result.append(asset: record)
        return result
    }
}
