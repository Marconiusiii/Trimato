import AppKit
import SwiftUI

struct TimelineAccessibilityView: NSViewRepresentable {
    let elements: [TimelineListElement]
    let selection: EditorSelection
    let focusRequest: TimelineElementSelection?
    let focusRequestID: Int
    let focus: (TimelineElementSelection) -> Void
    let activate: (TimelineElementSelection) -> Void
    let renameClip: (UUID) -> Void
    let deleteClip: (UUID) -> Void
    let editTransition: (UUID) -> Void
    let deleteTransition: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.setAccessibilityElement(false)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.setAccessibilityElement(true)
        scrollView.setAccessibilityLabel("Timeline clips")
        context.coordinator.stack = stack
        context.coordinator.reconcile(elements)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reconcile(elements)
        context.coordinator.restoreFocusIfNeeded(requestID: focusRequestID, target: focusRequest)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineAccessibilityView
        weak var stack: NSStackView?
        private var buttons: [String: TimelineAccessibilityButton] = [:]
        private var lastFocusRequestID = 0
        private var focusTask: Task<Void, Never>?

        init(parent: TimelineAccessibilityView) {
            self.parent = parent
        }

        deinit {
            focusTask?.cancel()
        }

        func reconcile(_ elements: [TimelineListElement]) {
            guard let stack else { return }
            let desiredIDs = Set(elements.map(\.id))

            let removedIDs = buttons.keys.filter { !desiredIDs.contains($0) }
            for id in removedIDs {
                guard let button = buttons[id] else { continue }
                stack.removeArrangedSubview(button)
                button.removeFromSuperview()
                buttons[id] = nil
            }

            for (index, element) in elements.enumerated() {
                let button = buttons[element.id] ?? makeButton(for: element)
                update(button, for: element)
                if button.superview == nil {
                    stack.insertArrangedSubview(button, at: min(index, stack.arrangedSubviews.count))
                } else if stack.arrangedSubviews.firstIndex(of: button) != index {
                    stack.removeArrangedSubview(button)
                    stack.insertArrangedSubview(button, at: min(index, stack.arrangedSubviews.count))
                }
            }
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        }

        func restoreFocusIfNeeded(requestID: Int, target: TimelineElementSelection?) {
            guard requestID != lastFocusRequestID, let target else { return }
            lastFocusRequestID = requestID
            let button = buttons.values.first { $0.timelineSelection == target }
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let button else { return }
                button.setAccessibilityFocused(true)
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                button.setAccessibilityFocused(true)
            }
        }

        private func makeButton(for element: TimelineListElement) -> TimelineAccessibilityButton {
            let button = TimelineAccessibilityButton(title: "", target: self, action: #selector(activateButton(_:)))
            button.isBordered = false
            button.timelineID = element.id
            button.didReceiveAccessibilityFocus = { [weak self, weak button] in
                guard let self, let selection = button?.timelineSelection else { return }
                parent.focus(selection)
            }
            buttons[element.id] = button
            return button
        }

        private func update(_ button: TimelineAccessibilityButton, for element: TimelineListElement) {
            let label: String
            let timelineSelection: TimelineElementSelection
            let editorSelection: EditorSelection
            switch element.content {
            case .clip(let clip):
                label = clip.displayName
                timelineSelection = .clip(clip.id)
                editorSelection = .timelineClip(clip.id)
            case .transition(let transition):
                label = transition.displayName
                timelineSelection = .transition(transition.id)
                editorSelection = .transition(transition.id)
            }
            button.title = label
            button.setAccessibilityLabel(label)
            button.timelineSelection = timelineSelection
            button.state = parent.selection == editorSelection ? .on : .off
            button.menu = menu(for: timelineSelection)
        }

        private func menu(for selection: TimelineElementSelection) -> NSMenu {
            let menu = NSMenu()
            switch selection {
            case .clip(let id):
                menu.addItem(menuItem("Open Clip Editor", action: #selector(openClip(_:)), id: id))
                menu.addItem(menuItem("Rename Clip…", action: #selector(renameClip(_:)), id: id))
                menu.addItem(.separator())
                menu.addItem(menuItem("Delete from Timeline", action: #selector(deleteClip(_:)), id: id))
            case .transition(let id):
                menu.addItem(menuItem("Edit Transition…", action: #selector(editTransition(_:)), id: id))
                menu.addItem(menuItem("Delete Transition", action: #selector(deleteTransition(_:)), id: id))
            }
            return menu
        }

        private func menuItem(_ title: String, action: Selector, id: UUID) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }

        @objc private func activateButton(_ sender: TimelineAccessibilityButton) {
            guard let selection = sender.timelineSelection else { return }
            parent.activate(selection)
        }

        @objc private func openClip(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.activate(.clip(id))
        }

        @objc private func renameClip(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.renameClip(id)
        }

        @objc private func deleteClip(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.deleteClip(id)
        }

        @objc private func editTransition(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.editTransition(id)
        }

        @objc private func deleteTransition(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.deleteTransition(id)
        }
    }
}

private final class TimelineAccessibilityButton: NSButton {
    var timelineID = ""
    var timelineSelection: TimelineElementSelection?
    var didReceiveAccessibilityFocus: (() -> Void)?

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        if accessibilityFocused { didReceiveAccessibilityFocus?() }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control, event.keyCode == 36, showContextMenu() { return }
        super.keyDown(with: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showContextMenu()
    }

    private func showContextMenu() -> Bool {
        guard let menu, let window else { return false }
        let location = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        guard let event else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
}
