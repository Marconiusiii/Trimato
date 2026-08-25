import AppKit
import Combine
import SwiftUI

@MainActor
final class EditorAccessibilityFocusScope: ObservableObject {
    weak var boundaryView: NSView?

    var containsAccessibilityFocus: Bool {
        guard let boundaryView, let window = boundaryView.window, window.isKeyWindow,
              let focusedElement = NSApp.accessibilityFocusedUIElement as? NSObject else {
            return false
        }

        if focusedElement === boundaryView { return true }
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        guard focusedElement.responds(to: frameSelector),
              let frameValue = focusedElement.value(forKey: "accessibilityFrame") as? NSValue else {
            return false
        }
        let focusedFrame = frameValue.rectValue
        guard !focusedFrame.isEmpty else { return false }
        let windowFrame = boundaryView.convert(boundaryView.bounds, to: nil)
        let screenFrame = window.convertToScreen(windowFrame)
        return screenFrame.contains(NSPoint(x: focusedFrame.midX, y: focusedFrame.midY))
    }
}

struct EditorAccessibilityFocusBridge: NSViewRepresentable {
    let scope: EditorAccessibilityFocusScope

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        scope.boundaryView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scope.boundaryView = nsView
    }
}
