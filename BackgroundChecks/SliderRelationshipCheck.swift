import AppKit
import SwiftUI
@testable import Trimato

@main struct SliderRelationshipCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        for feedback in TimecodeFeedback.allCases {
            for custom in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let slider: NSSlider
                if custom {
                    let playhead = NativePlayheadSlider.PlayheadSlider()
                    playhead.cell = NativePlayheadSlider.PlayheadCell()
                    slider = playhead
                } else { slider = NSSlider() }
                slider.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
                slider.minValue = 0; slider.maxValue = 1
                slider.cell?.setAccessibilityLabel("Clip playhead")
                let other = NSButton(title: "Other control", target: nil, action: nil)
                other.frame = NSRect(x: 0, y: 40, width: 120, height: 30)
                window.contentView?.addSubview(slider)
                window.contentView?.addSubview(other)
                func snapshot(_ phase: String) async throws {
                    try await Task.sleep(for: .milliseconds(30))
                    precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
                    print("CASE custom=\(custom) feedback=\(feedback) phase=\(phase)")
                    print("CONTROL " + AccessibilityRelationshipProbe.report(slider))
                    if let cell = slider.cell { print("CELL " + AccessibilityRelationshipProbe.report(cell)) }
                    print("WINDOW FOCUS " + String(describing: window.firstResponder))
                }
                slider.isEnabled = false
                if let cell = slider.cell as? NativePlayheadSlider.PlayheadCell {
                    cell.updateSpokenValue(format: { _ in "00:00" }, feedback: feedback, isMoving: { false })
                }
                try await snapshot("disabled before preparation")
                slider.isEnabled = true
                precondition(window.makeFirstResponder(slider))
                precondition(window.firstResponder === slider)
                try await snapshot("first keyboard entry")
                slider.doubleValue = 0.25
                if let cell = slider.cell as? NativePlayheadSlider.PlayheadCell {
                    cell.updateSpokenValue(format: { _ in "00:25" }, feedback: feedback, isMoving: { false })
                }
                try await snapshot("value settling")
                try await Task.sleep(for: .milliseconds(300))
                try await snapshot("value settled")
                precondition(window.makeFirstResponder(other))
                try await snapshot("keyboard focus away")
                precondition(window.makeFirstResponder(slider))
                try await snapshot("keyboard return")
                (slider.cell as? NativePlayheadSlider.PlayheadCell)?.cancelPendingValue()
            }
        }
        print("COMPLETE: native and Trimato slider relationships across preparation, entry, value changes, and keyboard return. VoiceOver navigation was not simulated.")
    }
}
