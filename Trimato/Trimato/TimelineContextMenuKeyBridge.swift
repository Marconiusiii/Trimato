import AppKit
import SwiftUI

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
            if !event.isARepeat,
               let selection = parent.focusedElement,
               case .clip(let id) = selection,
               let anchorView,
               anchorView.window?.isKeyWindow == true,
               NSApp.modalWindow == nil {
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
            }
            guard modifiers == .control,
                  event.keyCode == 36 || event.keyCode == 76,
                  let selection = parent.focusedElement,
                  let anchorView,
                  anchorView.window?.isKeyWindow == true,
                  NSApp.modalWindow == nil else { return event }

            menuSelection = selection
            NSMenu.popUpContextMenu(menu(for: selection), with: event, for: anchorView)
            return nil
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
                parent.deleteClip(id)
            case (4, .transition(let id)):
                parent.editTransition(id)
            case (5, .transition(let id)):
                parent.deleteTransition(id)
            case (6, .clip(let id)):
                parent.copyClip(id)
            case (7, .clip(let id)):
                parent.pasteClipAfter(id)
            case (8, .clip(let id)):
                parent.moveClipAfter(id)
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
