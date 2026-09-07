import AppKit
@testable import Trimato

@MainActor final class MenuActionRecorder: NSObject {
    var selected: TimelineElementSelection?
    @objc func choose(_ item: NSMenuItem) { selected = item.representedObject as? TimelineElementSelection }
}

@main struct TimelineMenuCheck {
    @MainActor static func main() {
        // This helper never orders a window front or starts the application event loop.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true)
        let first = TimelineCollectionButton(frame: NSRect(x: 0, y: 0, width: 150, height: 60))
        let second = TimelineCollectionButton(frame: NSRect(x: 160, y: 0, width: 150, height: 60))
        window.contentView!.addSubview(first)
        window.contentView!.addSubview(second)
        let firstID = TimelineElementSelection.clip(UUID())
        let secondID = TimelineElementSelection.clip(UUID())
        first.selection = firstID; second.selection = secondID
        let actionRecorder = MenuActionRecorder()
        var requested: [TimelineElementSelection] = []
        let provider: (TimelineElementSelection) -> NSMenu = { selection in
            requested.append(selection)
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Delete from Timeline", action: #selector(MenuActionRecorder.choose(_:)), keyEquivalent: "")
            item.target = actionRecorder
            item.representedObject = selection
            return menu
        }
        first.menuProvider = provider; second.menuProvider = provider
        let attached = first.menu!
        precondition(attached.delegate === first)
        let actionsSelector = NSSelectorFromString("accessibilityActionNames")
        let actions = first.perform(actionsSelector)?.takeUnretainedValue() as? [String] ?? []
        precondition(actions.contains("AXShowMenu"), "Native Show Menu action is missing: \(actions)")
        window.makeFirstResponder(second)
        let mouse = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(first.menu(for: mouse) === attached, "Mouse/accessibility menu lookup lost the attached menu")
        var presented = false
        precondition(first.showClipMenu { menu, view in
            presented = true
            precondition(view === first && menu === attached)
            precondition(menu.items.count == 1 && requested.last == firstID)
            let item = menu.items[0]
            precondition(item.isEnabled)
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
            precondition(actionRecorder.selected == firstID)
        })
        precondition(presented, "Keyboard presentation did not reach the button menu")
        precondition(window.firstResponder === second, "Opening the target menu rewrote keyboard focus")
        first.selection = .caption(UUID())
        first.menu!.delegate!.menuNeedsUpdate?(first.menu!)
        precondition(first.menu === attached && requested.last == first.selection, "Reused button menu kept a stale clip")
        first.menuProvider = nil
        precondition(first.menu == nil, "Empty/recycled button retained a menu")
        precondition(!first.showClipMenu { _, _ in fatalError("Empty button presented a menu") })
        precondition(!window.isVisible && !window.isKeyWindow)
        print("Native AXShowMenu attachment, mouse/accessibility lookup, target-button presentation, keyboard-focus independence, and reuse cleanup passed without displaying a menu or window")
    }
}
