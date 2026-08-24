//
//  TrimatoTests.swift
//  TrimatoTests
//
//  Created by Marco Salsiccia on 5/5/26.
//

import AVFoundation
import Testing
import UniformTypeIdentifiers
@testable import Trimato

struct TrimatoTests {

    @Test func placementCommandsUseTheApprovedEditorTerminology() {
        #expect(PlacementAction.allCases.map(\.title) == [
            "Append to Timeline",
            "Insert and Split",
            "Insert and Overwrite",
            "Insert on Top with Source Audio",
            "Insert on Top over Primary Audio",
        ])
    }

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
                colorTransfer: "smpte2084",
                width: nil,
                height: nil,
                averageFrameRate: nil
            )],
            format: .init(duration: "12.5", formatName: "matroska")
        )
        let alpha = FFmpegMediaProbe.Report(
            streams: [.init(
                codecType: "video",
                codecName: "prores",
                pixelFormat: "yuva444p10le",
                colorTransfer: "bt709",
                width: nil,
                height: nil,
                averageFrameRate: nil
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

    @Test func ffmpegBuildsAConcatenatedFilterForEditedRanges() {
        let ranges = [
            CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600),
                duration: CMTime(seconds: 2, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 5, preferredTimescale: 600),
                duration: CMTime(seconds: 3, preferredTimescale: 600)
            )
        ]
        let arguments = FFmpegClipExporter.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mkv"),
            sourceRanges: ranges,
            hasAudio: false,
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4")
        )
        let filter = arguments[arguments.firstIndex(of: "-filter_complex")! + 1]

        #expect(filter.contains("trim=start=1.000000:duration=2.000000"))
        #expect(filter.contains("trim=start=5.000000:duration=3.000000"))
        #expect(filter.contains("concat=n=2:v=1:a=0[v]"))
        #expect(!arguments.contains("[a]"))
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

    @Test func bundledFFmpegToolsOnlyExposeLocalProtocols() async throws {
        let result = try await FFmpegRunner.run(
            tool: .ffmpeg,
            arguments: ["-hide_banner", "-protocols"]
        )
        let protocols = Set(
            String(decoding: result.standardOutput, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )

        #expect(protocols.isSuperset(of: ["file", "pipe", "fd"]))
        #expect(protocols.isDisjoint(with: [
            "crypto", "ftp", "gopher", "http", "httpproxy", "rtmp", "rtp",
            "srtp", "tcp", "udp", "udplite", "unix"
        ]))
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

    @Test func bundledToolsJoinTwoEditedRanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mkv")
        let outputURL = directory.appendingPathComponent("joined.mp4")

        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "1.2", "-c:v", "mpeg4", "-c:a", "pcm_s16le", sourceURL.path
        ])
        try await FFmpegClipExporter.export(
            sourceURL: sourceURL,
            sourceRanges: [
                CMTimeRange(
                    start: CMTime(seconds: 0.1, preferredTimescale: 600),
                    duration: CMTime(seconds: 0.3, preferredTimescale: 600)
                ),
                CMTimeRange(
                    start: CMTime(seconds: 0.8, preferredTimescale: 600),
                    duration: CMTime(seconds: 0.3, preferredTimescale: 600)
                )
            ],
            hasAudio: true,
            to: outputURL,
            progress: { _ in }
        )

        let report = try await FFmpegMediaProbe.inspect(url: outputURL)
        let containsVideo = await report.videoStream != nil
        let containsAudio = await report.hasAudio
        let outputDuration = await report.duration
        #expect(containsVideo)
        #expect(containsAudio)
        #expect(outputDuration > 0.5 && outputDuration < 0.8)
    }

    @Test func nativeCompositionJoinsAndPassesThroughEditedRanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        let outputURL = directory.appendingPathComponent("joined.mov")

        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24",
            "-t", "1.2", "-c:v", "mpeg4", sourceURL.path
        ])
        let ranges = [
            CMTimeRange(
                start: CMTime(seconds: 0.1, preferredTimescale: 600),
                duration: CMTime(seconds: 0.3, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 0.8, preferredTimescale: 600),
                duration: CMTime(seconds: 0.3, preferredTimescale: 600)
            )
        ]
        let asset = AVURLAsset(url: sourceURL)
        let composition = try await EditedCompositionBuilder.build(
            asset: asset,
            sourceRanges: ranges
        )
        let compositionDuration = try await composition.load(.duration)
        #expect(abs(CMTimeGetSeconds(compositionDuration) - 0.6) < 0.01)

        try await ClipExporter.export(
            asset: asset,
            sourceRanges: ranges,
            sourceContentType: .quickTimeMovie,
            to: outputURL
        )
        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration = try await outputAsset.load(.duration)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty)
        #expect(CMTimeGetSeconds(outputDuration) > 0.5)
    }

    @Test func deletingAMiddleSelectionJoinsTheRemainingSourceRanges() throws {
        var timeline = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        try timeline.delete(editedRange: CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 600),
            end: CMTime(seconds: 15, preferredTimescale: 600)
        ))

        #expect(seconds(timeline.duration) == 25)
        #expect(timeline.sourceRanges.count == 2)
        #expect(seconds(timeline.sourceRanges[0].start) == 0)
        #expect(seconds(timeline.sourceRanges[0].duration) == 10)
        #expect(seconds(timeline.sourceRanges[1].start) == 15)
        #expect(seconds(timeline.sourceRanges[1].duration) == 15)
    }

    @Test func repeatedDeletionCanCrossAnEarlierEditPoint() throws {
        var timeline = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        try timeline.delete(editedRange: CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 600),
            end: CMTime(seconds: 15, preferredTimescale: 600)
        ))
        try timeline.delete(editedRange: CMTimeRange(
            start: CMTime(seconds: 8, preferredTimescale: 600),
            end: CMTime(seconds: 12, preferredTimescale: 600)
        ))

        #expect(seconds(timeline.duration) == 21)
        #expect(timeline.sourceRanges.count == 2)
        #expect(seconds(timeline.sourceRanges[0].duration) == 8)
        #expect(seconds(timeline.sourceRanges[1].start) == 17)
        #expect(seconds(timeline.sourceRanges[1].duration) == 13)
    }

    @Test func editedSelectionMapsBackAcrossSourceRanges() throws {
        var timeline = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        try timeline.delete(editedRange: CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 600),
            end: CMTime(seconds: 15, preferredTimescale: 600)
        ))
        let ranges = timeline.sourceRanges(in: CMTimeRange(
            start: CMTime(seconds: 8, preferredTimescale: 600),
            end: CMTime(seconds: 14, preferredTimescale: 600)
        ))

        #expect(ranges.count == 2)
        #expect(seconds(ranges[0].start) == 8)
        #expect(seconds(ranges[0].duration) == 2)
        #expect(seconds(ranges[1].start) == 15)
        #expect(seconds(ranges[1].duration) == 4)
    }

    @Test func startAndEndTrimsRetainTheExpectedSourceRange() throws {
        var startTrim = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        try startTrim.delete(editedRange: CMTimeRange(
            start: .zero,
            end: CMTime(seconds: 5, preferredTimescale: 600)
        ))
        #expect(seconds(startTrim.sourceRanges[0].start) == 5)
        #expect(seconds(startTrim.duration) == 25)

        var endTrim = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        try endTrim.delete(editedRange: CMTimeRange(
            start: CMTime(seconds: 20, preferredTimescale: 600),
            end: CMTime(seconds: 30, preferredTimescale: 600)
        ))
        #expect(seconds(endTrim.sourceRanges[0].start) == 0)
        #expect(seconds(endTrim.duration) == 20)
    }

    @Test func deletingTheEntireClipIsRejected() {
        var timeline = ClipEditTimeline(
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        #expect(throws: ClipEditError.entireClip) {
            try timeline.delete(editedRange: CMTimeRange(
                start: .zero,
                end: CMTime(seconds: 30, preferredTimescale: 600)
            ))
        }
    }

    @Test func frameTimestampsAreRebasedAroundDeletedMedia() {
        let timestamps = (0..<10).map {
            CMTime(seconds: Double($0), preferredTimescale: 600)
        }
        let edited = EditedCompositionBuilder.editedFrameTimestamps(
            sourceTimestamps: timestamps,
            sourceRanges: [
                CMTimeRange(
                    start: .zero,
                    end: CMTime(seconds: 3, preferredTimescale: 600)
                ),
                CMTimeRange(
                    start: CMTime(seconds: 6, preferredTimescale: 600),
                    end: CMTime(seconds: 10, preferredTimescale: 600)
                )
            ]
        )

        #expect(edited.map(seconds) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func appDeclaresVideoDocumentTypes() throws {
        let documentTypes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [[String: Any]]
        )
        let contentTypes = documentTypes
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }

        #expect(contentTypes.contains("public.movie"))
        #expect(contentTypes.contains("com.marconius.trimato.matroska-video"))
        #expect(contentTypes.contains("com.marconius.trimato.webm-video"))
        let videoType = try #require(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("public.movie") == true
        })
        #expect(videoType["CFBundleTypeRole"] as? String == "Editor")
        #expect(videoType["LSHandlerRank"] as? String == "Alternate")
        #expect(contentTypes.contains("com.marconius.trimato.project"))
    }

    @Test func aboutInformationIsAccessibleAndAcknowledgesFFmpeg() throws {
        #expect(AboutInformation.copyright == "© 2026 Marco Salsiccia")
        #expect(!AboutInformation.copyright.contains("Copyright ©"))
        #expect(AboutInformation.ffmpegAcknowledgment.contains("FFmpeg 8.1.2"))
        #expect(AboutInformation.ffmpegAcknowledgment.contains("GNU Lesser General Public License"))
        #expect(AboutInformation.versionText().hasPrefix("Version "))

        let licenseURL = try #require(
            Bundle.main.url(forResource: "COPYING.LGPLv2.1", withExtension: nil)
        )
        #expect(FileManager.default.fileExists(atPath: licenseURL.path))
    }

    @Test func importProgressAnnouncementsUseRestrainedMilestones() {
        #expect(VideoPlayerViewModel.importProgressMilestone(for: 0.01) == 0)
        #expect(VideoPlayerViewModel.importProgressMilestone(for: 0.24) == 0)
        #expect(VideoPlayerViewModel.importProgressMilestone(for: 0.25) == 25)
        #expect(VideoPlayerViewModel.importProgressMilestone(for: 0.74) == 50)
        #expect(VideoPlayerViewModel.importProgressMilestone(for: 1) == 100)
    }

    @Test func proxyRemovalDeletesTheTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = directory.appendingPathComponent("proxy.mp4")
        try Data("temporary proxy".utf8).write(to: proxy)

        #expect(FileManager.default.fileExists(atPath: proxy.path))
        ProxyMediaManager.removeProxy(at: proxy)
        #expect(!FileManager.default.fileExists(atPath: proxy.path))
    }

    @Test func cachedProxyLocationIsStableForAnImportedAsset() throws {
        let cacheKey = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        let first = try ProxyMediaManager.cachedProxyURL(for: cacheKey)
        let second = try ProxyMediaManager.cachedProxyURL(for: cacheKey)

        #expect(first == second)
        #expect(first.lastPathComponent == "00000000-0000-0000-0000-000000000123.mp4")
    }

    private func seconds(_ time: CMTime) -> Double {
        CMTimeGetSeconds(time)
    }

}
