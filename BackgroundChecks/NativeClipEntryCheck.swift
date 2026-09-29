import AppKit
import SwiftUI
@testable import Trimato

@MainActor final class EntryWindow: NSWindow {
    var sliderRequests = 0
    var rejectsSlider = false
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NativePlayheadSlider.PlayheadSlider {
            sliderRequests += 1
            if rejectsSlider { return false }
        }
        return super.makeFirstResponder(responder)
    }
}
@main struct NativeClipEntryCheck {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let window = EntryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let slider = NativePlayheadSlider.PlayheadSlider(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        slider.cell = NativePlayheadSlider.PlayheadCell()
        slider.cell?.setAccessibilityLabel("Clip playhead")
        slider.cell?.setAccessibilityIdentifier(ClipEditorAccessibilityIdentifier.playhead)
        let other = NSTextView(frame: NSRect(x: 0, y: 40, width: 300, height: 30))
        window.contentView?.addSubview(slider)
        window.contentView?.addSubview(other)
        precondition(window.makeFirstResponder(nil))
        window.sliderRequests = 0
        var completed = 0
        var prepared = 0
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(20))
            precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
        }
        let inactive = ClipEditorEntryFocus()
        inactive.update(.init(owner: inactive, ready: true, willEnter: { prepared += 1 }, completed: { completed += 1 }), slider: slider)
        try await settle()
        precondition(completed == 0 && prepared == 0 && window.sliderRequests == 0, "Inactive window received entry")
        inactive.disconnect(slider: slider)

        // Only availability is supplied by the test. The responder request uses real AppKit.
        var available = false
        let entry = ClipEditorEntryFocus(isWindowAvailable: { _ in available })
        func update(_ ready: Bool) {
            entry.update(.init(owner: entry, ready: ready, willEnter: { prepared += 1 }, completed: {
                precondition(window.firstResponder === slider, "Completion preceded native focus")
                completed += 1
            }), slider: slider)
        }
        update(true)
        try await settle()
        precondition(window.sliderRequests == 0 && completed == 0)
        available = true
        update(false)
        try await settle()
        precondition(window.sliderRequests == 0 && completed == 0, "Unready media received entry")
        slider.isEnabled = false
        update(true)
        try await settle()
        precondition(window.sliderRequests == 0 && completed == 0, "Disabled slider received entry")
        slider.isEnabled = true
        window.rejectsSlider = true
        update(true)
        try await settle()
        precondition(window.sliderRequests == 1 && completed == 0, "Rejected focus completed entry")
        window.rejectsSlider = false
        update(true)
        try await settle()
        precondition(window.sliderRequests == 2 && completed == 1 && window.firstResponder === slider)
        for _ in 0..<10 { update(true) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await settle()
        precondition(window.sliderRequests == 2 && completed == 1, "Entry repeated after success")
        precondition(window.makeFirstResponder(other))
        update(true)
        try await settle()
        precondition(window.firstResponder === other && completed == 1, "Entry stole subsequent user focus")
        entry.disconnect(slider: slider)

        let cancelled = ClipEditorEntryFocus(isWindowAvailable: { _ in true })
        cancelled.update(.init(owner: cancelled, ready: true, willEnter: {}, completed: { completed += 1 }), slider: slider)
        cancelled.disconnect(slider: slider)
        try await settle()
        precondition(window.firstResponder === other && completed == 1, "Disconnected target received late entry")

        precondition(window.makeFirstResponder(slider))
        let previousRequests = window.sliderRequests
        let alreadyFocused = ClipEditorEntryFocus(isWindowAvailable: { _ in true })
        alreadyFocused.update(.init(owner: alreadyFocused, ready: true, willEnter: {}, completed: { completed += 1 }), slider: slider)
        try await settle()
        precondition(completed == 2 && window.sliderRequests == previousRequests, "Already-focused slider received redundant request")
        alreadyFocused.disconnect(slider: slider)
        print("PASS: actual native responder, inactive/unready/disabled rejection, failed-request recovery, one completion, no repeated entry, no focus theft, teardown cancellation, and already-focused target")
        print("LIMITATION: window remained invisible and inactive; availability was injected for native request checks, and VoiceOver speech was not exercised")
        window.close()
    }
}
