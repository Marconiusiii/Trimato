import AVFoundation
import Cinematic
import CryptoKit
import Testing
@testable import Trimato

@MainActor @Suite(.serialized)
struct SpatialAudioIntegrationTests {
    static let directory = URL(fileURLWithPath: "/tmp/trimato-spatial-app-integration")

    @Test(.enabled(if: IPhoneMediaTests.available), arguments: ["4K_30fps.MOV", "4K_60fps.mov", "4K_120fps.MOV"])
    func appExportsAndPreviewsPreserveSpatialAudio(name: String) async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent(name)
        let original = AVURLAsset(url: source)
        let duration = try await original.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        let trim = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48_000), duration: CMTime(seconds: 4, preferredTimescale: 48_000))
        let project = try await IPhoneMediaTests().project(source: source, selectionDuration: nil)
        let urls = [project.media[0].id: source]
        let preview = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        defer { for url in preview.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        #expect(preview.audioMix == nil)
        #expect(preview.spatialAudio != nil)
        try await assertSpatial(preview.playbackAsset, matches: original)
        let composition = try #require(preview.playbackVideoComposition)
        let ids = Set(try await preview.playbackAsset.loadTracks(withMediaType: .video).map(\.trackID))
        for instruction in composition.instructions {
            let item = try #require(instruction as? AVVideoCompositionInstruction)
            #expect(item.layerInstructions.allSatisfy { ids.contains($0.trackID) })
        }
        let clipPreview = try await EditedCompositionBuilder.playbackAsset(asset: original, sourceRanges: [trim])
        try await assertSpatial(clipPreview, matches: original)
        #expect(abs(try await clipPreview.load(.duration).seconds - 4) < 0.001)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for (suffix, range, projectExport) in [
            ("spatial-original-video", full, false), ("spatial-trim-1s-to-5s", trim, false),
            ("spatial-Trimato-HDR", full, true), ("spatial-Trimato-HDR-trim-1s-to-5s", trim, true)
        ] {
            let output = Self.directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + suffix + ".mov")
            if projectExport {
                try await ProjectExporter.export(project: project, mediaURLs: urls,
                    timeRange: suffix.contains("trim-") ? ProjectTimeRange(range) : nil,
                    format: .hevcMovie, to: output, progress: { _ in }, preserveHDR: true)
            } else {
                try await ClipExporter.export(asset: original, sourceRanges: [range], sourceContentType: .quickTimeMovie,
                    format: .original, to: output, progress: { _ in })
            }
            let exported = AVURLAsset(url: output)
            try await assertSpatial(exported, matches: original)
            try await assertSamples(output, original: source, ranges: [range])
            #expect(abs(try await exported.load(.duration).seconds - range.duration.seconds) < 0.01)
            #expect(try await VideoColorPolicy.resolve(asset: exported, preserveHDR: true) == .hlg)
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func unsupportedAudioEditsAndFormatsFailBeforeReplacingOutput() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_30fps.MOV")
        let base = try await IPhoneMediaTests().project(source: source)
        let urls = [base.media[0].id: source]
        let index = try #require(base.tracks.firstIndex { $0.kind == .audio })
        var changes: [TrimatoProject] = []
        var mix = base; mix.tracks[index].mix.pan = 0.5; changes.append(mix)
        for project in changes {
            await #expect(throws: SpatialAudioError.self) {
                _ = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls, purpose: .finalExport)
            }
        }
        let target = Self.directory.appendingPathComponent("must-not-replace.mp4")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let sentinel = Data("existing export".utf8)
        try sentinel.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        for format in [ExportFormat.hevcMP4, .wav24, .m4aAppleLossless] {
            await #expect(throws: SpatialAudioError.self) {
                try await ProjectExporter.export(project: base, mediaURLs: urls, format: format, to: target, progress: { _ in })
            }
            #expect(try Data(contentsOf: target) == sentinel)
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func convertedClipExportsPreserveOriginalAudio() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_30fps.MOV")
        let original = AVURLAsset(url: source)
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48_000), duration: CMTime(seconds: 1, preferredTimescale: 48_000))
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for format in [ExportFormat.hevcMovie, .proRes422LT, .proRes422, .proRes422HQ] {
            let output = Self.directory.appendingPathComponent("clip-\(format.rawValue).mov")
            try await ClipExporter.export(asset: original, sourceRanges: [range], sourceContentType: .quickTimeMovie,
                format: format, to: output, progress: { _ in })
            try await assertSpatial(AVURLAsset(url: output), matches: original)
            try await assertSamples(output, original: source, ranges: [range])
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func nativePlayerPreparesSpatialAudioAndBlocksUnsupportedMixChanges() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_30fps.MOV")
        let project = try await IPhoneMediaTests().project(source: source)
        let model = ProjectPlayerViewModel()
        model.player.isMuted = true
        defer { model.cancelPreparation(); model.player.replaceCurrentItem(with: nil) }
        model.prepare(project: project, mediaURLs: [project.media[0].id: source])
        for _ in 0..<300 {
            if !model.isPreparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!model.isPreparing)
        #expect(model.errorMessage == nil)
        let item = try #require(model.player.currentItem)
        for _ in 0..<100 {
            if item.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(item.status == .readyToPlay)
        #expect(item.audioMix == nil)
        try await assertSpatial(item.asset, matches: AVURLAsset(url: source))
        var changed = project
        changed.tracks[changed.tracks.firstIndex { $0.kind == .audio }!].mix.pan = 0.5
        model.updateMix(project: changed)
        for _ in 0..<300 where model.isPreparing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.canControlPlayback)
        #expect(model.audioNotice?.contains("Stereo preview") == true)
        #expect(model.errorMessage == nil)
        model.updateMix(project: project)
        for _ in 0..<300 where model.isPreparing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.canControlPlayback)
        #expect(model.audioNotice == nil)
        #expect(model.errorMessage == nil)
        let editor = VideoPlayerViewModel()
        editor.player.isMuted = true
        defer { editor.closeMedia() }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let proxy = Self.directory.appendingPathComponent("stereo-only-playback-proxy.mov")
        defer { try? FileManager.default.removeItem(at: proxy) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-i", source.path,
            "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-dn", "-sn", proxy.path])
        let proxyAsset = AVURLAsset(url: proxy)
        #expect(try await !SpatialAudioPlan.detect(in: proxyAsset))
        let prepared = MediaSource(originalURL: source, playbackURL: proxy, originalAsset: AVURLAsset(url: source),
            playbackAsset: proxyAsset, contentType: .quickTimeMovie, mode: .proxyPlaybackMP4Export,
            frameTimestamps: [.zero], hasVideo: true, hasAudio: true)
        editor.load(url: source,
            sourceSegments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 1)))],
            preparedSource: prepared)
        for _ in 0..<300 {
            if !editor.isLoadingMedia { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(editor.hasMedia)
        let editedItem = try #require(editor.player.currentItem)
        try await assertSpatial(editedItem.asset, matches: AVURLAsset(url: source))
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func discontiguousCutsAndVideoFiltersRetainAudio() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_30fps.MOV")
        let original = AVURLAsset(url: source)
        let segments = [1.0, 3.0].map { SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: $0), duration: ProjectTime(seconds: 1))) }
        await #expect(throws: SpatialAudioError.self) {
            _ = try await EditedCompositionBuilder.playbackAsset(asset: original, sourceRanges: segments.reversed().map { $0.sourceRange.cmTimeRange })
        }
        let playback = try await EditedCompositionBuilder.playbackAsset(asset: original, sourceRanges: segments.map { $0.sourceRange.cmTimeRange })
        try await assertSpatial(playback, matches: original)
        #expect(abs(try await playback.load(.duration).seconds - 2) < 0.001)
        let cuts = Self.directory.appendingPathComponent("ordered-cuts.mov")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try await ClipExporter.export(asset: original, sourceRanges: segments.map { $0.sourceRange.cmTimeRange },
            sourceContentType: .quickTimeMovie, format: .original, to: cuts, progress: { _ in })
        try await assertSpatial(AVURLAsset(url: cuts), matches: original)
        try await assertSamples(cuts, original: source, ranges: segments.map { $0.sourceRange.cmTimeRange })
        var project = try await IPhoneMediaTests().project(source: source)
        for index in project.tracks.indices where !project.tracks[index].clips.isEmpty {
            project.tracks[index].clips[0].segments = segments
        }
        project.synchronizeTracksToLegacyTimeline()
        let projectCuts = Self.directory.appendingPathComponent("project-ordered-cuts.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [project.media[0].id: source],
            format: .hevcMovie, to: projectCuts, progress: { _ in }, preserveHDR: true)
        try await assertSpatial(AVURLAsset(url: projectCuts), matches: original)
        try await assertSamples(projectCuts, original: source, ranges: segments.map { $0.sourceRange.cmTimeRange })
        let filtered = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: .brightnessContrast)],
            audio: false, duration: 2, segments: segments)
        defer { try? FileManager.default.removeItem(at: filtered) }
        try await assertSpatial(AVURLAsset(url: filtered), matches: original)
        try await assertSamples(filtered, original: source, ranges: segments.map { $0.sourceRange.cmTimeRange })
        await #expect(throws: SpatialAudioError.self) {
            _ = try await ClipFilterRenderer.render(source: source, filters: [], audio: true, duration: 2, segments: segments)
        }
    }

    private func assertSamples(_ output: URL, original: URL, ranges: [CMTimeRange]) async throws {
        let before = try await Self.decode(original), after = try await Self.decode(output)
        #expect(Set(before.keys) == Set(after.keys))
        for codec in before.keys {
            let a = before[codec]!, b = try #require(after[codec])
            #expect(a.channels == b.channels && a.rate == b.rate)
            var expected: [Float] = []
            for range in ranges {
                let start = min(Int((range.start.seconds * a.rate).rounded()) * a.channels, a.samples.count)
                let end = min(Int((range.end.seconds * a.rate).rounded()) * a.channels, a.samples.count)
                expected.append(contentsOf: a.samples[start..<end])
            }
            #expect(b.samples.count == expected.count)
            let maximum = zip(expected, b.samples).map { abs(Double($0) - Double($1)) }.max() ?? .infinity
            #expect(maximum <= 0.000001)
        }
    }

    struct PCM {
        let channels: Int
        let rate: Double
        let samples: [Float]
    }

    static func decode(_ url: URL) async throws -> [UInt32: PCM] {
        let asset = AVURLAsset(url: url)
        var result: [UInt32: PCM] = [:]
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let description = descriptions.first,
                  let sourceFormat = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw Failure.invalid("Missing source audio format")
            }
            let codec = sourceFormat.mFormatID
            guard result[codec] == nil else { throw Failure.invalid("Ambiguous audio tracks") }
            let channels = Int(sourceFormat.mChannelsPerFrame)
            var layoutSize = 0
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) else {
                throw Failure.invalid("Missing channel layout")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sourceFormat.mSampleRate, AVNumberOfChannelsKey: channels,
                AVChannelLayoutKey: Data(bytes: layout, count: layoutSize)
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { throw Failure.invalid("Cannot read native audio") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.invalid("Cannot start decoder") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                let frameCount = CMSampleBufferGetNumSamples(buffer)
                let expectedTime = Double(samples.count / channels) / sourceFormat.mSampleRate
                guard abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - expectedTime) < 1 / sourceFormat.mSampleRate,
                      let block = CMSampleBufferGetDataBuffer(buffer),
                      CMBlockBufferGetDataLength(block) == frameCount * channels * MemoryLayout<Float>.size else {
                    throw Failure.invalid("Unexpected decoded audio layout or timestamps")
                }
                var values = [Float](repeating: 0, count: frameCount * channels)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw Failure.invalid("Cannot copy decoded samples") }
                samples.append(contentsOf: values)
            }
            guard reader.status == .completed, !samples.isEmpty else {
                throw reader.error ?? Failure.invalid("Incomplete audio decoding")
            }
            result[codec] = PCM(channels: channels, rate: sourceFormat.mSampleRate, samples: samples)
        }
        guard result.count == 2 else { throw Failure.invalid("Expected AAC and APAC audio") }
        return result
    }

    enum Failure: Error { case invalid(String) }

    private func assertSpatial(_ asset: AVAsset, matches original: AVAsset) async throws {
        let before = try await original.loadTracks(withMediaType: .audio)
        let after = try await asset.loadTracks(withMediaType: .audio)
        #expect(before.count == 2 && after.count == 2)
        #expect(try await SpatialAudioPlan.detect(in: asset))
        #expect(try await asset.load(.trackGroups).contains { Set($0.trackIDs.map(\.int32Value)) == Set(after.map(\.trackID)) })
        for (a, b) in zip(before, after) {
            let af = try #require(try await a.load(.formatDescriptions).first)
            let bf = try #require(try await b.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(af) == CMFormatDescriptionGetMediaSubType(bf))
            #expect(CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee.mChannelsPerFrame == CMAudioFormatDescriptionGetStreamBasicDescription(bf)?.pointee.mChannelsPerFrame)
            #expect(try await a.load(.isEnabled) == b.load(.isEnabled))
            #expect(try await a.loadAssociatedTracks(ofType: .audioFallback).count == b.loadAssociatedTracks(ofType: .audioFallback).count)
        }
        // Cinematic's metadata reader accepts file assets, not an in-memory AVMutableMovie.
        if #available(macOS 26, *), asset is AVURLAsset, let info = try? await CNAssetSpatialAudioInfo(asset: original) {
            let copied = try await CNAssetSpatialAudioInfo(asset: asset)
            #expect(info.spatialAudioMixMetadata == copied.spatialAudioMixMetadata)
        }
    }
}
