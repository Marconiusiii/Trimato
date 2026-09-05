import AppKit
import Testing
@testable import Trimato

@Suite("Native default button", .serialized)
struct NativeDefaultButtonTests {
    @Test @MainActor func buttonInstallsItsCellAsTheWindowDefault() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let button = DefaultActionButton(title: "Apply", target: nil, action: nil)
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        window.contentView?.addSubview(button)
        button.installAsDefaultButton()

        #expect(window.defaultButtonCell === button.cell)
        #expect(button.keyEquivalent == "\r")
        #expect(button.keyEquivalentModifierMask.isEmpty)
        window.close()
    }
}
