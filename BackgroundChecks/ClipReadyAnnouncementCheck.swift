import Foundation
import Darwin
@testable import Trimato

@main struct ClipReadyAnnouncementCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
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
        print("PASS: cached and uncached entry, progress dismissal, inactive window, one announcement, cancellation, and failure")
    }
}
