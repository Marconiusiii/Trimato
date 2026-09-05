import Testing
@testable import Trimato

struct OperationProgressTests {
    @Test @MainActor func progressSessionCarriesUpdatesIntoItsWindow() {
        let session = OperationProgressWindowSession(operation: OperationProgress(
            title: "Preparing Project",
            progress: 0.1,
            detail: "Loading media"
        ), postsAnnouncements: false)

        session.update(OperationProgress(
            title: "Preparing Project",
            progress: 0.8,
            detail: "Preparing timeline"
        ))

        #expect(session.title == "Preparing Project")
        #expect(session.progress == 0.8)
        #expect(session.detail == "Preparing timeline")
        #expect(!session.isFinished)
    }

    @Test @MainActor func completedSessionRunsItsDismissalExactlyOnce() {
        let session = OperationProgressWindowSession(
            operation: OperationProgress(title: "Applying Filter"),
            postsAnnouncements: false
        )
        var dismissalCount = 0

        session.finish(outcome: .completed) { dismissalCount += 1 }
        session.finish(outcome: .failed) { dismissalCount += 10 }
        session.completeDismissal()
        session.completeDismissal()

        #expect(session.isFinished)
        #expect(session.outcome == .completed)
        #expect(dismissalCount == 1)
    }

    @Test @MainActor func cancellingDisablesCancelAndPreservesCancelledOutcome() {
        var cancellationCount = 0
        let session = OperationProgressWindowSession(operation: OperationProgress(
            title: "Applying Filter",
            cancel: { cancellationCount += 1 }
        ), postsAnnouncements: false)

        session.cancel()
        session.cancel()
        session.finish(outcome: .completed, dismissed: {})

        #expect(cancellationCount == 1)
        #expect(!session.canCancel)
        #expect(session.outcome == .cancelled)
    }

    @Test func speaksMilestonesWithoutAWindowOrFocusedControl() {
        var speech = OperationProgressAnnouncements()
        let messages = [0.0, 0.02, 0.1, 0.19, 0.35, 0.34, 0.9, 1.0].compactMap {
            speech.update(progress: $0)
        }
        #expect(messages == ["0 percent.", "10 percent.", "30 percent.", "90 percent."])
        #expect(speech.finish(outcome: .completed) == "100 percent, complete.")
        #expect(speech.update(progress: 0.5) == nil)
        #expect(speech.finish(outcome: .completed) == nil)
    }

    @Test func cancellationNeverAnnouncesCompletionAndRetryStartsFresh() {
        var cancelled = OperationProgressAnnouncements()
        _ = cancelled.update(progress: 0.45)
        #expect(cancelled.finish(outcome: .cancelled) == "Cancelled.")
        #expect(cancelled.update(progress: 1) == nil)
        var retry = OperationProgressAnnouncements()
        #expect(retry.update(progress: 0.1) == "10 percent.")
        #expect(retry.finish(outcome: .failed) == "Failed.")
    }

    @Test func indeterminateWorkHasNoInventedPercentage() {
        var speech = OperationProgressAnnouncements()
        #expect(speech.update(progress: nil) == nil)
        #expect(speech.update(progress: .nan) == nil)
        #expect(speech.update(progress: .infinity) == nil)
        #expect(speech.finish(outcome: .completed) == "Complete.")
    }
    @Test func routinePreviewCompletionIsSilentButProgressAndFailuresRemainAvailable() {
        var preview = OperationProgressAnnouncements()
        #expect(preview.update(progress: 0.4) == "40 percent.")
        #expect(preview.finish(outcome: .completed, announceCompletion: false) == nil)
        #expect(preview.update(progress: 1) == nil)
        var failed = OperationProgressAnnouncements()
        #expect(failed.finish(outcome: .failed, announceCompletion: false) == "Failed.")
        var cancelled = OperationProgressAnnouncements()
        #expect(cancelled.finish(outcome: .cancelled, announceCompletion: false) == "Cancelled.")
    }

}
