//
//  VidTimeTests.swift
//  VidTimeTests
//
//  Created by Marco Salsiccia on 5/5/26.
//

import AVFoundation
import Testing
import UniformTypeIdentifiers
@testable import VidTime

struct VidTimeTests {

    @Test func settingInAndOutMarkersReplacesPreviousValues() {
        let viewModel = VideoPlayerViewModel()
        let firstIn = CMTime(seconds: 2, preferredTimescale: 600)
        let replacementIn = CMTime(seconds: 4, preferredTimescale: 600)
        let firstOut = CMTime(seconds: 8, preferredTimescale: 600)
        let replacementOut = CMTime(seconds: 10, preferredTimescale: 600)

        viewModel.setInMarker(at: firstIn)
        viewModel.setInMarker(at: replacementIn)
        viewModel.setOutMarker(at: firstOut)
        viewModel.setOutMarker(at: replacementOut)

        #expect(viewModel.inMarker == replacementIn)
        #expect(viewModel.outMarker == replacementOut)
    }

    @Test func exportRangeRequiresInBeforeOut() {
        let earlier = CMTime(seconds: 2, preferredTimescale: 600)
        let later = CMTime(seconds: 8, preferredTimescale: 600)

        #expect(VideoPlayerViewModel.validExportRange(inMarker: earlier, outMarker: later) != nil)
        #expect(VideoPlayerViewModel.validExportRange(inMarker: later, outMarker: earlier) == nil)
        #expect(VideoPlayerViewModel.validExportRange(inMarker: earlier, outMarker: earlier) == nil)
    }

    @Test func timelinePointsAreChronologicalWhenMarkersAreReversed() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let points = VideoPlayerViewModel.orderedTimelinePoints(
            duration: duration,
            inMarker: CMTime(seconds: 9, preferredTimescale: 600),
            outMarker: CMTime(seconds: 3, preferredTimescale: 600)
        )

        #expect(points.map(\.kind) == [.start, .outMarker, .inMarker, .end])
    }

    @Test func duplicateTimelinePositionsAreCollapsed() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let points = VideoPlayerViewModel.orderedTimelinePoints(
            duration: duration,
            inMarker: .zero,
            outMarker: duration
        )

        #expect(points.count == 2)
        #expect(points.map(\.kind) == [.start, .outMarker])
    }

    @Test func timelineNavigationMovesStrictlyInTheRequestedDirection() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let inMarker = CMTime(seconds: 3, preferredTimescale: 600)
        let outMarker = CMTime(seconds: 9, preferredTimescale: 600)

        let next = VideoPlayerViewModel.timelineDestination(
            from: inMarker,
            movingForward: true,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker
        )
        let previous = VideoPlayerViewModel.timelineDestination(
            from: outMarker,
            movingForward: false,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker
        )

        #expect(next?.kind == .outMarker)
        #expect(previous?.kind == .inMarker)
    }

    @Test func trimmedFilenamePreservesSourceExtension() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Example Clip.mp4")

        #expect(VideoPlayerViewModel.trimmedFilename(for: sourceURL) == "Example Clip-trimmed.mp4")
    }

    @Test func convertedFilenameAlwaysUsesMP4() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Example Clip.mkv")

        #expect(VideoPlayerViewModel.trimmedFilename(
            for: sourceURL,
            convertingToMP4: true
        ) == "Example Clip-trimmed.mp4")
    }

    @Test func passthroughUsesTheOriginalContainerType() throws {
        let fileType = try ClipExporter.passthroughFileType(
            for: .mpeg4Movie,
            supportedFileTypes: [.mp4, .mov]
        )

        #expect(fileType == .mp4)
    }

    @Test func unsupportedPassthroughDoesNotFallBackToConversion() {
        do {
            _ = try ClipExporter.passthroughFileType(
                for: .mpeg4Movie,
                supportedFileTypes: [.mov]
            )
            Issue.record("Expected unsupported passthrough to throw")
        } catch let error as ClipExportError {
            #expect(error == .unsupportedFileType)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func hdrAndAlphaSourcesAreRejectedForMP4Conversion() {
        let hdr = FFmpegMediaProbe.Report(
            streams: [.init(
                codecType: "video",
                codecName: "hevc",
                pixelFormat: "yuv420p10le",
                colorTransfer: "smpte2084"
            )],
            format: .init(duration: "12.5", formatName: "matroska")
        )
        let alpha = FFmpegMediaProbe.Report(
            streams: [.init(
                codecType: "video",
                codecName: "prores",
                pixelFormat: "yuva444p10le",
                colorTransfer: "bt709"
            )],
            format: .init(duration: "12.5", formatName: "mov")
        )

        #expect(throws: MediaSourceError.unsupportedHDR) {
            try FFmpegMediaProbe.validateForMP4Conversion(hdr)
        }
        #expect(throws: MediaSourceError.unsupportedAlpha) {
            try FFmpegMediaProbe.validateForMP4Conversion(alpha)
        }
    }

    @Test func ffmpegExportReadsOriginalAndProducesMP4Arguments() {
        let arguments = FFmpegClipExporter.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mkv"),
            timeRange: CMTimeRange(
                start: CMTime(seconds: 2.5, preferredTimescale: 600),
                duration: CMTime(seconds: 7.25, preferredTimescale: 600)
            ),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4")
        )

        #expect(arguments.contains("/tmp/source.mkv"))
        #expect(arguments.contains("h264_videotoolbox"))
        #expect(arguments.contains("aac"))
        #expect(arguments.last == "/tmp/output.mp4")

        let fallbackArguments = FFmpegClipExporter.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mkv"),
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 1, preferredTimescale: 600)
            ),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            useVideoToolbox: false
        )
        #expect(fallbackArguments.contains("mpeg4"))
        #expect(fallbackArguments.contains("mp4v"))
    }

    @Test func ffmpegProgressParserClampsProgress() {
        var values: [Double] = []
        let progress = Data("out_time_us=2500000\nprogress=continue\nout_time_us=12000000\nprogress=end\n".utf8)

        FFmpegRunner.parseProgress(progress, duration: 10) { value in
            values.append(value)
        }

        #expect(values == [0.25, 1, 1])
    }

    @Test func bundledFFmpegToolsExecute() async throws {
        let ffmpeg = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-version"])
        let ffprobe = try await FFmpegRunner.run(tool: .ffprobe, arguments: ["-version"])

        #expect(String(decoding: ffmpeg.standardOutput, as: UTF8.self).contains("ffmpeg version 8.1.2"))
        #expect(String(decoding: ffprobe.standardOutput, as: UTF8.self).contains("ffprobe version 8.1.2"))
    }

    @Test func bundledToolsEncodeTrimmedMP4FromMKV() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mkv")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")

        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24",
            "-t", "1", "-c:v", "mpeg4", sourceURL.path
        ])
        try await FFmpegClipExporter.export(
            sourceURL: sourceURL,
            timeRange: CMTimeRange(
                start: CMTime(seconds: 0.25, preferredTimescale: 600),
                duration: CMTime(seconds: 0.5, preferredTimescale: 600)
            ),
            to: outputURL,
            progress: { _ in }
        )
        let probe = try await FFmpegRunner.run(tool: .ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_type",
            "-show_entries", "format=format_name,duration", "-of", "json",
            outputURL.path
        ])
        let report = String(decoding: probe.standardOutput, as: UTF8.self)

        #expect(report.contains("\"codec_type\": \"video\""))
        #expect(report.contains("mp4"))
    }

}
