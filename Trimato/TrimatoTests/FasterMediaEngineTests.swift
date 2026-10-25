import AVFoundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct FasterMediaEngineTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-engine-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func binaryFrameSearchHandlesBoundariesAndVariableIntervals() {
        let frames = [0.0, 0.033, 0.09, 0.2].map { CMTime(seconds: $0, preferredTimescale: 1_000_000) }
        #expect(FrameTimestampSearch.firstAfter(frames[1], in: frames) == 2)
        #expect(FrameTimestampSearch.lastBefore(frames[1], in: frames) == 0)
        #expect(FrameTimestampSearch.firstAfter(frames[3], in: frames) == nil)
        #expect(FrameTimestampSearch.lastBefore(.zero, in: frames) == nil)
        #expect(FrameTimestampSearch.firstAfter(.zero, in: []) == nil)
        #expect(FrameTimestampSearch.lastBefore(CMTime(seconds: 0.1, preferredTimescale: 600), in: frames) == 2)
    }

    @Test func discoveryFindsCaptionsAndMediaTogetherAndHonorsCancellation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one.mov", "two.srt", "three.vtt", "notes.txt", ".hidden.mov"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let result = try await ProjectImportCoordinator.discover(root)
        #expect(result.media.map(\.lastPathComponent) == ["one.mov"])
        #expect(result.captions.map(\.lastPathComponent) == ["three.vtt", "two.srt"])
        let job = Task { try await ProjectImportCoordinator.discover(root) }
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
    }

    @Test func interactiveRenderDoesNotWaitForBackgroundRenderOrFullAnalysis() async throws {
        let scheduler = MediaJobScheduler(renderCapacity: 2)
        try await scheduler.acquire(.render, priority: .background)
        try await scheduler.acquire(.analysis, priority: .background)
        try await scheduler.acquire(.inspection, priority: .interactive)
        try await scheduler.acquire(.render, priority: .interactive)
        let queued = Task { try await scheduler.acquire(.render, priority: .background) }
        while await scheduler.queuedCount == 0 { await Task.yield() }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await scheduler.release(.render, priority: .interactive)
        await scheduler.release(.render)
        await scheduler.release(.analysis)
        await scheduler.release(.inspection, priority: .interactive)
        #expect(await scheduler.queuedCount == 0)
    }

    @Test func renderCacheLeasesSurviveCleanupAndSourceChangesInvalidateOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("source".utf8).write(to: source)
        let cache = RenderedMediaCache(directory: root.appendingPathComponent("cache"), maximumByteCount: 500)
        let counter = AnalysisCounter()
        let recipe = Data("recipe".utf8)
        let producer: @Sendable () async throws -> URL = {
            let file = root.appendingPathComponent(UUID().uuidString)
            try await counter.next().write(to: file)
            return file
        }
        let first = try await cache.value(source: source, recipe: recipe, produce: producer)
        let second = try await cache.value(source: source, recipe: recipe, produce: producer)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        #expect(first != second)
        #expect(await counter.count == 1)
        try FileManager.default.removeItem(at: first)
        #expect(try Data(contentsOf: second) == Data("analysis".utf8))
        let fingerprintBeforeReuse = try MediaCacheManager.sourceFingerprint(for: second)
        let reused = try await cache.value(source: source, recipe: recipe, produce: producer)
        defer { try? FileManager.default.removeItem(at: reused) }
        #expect(try MediaCacheManager.sourceFingerprint(for: second) == fingerprintBeforeReuse)
        #expect(try await cache.clear(.all).removedFileCount == 1)
        #expect(try Data(contentsOf: second) == Data("analysis".utf8))
        let third = try await cache.value(source: source, recipe: recipe, produce: producer)
        defer { try? FileManager.default.removeItem(at: third) }
        try Data("changed source".utf8).write(to: source, options: .atomic)
        let fourth = try await cache.value(source: source, recipe: recipe, produce: producer)
        defer { try? FileManager.default.removeItem(at: fourth) }
        #expect(await counter.count == 3)
        #expect(try await cache.status().bytes <= 500)
    }

    @Test func failedAndCancelledRendersAreNotCachedAndUnavailableCacheCanRender() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("source".utf8).write(to: source)
        let cache = RenderedMediaCache(directory: root.appendingPathComponent("cache"), maximumByteCount: 100)
        let recipe = Data("failed".utf8)
        await #expect(throws: AnalysisError.self) {
            _ = try await cache.value(source: source, recipe: recipe) { throw AnalysisError.emptyFrameIndex }
        }
        let job = Task { try await cache.value(source: source, recipe: recipe) {
            try await Task.sleep(for: .seconds(10))
            return source
        } }
        try await Task.sleep(for: .milliseconds(10))
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        #expect(try await cache.status().count == 0)
        let oversize = try await cache.value(source: source, recipe: recipe) {
            let output = root.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 0, count: 120).write(to: output)
            return output
        }
        defer { try? FileManager.default.removeItem(at: oversize) }
        #expect(try await cache.status().bytes <= 100)
        #expect(try Data(contentsOf: oversize).count == 120)
        let unavailable = RenderedMediaCache(directory: source)
        let fallback = try await unavailable.value(source: source, recipe: recipe) {
            let output = root.appendingPathComponent(UUID().uuidString)
            try Data("complete".utf8).write(to: output)
            return output
        }
        #expect(try Data(contentsOf: fallback) == Data("complete".utf8))
        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }

    @Test func concurrentProxyConsumersReceiveOneCompletedFileAndNoPartialFiles() async throws {
        let source = try AudioEditorRevisionTests().fixture(duration: 2) { Float(0.1 * sin(2 * .pi * 220 * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let cache = MediaCacheManager.shared
        let key = UUID()
        let fingerprint = try MediaCacheManager.sourceFingerprint(for: source)
        do {
            async let first = cache.ensureProxy(sourceURL: source, duration: 2, cacheKey: key, fingerprint: fingerprint, hasVideo: false)
            async let second = cache.ensureProxy(sourceURL: source, duration: 2, cacheKey: key, fingerprint: fingerprint, hasVideo: false)
            let (one, two) = try await (first, second)
            #expect(one == two)
            let report = try await FFmpegMediaProbe.inspect(url: one)
            #expect(report.hasAudio)
            #expect(abs(report.duration - 2) < 0.1)
            let names = try FileManager.default.contentsOfDirectory(atPath: ProxyMediaManager.cacheDirectory().path)
            #expect(!names.contains { $0.hasPrefix(key.uuidString + "-") && $0.contains(".partial") })
            #expect(try await cache.existingProxy(cacheKey: key, fingerprint: fingerprint) == one)
            try await cache.removeProxy(cacheKey: key)
        } catch {
            try? await cache.removeProxy(cacheKey: key)
            throw error
        }
    }

    @Test func invalidFilterValuesKeepTheirActionableValidationError() async throws {
        let source = try AudioEditorRevisionTests().fixture(duration: 0.1) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        var filter = ClipFilter(kind: .brightnessContrast)
        filter.values["contrast"] = .nan
        await #expect(throws: MediaSourceError.self) {
            _ = try await ClipFilterRenderer.render(source: source, filters: [filter], audio: false, duration: 0.1)
        }
    }

    @Test func cancellationAtCompletedFilterDeliveryIsHonored() async throws {
        let fixture = AudioEditorRevisionTests()
        let source = try fixture.fixture(duration: 0.1) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        let job = Task {
            try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: .tone)], audio: true,
                duration: 0.1, progress: { value in
                    if value >= 1 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        await #expect(throws: CancellationError.self) { _ = try await job.value }
    }

    @Test func boundedImportReportsEachFileAndKeepsSourceOrder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = AudioEditorRevisionTests()
        let source = try fixture.fixture(duration: 0.1) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        var inputs: [URL] = []
        for index in 0..<9 {
            let url = root.appendingPathComponent("clip-\(index).wav")
            try FileManager.default.copyItem(at: source, to: url)
            inputs.append(url)
        }
        var records: [Int: MediaAssetRecord] = [:]
        var active: Set<Int> = []
        var maximumActive = 0
        try await ProjectImportCoordinator.importAssets(at: inputs, progress: { index, _ in
            active.insert(index)
            maximumActive = max(maximumActive, active.count)
        }, completed: { index, result in
            active.remove(index)
            if case .success(let record) = result { records[index] = record }
            else { Issue.record("A generated WAV failed to import") }
        })
        #expect(records.keys.sorted().compactMap { records[$0]?.originalPath } == inputs.map(\.path))
        #expect(maximumActive <= 4)
        #expect(active.isEmpty)
    }

    @Test func sourceEnvelopeIncludesHandlesAndClampsToSource() {
        let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 5), duration: ProjectTime(seconds: 1))),
                        SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 9), duration: ProjectTime(seconds: 2)))]
        let clip = TimelineClip(assetID: UUID(), name: "Clip", segments: segments)
        let envelope = ClipFilterRenderer.sourceEnvelope(clip: clip, duration: ProjectTime(seconds: 12), handle: ProjectTime(seconds: 2))
        #expect(envelope?.start == ProjectTime(seconds: 3))
        #expect(envelope?.end == ProjectTime(seconds: 12))
    }

    @Test func filteredVideoEnvelopesKeepTransitionHandlesAndProjectTiming() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("video.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=30:duration=4", "-c:v", "prores_ks", "-profile:v", "1", source.path])
        let record = MediaAssetRecord(name: "Video", originalPath: source.path, duration: ProjectTime(seconds: 4),
            naturalWidth: 160, naturalHeight: 90, frameRate: 30, hasAudio: false,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 4)))], playbackMode: .nativePassthrough)
        var project = TrimatoProject()
        project.media = [record]
        func segment(_ start: Double) -> SourceSegment {
            SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: start), duration: ProjectTime(seconds: 0.8)))
        }
        let first = try project.append(asset: record, segments: [segment(1)])
        let second = try project.append(asset: record, segments: [segment(2)])
        for id in [first, second] { try project.setClipEffects(id: id, audio: nil, filters: [ClipFilter(kind: .blackAndWhite)]) }
        let track = try #require(project.tracks.first { $0.kind == .video })
        try project.addTransition(TimelineTransition(trackID: track.id, edge: .between, kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 0.4), leadingClipID: first, trailingClipID: second))
        let (prepared, urls, files) = try await ClipFilterRenderer.prepare(project: project, urls: [record.id: source])
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        #expect(prepared.duration == project.duration)
        for clip in prepared.tracks.flatMap(\.clips) where clip.id == first || clip.id == second {
            let asset = try #require(prepared.asset(id: clip.assetID))
            #expect(clip.duration == ProjectTime(seconds: 0.8))
            #expect(asset.duration < record.duration)
            #expect((clip.segments.first?.sourceRange.start.seconds ?? 0) >= 0.4 - 0.00001)
            #expect(asset.duration.seconds - (clip.segments.last?.sourceRange.end.seconds ?? 0) >= 0.4 - 0.00001)
            #expect(urls[clip.assetID] != nil)
        }
        #expect(project.tracks.flatMap(\.clips).first { $0.id == first }?.segments.map(\.sourceRange) == [segment(1).sourceRange])
        let output = root.appendingPathComponent("transition.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: source], format: .proRes422LT,
            to: output, progress: { _ in }, preserveHDR: false)
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(abs(report.duration - project.duration.seconds) < 0.07)
    }

    @Test func nativeAudioDeliveryCompletesAndCancellationDoesNotCommit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = AudioEditorRevisionTests()
        let source = try fixture.fixture(duration: 2) { Float(0.1 * sin(2 * .pi * 220 * $0)) }
        defer { try? FileManager.default.removeItem(at: source) }
        let output = root.appendingPathComponent("audio.wav")
        let asset = AVURLAsset(url: source)
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 48000), duration: CMTime(seconds: 0.75, preferredTimescale: 48000))
        try await AudioOnlyExporter.export(asset: asset, audioMix: nil, timeRange: range, format: .wav24, to: output, progress: { _ in })
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(abs(report.duration - 0.75) < 0.001)
        let cancelled = root.appendingPathComponent("cancelled.wav")
        let job = Task { try await AudioOnlyExporter.export(asset: asset, audioMix: nil, timeRange: nil,
            format: .wav24, to: cancelled, progress: { _ in }) }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
    }

    @Test func exactFrameWindowsMatchVariableRateSamplesAcrossADeletion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("variable.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=30:duration=4", "-vf", "select='eq(mod(n,3),0)+eq(mod(n,7),0)'",
            "-fps_mode", "vfr", "-c:v", "mpeg4", "-bf", "2", source.path])
        let asset = AVURLAsset(url: source)
        let all = try await FrameWindowIndex.read(asset: asset,
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)))
        let probe = try await FFmpegMediaProbe.frameTimestamps(url: source, duration: 4)
        if all.count != probe.count || !zip(all, probe).allSatisfy({ abs($0.seconds - $1.seconds) < 0.00001 }) {
            let diagnostics = try JSONEncoder().encode(["native": all.map(\.seconds), "ffprobe": probe.map(\.seconds)])
            Attachment.record(Array(diagnostics), named: "frame-timing.json")
        }
        #expect(all.count == probe.count)
        #expect(zip(all, probe).allSatisfy { abs($0.seconds - $1.seconds) < 0.00001 })
        let index = FrameWindowIndex(asset: asset, duration: CMTime(seconds: 4, preferredTimescale: 600))
        for frame in [0, 2, 15, all.count - 2] {
            let target = try await index.target(from: all[frame], forward: true, count: 1)
            #expect(abs(target.seconds - all[frame + 1].seconds) < 0.00001)
        }
        let ranges = [CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                      CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))]
        let expected = EditedCompositionBuilder.editedFrameTimestamps(sourceTimestamps: all, sourceRanges: ranges)
        let editedIndex = FrameWindowIndex(asset: asset, duration: CMTime(seconds: 2, preferredTimescale: 600), sourceRanges: ranges)
        for frame in expected.indices.dropLast() {
            let target = try await editedIndex.target(from: expected[frame], forward: true, count: 1)
            #expect(abs(target.seconds - expected[frame + 1].seconds) < 0.00001,
                "From \(expected[frame].seconds), got \(target.seconds), expected \(expected[frame + 1].seconds)")
        }
        #expect(try await editedIndex.target(from: .zero, forward: false, count: 1) == .zero)
    }

    @Test func cuttingBoardQueuesRapidFrameRequestsAndCancelsOnClose() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stepping.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=30:duration=2", "-c:v", "prores_ks", "-profile:v", "1", source.path])
        let model = VideoPlayerViewModel(announcementHandler: { _ in })
        model.player.isMuted = true
        defer { model.closeMedia() }
        model.load(url: source, preparedSource: .native(url: source, asset: AVURLAsset(url: source),
            contentType: nil, mode: .nativePassthrough, hasVideo: true, hasAudio: false))
        for _ in 0..<500 where model.isLoadingMedia { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.hasMedia)
        let item = try #require(model.player.currentItem)
        for _ in 0..<500 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        try #require(item.status == .readyToPlay)
        model.stepForward(frames: 10)
        model.stepForward(frames: 10)
        model.stepForward(frames: 10)
        model.stepBackward(frames: 5)
        let expected = 25.0 / 30
        for _ in 0..<500 where abs(model.player.currentTime().seconds - expected) > 0.00001 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(model.player.currentTime().seconds - expected) < 0.00001)
        model.stepForward()
        model.closeMedia()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.hasMedia)
        #expect(model.player.currentItem == nil)
        #expect(model.mediaOpenErrorMessage == nil)
    }

    @Test func lateExcerptMatchesDecodeFromStartAndRetainsAudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=30:duration=8", "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000:duration=8",
            "-c:v", "mpeg4", "-bf", "2", "-c:a", "pcm_s16le", source.path])
        let range = CMTimeRange(start: CMTime(seconds: 5.1, preferredTimescale: 600), duration: CMTime(seconds: 0.7, preferredTimescale: 600))
        let output = root.appendingPathComponent("fast.mov")
        let reference = root.appendingPathComponent("reference.mov")
        var slow = FFmpegClipExporter.arguments(sourceURL: source, sourceRanges: [range], hasAudio: true,
                                               outputURL: reference, format: .proRes422LT)
        let seek = try #require(slow.firstIndex(of: "-ss"))
        let option = Array(slow[seek...seek + 1]); slow.removeSubrange(seek...seek + 1)
        let input = try #require(slow.firstIndex(of: "-i"))
        slow.insert(contentsOf: option, at: input + 2)
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: slow)
        try await FFmpegClipExporter.export(sourceURL: source, sourceRanges: [range], hasAudio: true,
                                           format: .proRes422LT, to: output, progress: { _ in })
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(report.hasAudio)
        #expect(abs(report.duration - 0.7) < 0.04)
        let record = MediaAssetRecord(name: "Video", originalPath: reference.path, duration: ProjectTime(seconds: 0.7),
            naturalWidth: 160, naturalHeight: 90, frameRate: 30, hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.7)))], playbackMode: .nativePassthrough)
        var project = TrimatoProject()
        project.media = [record]
        _ = try project.append(asset: record)
        let native = root.appendingPathComponent("native.mov")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: reference], format: .proRes422LT,
                                         to: native, progress: { _ in }, preserveHDR: false)
        let nativeReport = try await FFmpegMediaProbe.inspect(url: native)
        #expect(nativeReport.hasAudio)
        #expect(abs(nativeReport.duration - 0.7) < 0.04)
        func hashes(_ url: URL) async throws -> [String] {
            let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-i", url.path, "-map", "0:v:0", "-f", "framemd5", "-"])
            return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
                .filter { !$0.hasPrefix("#") }.map { String($0.split(separator: ",").last!) }
        }
        #expect(try await hashes(output) == hashes(reference))
    }
}
