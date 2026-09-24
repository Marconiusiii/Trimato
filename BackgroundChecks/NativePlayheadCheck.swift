import AppKit
import SwiftUI
@testable import Trimato

@MainActor final class PlayheadState: ObservableObject {
    @Published var fraction = 0.37
    @Published var feedback = TimecodeFeedback.whenStopped
    @Published var style = TimecodeStyle.numeric
    @Published var enabled = true
    @Published var moving = false
    @Published var keyboardRequest = false
    var writes = 0
    var timecode: String {
        AppPreferences.spokenTimecode(seconds: fraction * 100, frameRate: 30, milliseconds: true, style: style)
    }
}
struct PlayheadHost: View {
    @ObservedObject var state: PlayheadState
    let labeled: Bool
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool
    var body: some View {
        Group {
            if labeled { LabeledContent("Project playhead") { slider } }
            else { slider }
        }
    }
    private var slider: some View {
        NativePlayheadSlider(value: Binding(get: { state.fraction }, set: { state.writes += 1; state.fraction = $0 }),
            step: 1.0 / 3000, label: "Project playhead", identifier: "check.playhead",
            spokenValue: { fraction in
                AppPreferences.spokenTimecode(seconds: fraction * 100, frameRate: 30, milliseconds: true, style: state.style)
            }, feedback: state.feedback, isMoving: { state.moving })
            .disabled(!state.enabled)
            .focused($keyboardFocused)
            .accessibilityFocused($voiceOverFocused)
            .frame(width: 400, height: 40)
            .onChange(of: state.keyboardRequest) { _, value in keyboardFocused = value }
    }
}
@main struct NativePlayheadCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        for labeled in [false, true] {
        let state = PlayheadState()
        let host = NSHostingView(rootView: PlayheadHost(state: state, labeled: labeled).environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(25))
            precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
        }
        func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>(), found: [NSObject] = []
            func walk(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                if object.responds(to: NSSelectorFromString("accessibilityRole")),
                   object.value(forKey: "accessibilityRole") as? String == "AXSlider" { found.append(object) }
                if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(walk) }
            }
            walk(host)
            return found
        }
        func native(_ view: NSView) -> NativePlayheadSlider.PlayheadSlider? {
            if let slider = view as? NativePlayheadSlider.PlayheadSlider { return slider }
            return view.subviews.lazy.compactMap(native).first
        }
        try await settle()
        guard let slider = native(host) else { fatalError("Native slider was not installed") }
        let cell = slider.cell as! NativePlayheadSlider.PlayheadCell
        let identity = ObjectIdentifier(cell)
        for feedback in TimecodeFeedback.allCases {
            state.feedback = feedback
            for style in TimecodeStyle.allCases {
                state.style = style
                for position in [0.0, 0.12347, 0.37, 0.85, 1.0] {
                    state.fraction = position
                    try await settle()
                    try await Task.sleep(for: .milliseconds(300))
                    let found = elements()
                    precondition(found.count == 1, "Expected one native slider; found \(found.count)")
                    let element = found[0]
                    precondition(ObjectIdentifier(element) == identity, "Clock update replaced the accessible slider")
                    precondition(element.value(forKey: "accessibilityLabel") as? String == "Project playhead")
                    precondition(element.value(forKey: "accessibilityIdentifier") as? String == "check.playhead")
                    let value = element.value(forKey: "accessibilityValue")
                    let description = element.value(forKey: "accessibilityValueDescription")
                    if feedback == .whenStopped {
                        precondition(value as? String == state.timecode && description as? String == state.timecode)
                    } else {
                        precondition(value == nil && description == nil, "Quiet mode exposed a value: \(String(describing: value))")
                    }
                    precondition(!(value is NSNumber), "Native numeric fallback remains")
                    precondition(slider.doubleValue == position)
                }
            }
            state.fraction = 0.5
            try await settle()
            let writes = state.writes
            precondition(cell.accessibilityPerformIncrement())
            precondition(abs(state.fraction - (0.5 + 1.0 / 3000)) < 1e-10)
            precondition(cell.accessibilityValue() == nil, "Adjustment spoke before settling")
            try await settle()
            precondition(cell.accessibilityPerformDecrement())
            precondition(abs(state.fraction - 0.5) < 1e-10 && state.writes == writes + 2)
            try await settle()
            if feedback != .whenStopped { precondition(cell.accessibilityValue() == nil && cell.accessibilityValueDescription() == nil) }
        }
        print("PASS: 30 native accessibility cases; no numeric fallback; quiet values remain absent during updates and frame adjustments; stable slider identity")
        state.feedback = .whenStopped
        state.moving = true
        for tick in 1...60 {
            state.fraction = Double(tick) / 100
            try await settle()
            precondition(cell.accessibilityValue() == nil && cell.accessibilityValueDescription() == nil,
                         "Playback exposed a spoken value")
        }
        state.moving = false
        try await settle()
        precondition(cell.accessibilityValue() == nil, "Stop spoke before settling")
        try await Task.sleep(for: .milliseconds(300))
        precondition(cell.accessibilityValue() as? String == state.timecode)
        for position in [0.3, 0.4, 0.5] {
            state.fraction = position
            try await settle()
            precondition(cell.accessibilityValue() == nil, "Jog burst exposed an intermediate value")
        }
        try await Task.sleep(for: .milliseconds(300))
        precondition(cell.accessibilityValue() as? String == state.timecode, "Final jog position was not exposed")
        state.fraction = 0.6; try await settle()
        state.moving = true; try await settle()
        try await Task.sleep(for: .milliseconds(300))
        precondition(cell.accessibilityValue() == nil, "Playback did not cancel pending feedback")
        state.moving = false; try await settle()
        state.feedback = .onDemand; try await settle()
        try await Task.sleep(for: .milliseconds(300))
        precondition(cell.accessibilityValue() == nil, "On Demand did not cancel pending feedback")
        print("PASS: playback exposes no timecode; stopped and jog bursts settle to one final value; playback and preference changes cancel pending values")
        cell.setAccessibilityValue(NSNumber(value: 0.25))
        precondition(state.fraction == 0.25, "Native accessibility setter did not seek")
        try await settle()
        state.fraction = 0; try await settle()
        let writes = state.writes
        precondition(cell.accessibilityPerformDecrement() && state.writes == writes)
        state.fraction = 1; try await settle()
        precondition(cell.accessibilityPerformIncrement() && state.writes == writes)
        state.enabled = false; try await settle()
        precondition(!cell.accessibilityPerformIncrement() && !cell.accessibilityPerformDecrement())
        state.enabled = true; try await settle()
        state.keyboardRequest = true
        try await settle()
        if window.firstResponder === slider {
            print("PASS: SwiftUI keyboard focus reached the native slider in the inactive test window")
        } else {
            print("LIMITATION: inactive window did not resolve SwiftUI keyboard focus; native responder tested separately")
        }
        precondition(window.makeFirstResponder(slider))
        precondition(window.firstResponder === slider && !window.isKeyWindow && !app.isActive)
        window.makeFirstResponder(nil)
        print("PASS: endpoint bounds, disabled actions, and native keyboard responder; window remained unshown and inactive")
        window.close()
        }
    }
}
