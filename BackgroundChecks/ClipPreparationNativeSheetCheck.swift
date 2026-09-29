import AppKit
import SwiftUI
@testable import Trimato

@MainActor final class SheetCheckState: ObservableObject {
    @Published var operation: OperationProgress?
    @Published var pending = true
    var outcome = OperationProgressOutcome.completed
    var handoffs = 0
    var cancellations = 0
    func begin() {
        pending = true
        operation = .clipLoading(progress: 0.2, stage: "Indexing frames", cancel: { [weak self] in self?.cancellations += 1 })
    }
}
struct SheetCheckHost: View {
    @ObservedObject var state: SheetCheckState
    var body: some View {
        Text("Background sheet check")
            .frame(width: 480, height: 200)
            .clipPreparationSheet(state.operation, outcome: state.outcome, completionPending: state.pending) {
                state.handoffs += 1
            }
    }
}
@MainActor final class InvisibleSheetWindow: NSWindow {
    var attachments = 0
    var onAttach: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        // Prevent native sheet presentation from displaying anything on screen.
        // Do not replace beginSheet, endSheet, SwiftUI dismissal, or onDismiss.
        sheetWindow.alphaValue = 0
        sheetWindow.ignoresMouseEvents = true
        attachments += 1
        super.beginSheet(sheetWindow, completionHandler: handler)
        onAttach?()
    }
}
@main struct ClipPreparationNativeSheetCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func untouched() {
            precondition(!app.isActive, "Test application activated")
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground, "Foreground application changed")
            for window in app.windows where window.isVisible {
                precondition(window.alphaValue == 0, "Visible test window was not transparent")
            }
        }
        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                untouched()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            fatalError("Timed out: \(description)")
        }
        for outcome in [OperationProgressOutcome.completed, .cancelled, .failed] {
        for completeDuringAttachment in [false, true] {
            let state = SheetCheckState()
            state.outcome = outcome
            let window = InvisibleSheetWindow(contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentViewController = NSHostingController(rootView: SheetCheckHost(state: state))
            defer { window.orderOut(nil); window.close() }
            window.orderBack(nil)
            untouched()
            if completeDuringAttachment {
                window.onAttach = {
                    Task { @MainActor in state.operation = nil; state.pending = false }
                }
            }
            for cycle in 0..<2 {
                state.begin()
                try await waitFor("native attachment") { window.attachments == cycle + 1 }
                if !completeDuringAttachment {
                    state.operation = nil
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(window.attachedSheet != nil && state.handoffs == cycle, "Pending preparation dismissed")
                    state.pending = false
                }
                try await waitFor("native automatic dismissal") { state.handoffs == cycle + 1 && window.attachedSheet == nil }
                try await Task.sleep(for: .milliseconds(100))
                precondition(window.attachments == cycle + 1, "Finished operation reopened a sheet")
                precondition(state.cancellations == 0, "Completion required cancellation")
                untouched()
            }
            print("PASS: actual SwiftUI sheet attached and automatically dismissed twice; completionDuringAttachment=\(completeDuringAttachment) outcome=\(outcome); no cancellation, no repeated sheet, no foreground change")
        }
        }
        print("LIMITATION: transparent background windows exercise native presentation and dismissal, not foreground focus or VoiceOver speech")
    }
}
