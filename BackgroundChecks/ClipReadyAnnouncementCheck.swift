import Foundation
import AppKit
import Darwin
@testable import Trimato

@main struct ClipReadyAnnouncementCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() async {
        verify(NSApp == nil, "Background check must not create an application")
        for outcome in [OperationProgressOutcome.completed, .cancelled, .failed] {
            var operation = OperationProgress(
                title: "Preparing Clip", detail: "Inspecting media",
                announceCompletion: false, announcesUpdates: false
            )
            let session = OperationProgressWindowSession(operation: operation, postsAnnouncements: false)
            operation.detail = "Preparing waveform"
            session.update(operation)
            var dismissed = false
            session.finish(outcome: outcome) { dismissed = true }
            operation.detail = "Stale loading status"
            session.update(operation)
            await Task.yield()
            verify(session.detail == "Preparing waveform", "Finished session accepted a late update")
            verify(session.isFinished && session.outcome == outcome, "Completion outcome changed")
            session.completeDismissal()
            verify(dismissed, "Completion lost the existing dismissal handoff")
        }
        var legacy = OperationProgressAnnouncements()
        verify(legacy.update(progress: 0.5) == "50 percent.", "Existing progress speech changed")
        verify(legacy.finish(outcome: .completed) == "100 percent, complete.", "Existing completion speech changed")
        let quickLoad = ClipLoadingPresentation()
        quickLoad.begin()
        quickLoad.finish()
        let replacedLoad = ClipLoadingPresentation()
        replacedLoad.begin()
        replacedLoad.begin()
        replacedLoad.finish()
        let slowLoad = ClipLoadingPresentation()
        slowLoad.begin()
        verify(!slowLoad.isPresented, "Slow load showed progress immediately")
        await slowLoad.delayTask?.value
        verify(!quickLoad.isPresented, "Completed quick load showed delayed progress")
        verify(!replacedLoad.isPresented, "Replaced or cancelled load showed stale progress")
        verify(slowLoad.isPresented, "Long load did not show progress")
        slowLoad.finish()
        verify(slowLoad.isPresented, "Entry unblocked before the progress window returned")
        slowLoad.dismissed()
        verify(!slowLoad.isPresented, "Dismissal did not unblock entry")
        for cached in [true, false] {
            var entry = ClipEditorEntryFocusPolicy()
            var announcement = ClipReadyAnnouncementPolicy()
            if !cached {
                verify(!entry.consume(ready: false, isKeyWindow: true, hasSheet: true), "Entered while preparing")
            }
            verify(!entry.consume(ready: true, isKeyWindow: true, hasSheet: true), "Entered before progress dismissal")
            verify(!entry.consume(ready: true, isKeyWindow: false, hasSheet: false), "Entered an inactive window")
            verify(entry.consume(ready: true, isKeyWindow: true, hasSheet: false), "Ready entry was lost")
            verify(announcement.message(ready: true, outcome: .completed) == "Clip Ready", "Ready announcement was lost")
            verify(announcement.message(ready: true, outcome: .completed) == nil, "Repeated ready announcement")
            verify(!entry.consume(ready: true, isKeyWindow: true, hasSheet: false), "Later dismissal repeated entry")
        }
        for outcome in [OperationProgressOutcome.cancelled, .failed] {
            var announcement = ClipReadyAnnouncementPolicy()
            verify(announcement.message(ready: true, outcome: outcome) == nil, "Unsuccessful load announced ready")
        }
        var announcement = ClipReadyAnnouncementPolicy()
        verify(announcement.message(ready: false, outcome: .completed) == nil, "Unprepared clip announced ready")
        verify(announcement.message(ready: true, outcome: .completed) == "Clip Ready", "Early update consumed readiness")
        verify(NSApp == nil, "Background check created an application")
        print("PASS: quiet quick loads, delayed long loads, cancellation, dismissal gating, late update rejection, cached and uncached entry, progress dismissal, inactive window, one announcement, cancellation, and failure")
    }
}
