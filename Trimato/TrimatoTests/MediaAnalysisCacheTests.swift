import AVFoundation
import Testing
@testable import Trimato

actor AnalysisCounter {
    var count = 0
    func next() -> Data { count += 1; return Data("analysis".utf8) }
}

@Suite(.serialized)
struct MediaAnalysisCacheTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        try Data("source".utf8).write(to: source)
        return (root, source)
    }

    @Test func frameIndexIgnoresHDRSideDataNumbers() {
        #expect(FFmpegMediaProbe.frameTimestamp(in: "best_effort_timestamp_time=0.125000") == 0.125)
        for line in ["0.112", "max_luminance=1000", "red_x=0.68", "best_effort_timestamp_time=N/A"] {
            #expect(FFmpegMediaProbe.frameTimestamp(in: line) == nil)
        }
    }

    @Test func reopeningAndConcurrentRequestsReuseCompletedAnalysis() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        let cache = MediaAnalysisCache(directory: directory)
        let counter = AnalysisCounter()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<6 {
                group.addTask { try await cache.value(source: source, kind: "frames-v1") {
                    try await Task.sleep(for: .milliseconds(30))
                    return await counter.next()
                } }
            }
            for try await data in group { #expect(data == Data("analysis".utf8)) }
        }
        #expect(await counter.count == 1)
        let reopened = MediaAnalysisCache(directory: directory)
        _ = try await reopened.value(source: source, kind: "frames-v1") { await counter.next() }
        #expect(await counter.count == 1)
        try Data("replaced source".utf8).write(to: source, options: .atomic)
        _ = try await reopened.value(source: source, kind: "frames-v1") { await counter.next() }
        #expect(await counter.count == 2)
        _ = try await reopened.value(source: source, kind: "frames-v2") { await counter.next() }
        #expect(await counter.count == 3)
    }

    @Test func failedCancelledAndCorruptAnalysisIsNotReused() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        let cache = MediaAnalysisCache(directory: directory)
        await #expect(throws: AnalysisError.self) {
            _ = try await cache.value(source: source, kind: "frames-v1") { throw AnalysisError.emptyFrameIndex }
        }
        #expect(try await cache.status().count == 0)
        let job = Task { try await cache.value(source: source, kind: "frames-v1") {
            try await Task.sleep(for: .seconds(10))
            return Data("partial".utf8)
        } }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        #expect(try await cache.status().count == 0)
        _ = try await cache.value(source: source, kind: "frames-v1") { Data("complete".utf8) }
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        let restored = try await cache.value(source: source, kind: "frames-v1") { Data("rebuilt".utf8) }
        #expect(restored == Data("rebuilt".utf8))
        #expect(try await cache.clear(.all).removedFileCount == 1)
        #expect(try await cache.status().bytes == 0)
    }

    @Test func unavailableCacheStorageDoesNotBlockAnalysis() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file cannot serve as the cache directory.
        let cache = MediaAnalysisCache(directory: source)
        let data = try await cache.value(source: source, kind: "frames-v1") { Data("complete".utf8) }
        #expect(data == Data("complete".utf8))
        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }

    @Test func analysisStorageStaysWithinItsBudget() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaAnalysisCache(directory: root.appendingPathComponent("cache"), maximumByteCount: 400)
        for index in 0..<5 {
            _ = try await cache.value(source: source, kind: "kind-\(index)") { Data(repeating: 1, count: 120) }
        }
        #expect(try await cache.status().bytes <= 400)
    }

    @Test @MainActor func clearingAnAbsentMarkerAlsoClearsAStalePlayerBoundary() {
        let model = VideoPlayerViewModel()
        model.player.isMuted = true
        let item = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: item)
        item.forwardPlaybackEndTime = CMTime(seconds: 0.112, preferredTimescale: 48_000)
        item.reversePlaybackEndTime = CMTime(seconds: 0.05, preferredTimescale: 48_000)
        #expect(model.outMarker == nil)
        model.clearOut()
        model.clearIn()
        #expect(!item.forwardPlaybackEndTime.isValid)
        #expect(!item.reversePlaybackEndTime.isValid)
        model.closeMedia()
    }

    @Test func invalidSavedRangesAreRejectedButShortEditsRemainValid() throws {
        let duration = ProjectTime(seconds: 5.84)
        let short = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 0.112)))
        let opening = try ClipEditorOpeningConfiguration.make(segments: [short], sourceDuration: duration)
        #expect(opening.playbackSegments == nil)
        #expect(opening.outMarker == short.sourceRange.end)
        for range in [
            ProjectTimeRange(start: ProjectTime(seconds: -1), duration: ProjectTime(seconds: 2)),
            ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 6)),
            ProjectTimeRange(start: .zero, duration: .zero)
        ] {
            #expect(throws: (any Error).self) {
                try ClipEditorOpeningConfiguration.make(segments: [SourceSegment(sourceRange: range)], sourceDuration: duration)
            }
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Movies/proClips/Clips/buddy_pullAway.mov")))
    @MainActor func importedPullAwayProjectReopensAfterClearingSavedShortSelection() async throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/proClips/Clips/buddy_pullAway.mov")
        var imported = try await ProjectImportCoordinator.importAsset(at: url)
        #expect(imported.duration.seconds > 5.8)
        #expect(imported.sourceEdit.count == 1)
        #expect(imported.sourceEdit[0].sourceRange.start == .zero)
        #expect(imported.sourceEdit[0].duration == imported.duration)
        // Reproduce the old project's persisted range without changing the user's project.
        imported.sourceEdit = [SourceSegment(sourceRange: ProjectTimeRange(
            start: .zero, duration: ProjectTime(seconds: 0.1122666667)))]
        var project = TrimatoProject(name: "PullAway regression")
        project.media = [imported]
        for _ in 0..<2 {
            let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
            let controller = ProjectController(document: ProjectDocument(project: reopened))
            let asset = try #require(reopened.media.first)
            let source = try #require(try await controller.preparedMediaSource(for: asset))
            let opening = try ClipEditorOpeningConfiguration.make(segments: asset.sourceEdit, sourceDuration: asset.duration)
            let model = VideoPlayerViewModel()
            model.player.isMuted = true
            defer { model.closeMedia() }
            model.load(url: url, sourceSegments: opening.playbackSegments, preparedSource: source,
                       initialInMarker: opening.inMarker, initialOutMarker: opening.outMarker)
            for _ in 0..<600 where model.isLoadingMedia { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.mediaOpenErrorMessage == nil)
            #expect(model.duration > 5.8)
            #expect(model.outMarker == opening.outMarker?.cmTime)
            model.clearIn()
            model.clearOut()
            #expect(model.placementSourceSegments.reduce(0) { $0 + $1.duration.seconds } > 5.8)
            let item = try #require(model.player.currentItem)
            for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
            #expect(item.status == .readyToPlay)
            #expect(await model.player.seek(to: CMTime(seconds: 5, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero))
            model.togglePlayPause()
            for _ in 0..<60 where model.player.currentTime().seconds < 5.3 { try await Task.sleep(for: .milliseconds(50)) }
            model.player.pause()
            #expect(model.player.currentTime().seconds >= 5.3)
            project.media[0].sourceEdit = model.placementSourceSegments
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Movies/proClips/Clips/buddy_pullAway.mov")))
    @MainActor func pullAwayReopensAtFullDurationAndSeeksBeyondTheOldBoundary() async throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/proClips/Clips/buddy_pullAway.mov")
        for _ in 0..<2 {
            let model = VideoPlayerViewModel()
            model.player.isMuted = true
            defer { model.closeMedia() }
            model.load(url: url)
            for _ in 0..<600 where model.isLoadingMedia { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.mediaOpenErrorMessage == nil)
            #expect(model.duration > 5.8)
            #expect(model.inMarker == nil && model.outMarker == nil)
            let item = try #require(model.player.currentItem)
            model.setOutMarker(at: CMTime(seconds: 0.112, preferredTimescale: 48_000))
            model.clearOut()
            #expect(!item.forwardPlaybackEndTime.isValid)
            for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
            #expect(item.status == .readyToPlay)
            let sought = await model.player.seek(to: CMTime(seconds: 5, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            #expect(sought)
            #expect(model.player.currentTime().seconds > 4.9)
            model.togglePlayPause()
            for _ in 0..<60 where model.player.currentTime().seconds < 5.3 {
                try await Task.sleep(for: .milliseconds(50))
            }
            model.togglePlayPause()
            #expect(model.player.currentTime().seconds >= 5.3)
            let frames = try await FFmpegMediaProbe.frameTimestamps(url: url)
            #expect(frames.count == 140)
            #expect(frames.last?.seconds ?? 0 > 5.7)
        }
    }
}
