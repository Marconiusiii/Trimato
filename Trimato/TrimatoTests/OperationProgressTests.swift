import AppKit
import Testing
@testable import Trimato

struct OperationProgressTests {
    @Test @MainActor func inactiveWindowNeverPresentsProgressAndCompletedWorkIsNotReplayed() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = OperationProgressBridge.Coordinator()
        defer { coordinator.invalidate(); window.close() }
        try #require(!window.isKeyWindow)

        coordinator.update(OperationProgress(title: "Applying Clip Effects", progress: 0.1),
                           outcome: .completed, completionPending: false, dismissed: {}, parent: window)
        #expect(window.attachedSheet == nil)
        coordinator.update(OperationProgress(title: "Applying Clip Effects", progress: 0.8),
                           outcome: .completed, completionPending: false, dismissed: {}, parent: window)
        #expect(window.attachedSheet == nil)
        coordinator.update(nil, outcome: .completed, completionPending: false, dismissed: {}, parent: window)

        // A queued native notification must not resurrect an already finished operation.
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        await Task.yield()
        #expect(window.attachedSheet == nil)
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
