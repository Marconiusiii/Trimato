import AVFoundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct ClipPreviewCoordinatorTests {
    private enum Failure: Error { case render }

    @MainActor
    private final class Harness {
        var renders: [URL: CheckedContinuation<URL, Error>] = [:]
        var preparations: [URL: CheckedContinuation<AVAsset, Error>] = [:]
        var progress: [URL: @MainActor @Sendable (Double) -> Void] = [:]
        var committed: [URL] = []
        var removed: [URL] = []
        var ready = true
        var restored = 0
        var renderCount = 0
        var holdPreparation = false

        lazy var coordinator = ClipPreviewCoordinator(render: { request, progress in
            self.renderCount += 1
            self.progress[request.source] = progress
            return try await withCheckedThrowingContinuation { self.renders[request.source] = $0 }
        }, prepare: { url, _ in
            if self.holdPreparation {
                return try await withCheckedThrowingContinuation { self.preparations[url] = $0 }
            }
            return AVMutableComposition()
        }, remove: { self.removed.append($0) })

        func update(_ request: ClipPreviewCoordinator.Request, force: Bool = false) {
            coordinator.update(request, debounce: false, force: force, readiness: { self.ready = $0 },
                               restoreOriginal: { self.restored += 1 },
                               commit: { _, url, _ in self.committed.append(url) })
        }

        func finish(_ request: ClipPreviewCoordinator.Request, result: Result<URL, Error>) {
            renders.removeValue(forKey: request.source)?.resume(with: result)
        }
    }

    private func request(_ name: String = "a", filtered: Bool = true, audio: Bool = false) -> ClipPreviewCoordinator.Request {
        .init(source: URL(fileURLWithPath: "/tmp/\(name).mov"),
              filters: filtered ? [ClipFilter(kind: audio ? .backgroundNoise : .blackAndWhite)] : [],
              audio: audio,
              segments: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))],
              audioSettings: audio ? .neutral : nil)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate())
    }

    @Test(arguments: [false, true])
    func failedPreparationCanRetryWithoutDiscardingLastSuccessfulPreview(audio: Bool) async throws {
        let h = Harness()
        let original = request("original", filtered: false, audio: audio)
        h.update(original)
        let changed = request(audio: audio)
        h.update(changed)
        #expect(!h.ready)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .failure(Failure.render))
        try await waitFor { h.coordinator.errorMessage != nil }
        #expect(!h.ready)
        #expect(h.committed.isEmpty)
        #expect(h.coordinator.lastSuccessfulRequest == original)

        h.update(changed, force: true)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.ready }
        #expect(h.coordinator.state == .ready)
        #expect(h.coordinator.errorMessage == nil)
        #expect(h.committed == [changed.source])
        #expect(h.removed.isEmpty)
        #expect(h.coordinator.lastSuccessfulRequest == changed)
    }

    @Test func cancelledRenderCannotReplacePreviewAndCleansLateOutput() async throws {
        let h = Harness()
        let changed = request()
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        h.coordinator.cancel()
        #expect(h.coordinator.state == .cancelled)
        #expect(!h.ready)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.removed == [changed.source] }
        #expect(h.committed.isEmpty)
        #expect(h.coordinator.state == .cancelled)
    }

    @Test func supersededRenderCannotChangeProgressReadinessOrError() async throws {
        let h = Harness()
        let first = request("first")
        let second = request("second")
        h.update(first)
        try await waitFor { h.renders[first.source] != nil }
        h.update(second)
        try await waitFor { h.renders[second.source] != nil }
        h.progress[second.source]?(0.4)
        h.progress[first.source]?(0.9)
        #expect(h.coordinator.progress == 0.4)
        h.finish(first, result: .failure(Failure.render))
        h.finish(second, result: .success(second.source))
        try await waitFor { h.ready }
        #expect(h.committed == [second.source])
        #expect(h.coordinator.errorMessage == nil)
        #expect(h.coordinator.lastSuccessfulRequest == second)
    }

    @Test func supersededAssetPreparationCannotCommitOrDeleteTheNewOutput() async throws {
        let h = Harness()
        h.holdPreparation = true
        let first = request("first")
        let second = request("second")
        h.update(first)
        try await waitFor { h.renders[first.source] != nil }
        h.finish(first, result: .success(first.source))
        try await waitFor { h.preparations[first.source] != nil }
        h.update(second)
        try await waitFor { h.renders[second.source] != nil }
        h.finish(second, result: .success(second.source))
        try await waitFor { h.preparations[second.source] != nil }
        h.preparations.removeValue(forKey: second.source)?.resume(returning: AVMutableComposition())
        try await waitFor { h.ready }
        h.preparations.removeValue(forKey: first.source)?.resume(returning: AVMutableComposition())
        try await waitFor { h.removed == [first.source] }
        #expect(h.committed == [second.source])
        #expect(h.ready)
        #expect(h.coordinator.lastSuccessfulRequest == second)
    }

    @Test func closingDuringAssetPreparationRejectsLateCommit() async throws {
        let h = Harness()
        h.holdPreparation = true
        let changed = request()
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.preparations[changed.source] != nil }
        h.coordinator.reset()
        h.preparations.removeValue(forKey: changed.source)?.resume(returning: AVMutableComposition())
        try await waitFor { h.removed == [changed.source] }
        #expect(h.committed.isEmpty)
        #expect(h.coordinator.lastSuccessfulRequest == nil)
    }

    @Test func removingFiltersRecoversImmediatelyAndRejectsOutstandingWork() async throws {
        let h = Harness()
        let changed = request()
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        let original = request(filtered: false)
        h.update(original)
        #expect(h.ready)
        #expect(h.restored == 1)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.removed == [changed.source] }
        #expect(h.committed.isEmpty)
        #expect(h.coordinator.lastSuccessfulRequest == original)
        #expect(h.ready)
    }

    @Test func repeatedObservedChangesDoNotRestartTheSameRequest() async throws {
        let h = Harness()
        let changed = request()
        h.update(changed)
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        #expect(h.renderCount == 1)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.ready }
        h.update(changed)
        #expect(h.renderCount == 1)
    }

    @Test func failedAssetPreparationCleansOutputAndKeepsRecoveryAvailable() async throws {
        let h = Harness()
        h.holdPreparation = true
        let changed = request()
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.preparations[changed.source] != nil }
        h.preparations.removeValue(forKey: changed.source)?.resume(throwing: Failure.render)
        try await waitFor { h.coordinator.errorMessage != nil }
        #expect(h.removed == [changed.source])
        #expect(h.committed.isEmpty)
        #expect(!h.ready)
        h.update(request(filtered: false))
        #expect(h.ready)
        #expect(h.coordinator.errorMessage == nil)
    }
}
