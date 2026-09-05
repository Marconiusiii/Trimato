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
            speech.update(title: "Applying Filter", progress: $0)
        }
        #expect(messages == ["Applying Filter, 0 percent.", "Applying Filter, 10 percent.",
                             "Applying Filter, 30 percent.", "Applying Filter, 90 percent."])
        #expect(speech.finish(title: "Applying Filter", outcome: .completed) ==
                "Applying Filter, 100 percent, complete.")
        #expect(speech.update(title: "Applying Filter", progress: 0.5) == nil)
        #expect(speech.finish(title: "Applying Filter", outcome: .completed) == nil)
    }

    @Test func cancellationNeverAnnouncesCompletionAndRetryStartsFresh() {
        var cancelled = OperationProgressAnnouncements()
        _ = cancelled.update(title: "Updating Clip Preview", progress: 0.45)
        #expect(cancelled.finish(title: "Updating Clip Preview", outcome: .cancelled) ==
                "Updating Clip Preview, cancelled.")
        #expect(cancelled.update(title: "Updating Clip Preview", progress: 1) == nil)
        var retry = OperationProgressAnnouncements()
        #expect(retry.update(title: "Updating Clip Preview", progress: 0.1) ==
                "Updating Clip Preview, 10 percent.")
        #expect(retry.finish(title: "Updating Clip Preview", outcome: .failed) ==
                "Updating Clip Preview, failed.")
    }

    @Test func indeterminateWorkHasNoInventedPercentage() {
        var speech = OperationProgressAnnouncements()
        #expect(speech.update(title: "Preparing Waveform", progress: nil) == "Preparing Waveform.")
        #expect(speech.update(title: "Preparing Waveform", progress: .nan) == nil)
        #expect(speech.update(title: "Preparing Waveform", progress: .infinity) == nil)
        #expect(speech.finish(title: "Preparing Waveform", outcome: .completed) == "Preparing Waveform, complete.")
    }
    @Test func routinePreviewCompletionIsSilentButProgressAndFailuresRemainAvailable() {
        var preview = OperationProgressAnnouncements()
        #expect(preview.update(title: "Updating Clip Preview", progress: 0.4) == "Updating Clip Preview, 40 percent.")
        #expect(preview.finish(title: "Updating Clip Preview", outcome: .completed, announceCompletion: false) == nil)
        #expect(preview.update(title: "Updating Clip Preview", progress: 1) == nil)
        var failed = OperationProgressAnnouncements()
        #expect(failed.finish(title: "Updating Clip Preview", outcome: .failed, announceCompletion: false) ==
                "Updating Clip Preview, failed.")
        var cancelled = OperationProgressAnnouncements()
        #expect(cancelled.finish(title: "Updating Clip Preview", outcome: .cancelled, announceCompletion: false) ==
                "Updating Clip Preview, cancelled.")
    }

}
