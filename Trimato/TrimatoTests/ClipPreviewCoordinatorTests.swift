import AVFoundation
import AppKit
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct ClipPreviewCoordinatorTests {
    private enum Failure: Error { case render }

    private final class ProgressPresenter: ClipPreviewProgressPresenting {
        var sessions: [UUID: OperationProgressWindowSession] = [:]
        var outcomes: [OperationProgressOutcome] = []

        func present(_ operation: OperationProgress, returnWindow: NSWindow?) -> UUID {
            let session = OperationProgressWindowSession(operation: operation, postsAnnouncements: false)
            sessions[session.id] = session
            return session.id
        }

        func update(_ operation: OperationProgress, id: UUID) -> Bool {
            guard let session = sessions[id] else { return false }
            session.update(operation)
            return true
        }

        func finish(id: UUID, outcome: OperationProgressOutcome, dismissed: @escaping () -> Void) {
            sessions[id]?.finish(outcome: outcome, dismissed: dismissed)
            outcomes.append(outcome)
        }
    }

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
        let presentation = ProgressPresenter()

        lazy var coordinator = ClipPreviewCoordinator(render: { request, progress in
            self.renderCount += 1
            self.progress[request.source] = progress
            return try await withCheckedThrowingContinuation { self.renders[request.source] = $0 }
        }, prepare: { url, _ in
            if self.holdPreparation {
                return try await withCheckedThrowingContinuation { self.preparations[url] = $0 }
            }
            return AVMutableComposition()
        }, remove: { self.removed.append($0) }, progressPresenter: presentation)

        func update(_ request: ClipPreviewCoordinator.Request, force: Bool = false) {
            coordinator.update(request, debounce: false, force: force, showsProgress: true,
                               readiness: { self.ready = $0 },
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
        #expect(h.presentation.outcomes == [.failed])

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
        #expect(abs(h.coordinator.progress - 0.4 * 0.95) < 0.000_001)
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
        #expect(h.presentation.outcomes == [.cancelled])
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
        #expect(h.presentation.outcomes == [.completed])
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
    @Test func invalidOrRegressingProgressCannotCorruptTheCurrentOperation() async throws {
        let h = Harness()
        let changed = request()
        h.update(changed)
        try await waitFor { h.renders[changed.source] != nil }
        h.progress[changed.source]?(0.6)
        h.progress[changed.source]?(.nan)
        h.progress[changed.source]?(.infinity)
        h.progress[changed.source]?(0.2)
        #expect(abs(h.coordinator.progress - 0.6 * 0.95) < 0.000_001)
        h.coordinator.cancel()
        h.progress[changed.source]?(1)
        #expect(abs(h.coordinator.progress - 0.6 * 0.95) < 0.000_001)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.removed == [changed.source] }
        #expect(h.committed.isEmpty)
    }

    @Test(arguments: [false, true])
    func progressFinishesAfterInstallationWithoutAnEditorViewUpdate(audio: Bool) async throws {
        let h = Harness()
        h.holdPreparation = true
        let changed = request(audio: audio)
        h.update(changed)
        let session = try #require(h.presentation.sessions.values.first)
        try await waitFor { h.renders[changed.source] != nil }
        h.progress[changed.source]?(1)
        #expect(session.progress == 0.95)
        #expect(!session.isFinished)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.preparations[changed.source] != nil }
        #expect(!session.isFinished)
        #expect(h.committed.isEmpty)
        h.preparations.removeValue(forKey: changed.source)?.resume(returning: AVMutableComposition())
        try await waitFor { session.isFinished }
        #expect(h.committed == [changed.source])
        #expect(h.ready)
        #expect(session.progress == 1)
        #expect(!session.canCancel)
        #expect(h.presentation.outcomes == [.completed])
        h.progress[changed.source]?(0.2)
        h.coordinator.cancel()
        #expect(session.progress == 1)
        #expect(h.presentation.outcomes == [.completed])
    }

    @Test func automaticPreviewPreparationDoesNotPresentAnEffectsWindow() async throws {
        let h = Harness()
        let changed = request()
        h.coordinator.update(changed, debounce: false, readiness: { h.ready = $0 },
                             restoreOriginal: {}, commit: { _, _, _ in })
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.ready }
        #expect(h.presentation.sessions.isEmpty)
        #expect(h.presentation.outcomes.isEmpty)
    }

    @Test func cancellationClosesProgressAndRejectsLateCompletion() async throws {
        let h = Harness()
        let changed = request()
        h.update(changed)
        let session = try #require(h.presentation.sessions.values.first)
        try await waitFor { h.renders[changed.source] != nil }
        session.cancel()
        #expect(session.isFinished)
        #expect(session.outcome == .cancelled)
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.removed == [changed.source] }
        #expect(h.committed.isEmpty)
        #expect(h.presentation.outcomes == [.cancelled])
    }

    @Test func failedPreparationFinishesProgressAndRetryGetsANewSession() async throws {
        let h = Harness()
        h.holdPreparation = true
        let changed = request()
        h.update(changed)
        let firstSession = try #require(h.presentation.sessions.values.first)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.preparations[changed.source] != nil }
        h.preparations.removeValue(forKey: changed.source)?.resume(throwing: Failure.render)
        try await waitFor { firstSession.isFinished }
        #expect(firstSession.outcome == .failed)
        h.holdPreparation = false
        h.update(changed, force: true)
        #expect(h.presentation.sessions.count == 2)
        try await waitFor { h.renders[changed.source] != nil }
        h.finish(changed, result: .success(changed.source))
        try await waitFor { h.ready }
        #expect(h.presentation.outcomes == [.failed, .completed])
    }

    @Test func supersededWorkCannotDismissTheCurrentProgressSession() async throws {
        let h = Harness()
        let first = request("first")
        let second = request("second")
        h.update(first)
        try await waitFor { h.renders[first.source] != nil }
        h.update(second)
        try await waitFor { h.renders[second.source] != nil }
        h.finish(first, result: .success(first.source))
        try await waitFor { h.removed == [first.source] }
        #expect(h.presentation.outcomes.isEmpty)
        #expect(h.presentation.sessions.count == 1)
        h.finish(second, result: .success(second.source))
        try await waitFor { h.ready }
        #expect(h.presentation.outcomes == [.completed])
    }
}
