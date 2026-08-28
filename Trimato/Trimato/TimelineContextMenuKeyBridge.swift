import AppKit
import SwiftUI

nonisolated enum TimelineElementAccessibilityIdentifier {
    private static let clipPrefix = "trimato.timeline.clip."
    private static let transitionPrefix = "trimato.timeline.transition."

    static func clip(_ id: UUID) -> String {
        clipPrefix + id.uuidString
    }

    static func transition(_ id: UUID) -> String {
        transitionPrefix + id.uuidString
    }

    static func selection(from identifier: String?) -> TimelineElementSelection? {
        guard let identifier else { return nil }
        if identifier.hasPrefix(clipPrefix),
           let id = UUID(uuidString: String(identifier.dropFirst(clipPrefix.count))) {
            return .clip(id)
        }
        if identifier.hasPrefix(transitionPrefix),
           let id = UUID(uuidString: String(identifier.dropFirst(transitionPrefix.count))) {
            return .transition(id)
        }
        return nil
    }
}

nonisolated enum TimelineKeyboardCommand: Equatable {
    case none
    case delete
    case openContextMenu

    static func resolve(keyCode: UInt16, controlOnly: Bool, hasAnyModifiers: Bool) -> Self {
        if !hasAnyModifiers, keyCode == 51 || keyCode == 117 {
            return .delete
        }
        if controlOnly, keyCode == 36 || keyCode == 76 {
            return .openContextMenu
        }
        return .none
    }
}

struct TimelineContextMenuKeyBridge: NSViewRepresentable {
    let focusedElement: TimelineElementSelection?
    let activate: (TimelineElementSelection) -> Void
    let renameClip: (UUID) -> Void
    let deleteClip: (UUID) -> Void
    let editTransition: (UUID) -> Void
    let deleteTransition: (UUID) -> Void
    let copyClip: (UUID) -> Void
    let pasteClipAfter: (UUID) -> Void
    let moveClipAfter: (UUID) -> Void
    let trimClipEnd: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TimelineContextMenuAnchorView {
        let view = TimelineContextMenuAnchorView()
        view.setAccessibilityElement(false)
        view.windowDidChange = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.attach(to: view)
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: TimelineContextMenuAnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ view: TimelineContextMenuAnchorView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineContextMenuKeyBridge
        private weak var anchorView: NSView?
        private var eventMonitor: Any?
        private var menuSelection: TimelineElementSelection?

        init(parent: TimelineContextMenuKeyBridge) {
            self.parent = parent
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func attach(to view: NSView?) {
            anchorView = view
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return handle(event)
            }
        }

        func removeMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !event.isARepeat,
                  let selection = resolvedFocusedSelection(),
                  let anchorView,
                  anchorView.window?.isKeyWindow == true,
                  NSApp.modalWindow == nil else { return event }

            if case .clip(let id) = selection {
                let character = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .command, character == "c" {
                    parent.copyClip(id)
                    return nil
                }
                if modifiers == .command, character == "v" {
                    parent.pasteClipAfter(id)
                    return nil
                }
                if modifiers == [.command, .option], character == "v" {
                    parent.moveClipAfter(id)
                    return nil
                }
                if modifiers == .command, character == "]" {
                    DispatchQueue.main.async { [parent] in parent.trimClipEnd(id) }
                    return nil
                }
            }

            let keyboardCommand = TimelineKeyboardCommand.resolve(
                keyCode: event.keyCode,
                controlOnly: modifiers == .control,
                hasAnyModifiers: !modifiers.isEmpty
            )
            if keyboardCommand == .delete {
                switch selection {
                case .clip(let id):
                    DispatchQueue.main.async { [parent] in parent.deleteClip(id) }
                case .transition(let id):
                    DispatchQueue.main.async { [parent] in parent.deleteTransition(id) }
                }
                return nil
            }

            guard keyboardCommand == .openContextMenu else { return event }

            menuSelection = selection
            let menu = menu(for: selection)
            let presentationView = anchorView.window?.contentView ?? anchorView
            menu.popUp(
                positioning: nil,
                at: menuPresentationPoint(in: presentationView),
                in: presentationView
            )
            return nil
        }

        private func resolvedFocusedSelection() -> TimelineElementSelection? {
            guard let focusedElement = NSApp.accessibilityFocusedUIElement as? NSObject else {
                return parent.focusedElement
            }
            var element: NSObject? = focusedElement
            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            let parentSelector = NSSelectorFromString("accessibilityParent")
            for _ in 0..<12 {
                guard let current = element else { return nil }
                if current.responds(to: identifierSelector),
                   let identifier = current.value(forKey: "accessibilityIdentifier") as? String,
                   let selection = TimelineElementAccessibilityIdentifier.selection(from: identifier) {
                    return selection
                }
                guard current.responds(to: parentSelector),
                      let accessibilityParent = current.value(forKey: "accessibilityParent") as? NSObject,
                      accessibilityParent !== current else { return nil }
                element = accessibilityParent
            }
            return nil
        }

        private func menuPresentationPoint(in view: NSView) -> NSPoint {
            guard let focusedElement = NSApp.accessibilityFocusedUIElement as? NSObject,
                  focusedElement.responds(to: NSSelectorFromString("accessibilityFrame")),
                  let frameValue = focusedElement.value(forKey: "accessibilityFrame") as? NSValue,
                  let window = view.window else {
                return NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            }
            let screenFrame = frameValue.rectValue
            let screenPoint = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return view.convert(windowPoint, from: nil)
        }

        private func menu(for selection: TimelineElementSelection) -> NSMenu {
            let menu = NSMenu(title: "Selected Element Actions")
            switch selection {
            case .clip:
                menu.addItem(item("Open Clip Editor", tag: 1))
                menu.addItem(item("Rename Clip…", tag: 2))
                menu.addItem(.separator())
                menu.addItem(item("Copy Clip", tag: 6, keyEquivalent: "c", modifiers: .command))
                menu.addItem(item("Paste Clip After", tag: 7, keyEquivalent: "v", modifiers: .command))
                menu.addItem(item("Move Copied Clip After", tag: 8, keyEquivalent: "v", modifiers: [.command, .option]))
                menu.addItem(item("Trim End to Project Playhead", tag: 9, keyEquivalent: "]", modifiers: .command))
                menu.addItem(.separator())
                menu.addItem(item("Delete from Timeline", tag: 3))
            case .transition:
                menu.addItem(item("Edit Transition…", tag: 4))
                menu.addItem(item("Delete Transition", tag: 5))
            }
            return menu
        }

        private func item(
            _ title: String,
            tag: Int,
            keyEquivalent: String = "",
            modifiers: NSEvent.ModifierFlags = []
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: keyEquivalent)
            item.target = self
            item.tag = tag
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let selection = menuSelection else { return }
            switch (sender.tag, selection) {
            case (1, .clip):
                parent.activate(selection)
            case (2, .clip(let id)):
                parent.renameClip(id)
            case (3, .clip(let id)):
                DispatchQueue.main.async { [parent] in parent.deleteClip(id) }
            case (4, .transition(let id)):
                parent.editTransition(id)
            case (5, .transition(let id)):
                DispatchQueue.main.async { [parent] in parent.deleteTransition(id) }
            case (6, .clip(let id)):
                parent.copyClip(id)
            case (7, .clip(let id)):
                parent.pasteClipAfter(id)
            case (8, .clip(let id)):
                parent.moveClipAfter(id)
            case (9, .clip(let id)):
                parent.trimClipEnd(id)
            default:
                break
            }
        }
    }
}

final class TimelineContextMenuAnchorView: NSView {
    var windowDidChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?()
    }
}
