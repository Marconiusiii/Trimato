import AppKit
import Combine
import SwiftUI

@MainActor
final class EditorAccessibilityFocusScope: ObservableObject {
    static let identifierPrefix = "trimato.editor."

    weak var boundaryView: NSView?

    var containsAccessibilityFocus: Bool {
        guard let boundaryView, let window = boundaryView.window, window.isKeyWindow,
              let focusedElement = NSApp.accessibilityFocusedUIElement as? NSObject else { return false }
        if hasEditorIdentifier(focusedElement) { return true }
        if TimelineKeyboardFocus.isInTimeline { return false }
        if focusedElement === boundaryView { return true }
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        guard focusedElement.responds(to: frameSelector),
              let frameValue = focusedElement.value(forKey: "accessibilityFrame") as? NSValue else { return false }
        let focusedFrame = frameValue.rectValue
        guard !focusedFrame.isEmpty else { return false }
        let windowFrame = boundaryView.convert(boundaryView.bounds, to: nil)
        let screenFrame = window.convertToScreen(windowFrame)
        return screenFrame.contains(NSPoint(x: focusedFrame.midX, y: focusedFrame.midY))
    }

    private func hasEditorIdentifier(_ focusedElement: NSObject) -> Bool {
        let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
        let parentSelector = NSSelectorFromString("accessibilityParent")
        var element: NSObject? = focusedElement

        for _ in 0..<12 {
            guard let current = element else { return false }
            if current.responds(to: identifierSelector),
               let identifier = current.value(forKey: "accessibilityIdentifier") as? String,
               identifier.hasPrefix(Self.identifierPrefix) {
                return true
            }
            guard current.responds(to: parentSelector),
                  let parent = current.value(forKey: "accessibilityParent") as? NSObject,
                  parent !== current else { return false }
            element = parent
        }
        return false
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
