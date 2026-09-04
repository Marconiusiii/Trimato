import Foundation

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

nonisolated struct TimelineAccessibilityFocusRequest: Equatable {
    let revision: Int
    let identifier: String
}

import AppKit
import SwiftUI

nonisolated enum TimelineKeyAction: Equatable {
    case toggleMovement, beginMovement, finishMovement, cancelMovement
    case openEditor, earlier, later, copy, paste, moveAfter, previewBefore, previewAfter

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isMoving: Bool, allowsNudging: Bool = false) -> Self? {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            if keyCode == 8 { return .copy }
            if keyCode == 9 { return .paste }
        }
        if modifiers == [.command, .option], keyCode == 9 { return .moveAfter }
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 49: return .toggleMovement
        case 36, 76: return .openEditor
        case 53: return isMoving ? .finishMovement : nil
        case 123, 126: return isMoving || allowsNudging ? .earlier : nil
        case 124, 125: return isMoving || allowsNudging ? .later : nil
        default: return nil
        }
    }

    static func target(voiceOver: Bool, accessibilityFocus: TimelineElementSelection?, keyboardFocus: TimelineElementSelection?, editingText: Bool) -> TimelineElementSelection? {
        // VoiceOver and the keyboard responder can legitimately be on different
        // controls. An unrelated text responder must not steal this clip's Space.
        if voiceOver { return accessibilityFocus }
        return editingText ? nil : keyboardFocus
    }
}

@MainActor
final class TimelineInputScope {
    let id = UUID()
    weak var view: NSView?
    var accessibilityFocus: TimelineElementSelection?
    var keyboardFocus: TimelineElementSelection?

    var focusedElement: TimelineElementSelection? {
        NSWorkspace.shared.isVoiceOverEnabled ? accessibilityFocus : keyboardFocus
    }
}

@MainActor
enum TimelineKeyboardFocus {
    static var scopes: [UUID: TimelineInputScope] = [:]

    static var isInTimeline: Bool {
        scopes.values.contains { $0.view?.window?.isKeyWindow == true && $0.focusedElement != nil }
    }
}

// This invisible view measures its row for mouse hit testing. It is not an
// accessibility element and does not replace or wrap the native Button semantics.
struct TimelineRowEventAnchor: NSViewRepresentable {
    let element: TimelineElementSelection

    func makeNSView(context: Context) -> TimelineRowAnchorView {
        let view = TimelineRowAnchorView()
        view.setAccessibilityElement(false)
        view.element = element
        return view
    }

    func updateNSView(_ view: TimelineRowAnchorView, context: Context) { view.element = element }
}

final class TimelineRowAnchorView: NSView {
    var element: TimelineElementSelection?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func row(at point: NSPoint, in view: NSView) -> TimelineRowAnchorView? {
        for child in view.subviews {
            if let row = child as? TimelineRowAnchorView,
               row.convert(row.visibleRect, to: nil).contains(point), !row.isHiddenOrHasHiddenAncestor {
                return row
            }
            if let row = row(at: point, in: child) { return row }
        }
        return nil
    }
}

struct TimelineKeyboardBridge: NSViewRepresentable {
    let accessibilitySelection: TimelineElementSelection?
    let keyboardSelection: TimelineElementSelection?
    let movingClipID: UUID?
    var accessibilityFocusRequest: TimelineAccessibilityFocusRequest?
    var isMoving: Bool { movingClipID != nil }
    var allowsNudging: (TimelineElementSelection) -> Bool = { _ in false }
    let perform: (TimelineKeyAction, TimelineElementSelection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        context.coordinator.install(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bridge = self
        context.coordinator.scope.accessibilityFocus = accessibilitySelection
        context.coordinator.scope.keyboardFocus = keyboardSelection
        context.coordinator.performAccessibilityFocusRequest(accessibilityFocusRequest, from: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject {
        let scope = TimelineInputScope()
        var bridge: TimelineKeyboardBridge?
        var monitor: Any?
        var menuDepth = 0
        var consumedKeys: Set<UInt16> = []
        var mouseSource: TimelineElementSelection?
        var mouseMovementStarted = false
        var mousePressID = UUID()
        var lastAccessibilityFocusRequest: TimelineAccessibilityFocusRequest?

        func install(_ view: NSView) {
            scope.view = view
            TimelineKeyboardFocus.scopes[scope.id] = scope
            NotificationCenter.default.addObserver(self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard bridge != nil, let window = scope.view?.window, window.isKeyWindow,
                  event.window == nil || event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil, menuDepth == 0 else { return event }
            if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
                return handleMouse(event, in: window)
            }
            return handleKey(event, voiceOver: NSWorkspace.shared.isVoiceOverEnabled,
                             editingText: (window.firstResponder as? NSTextView)?.isEditable == true)
        }

        func performAccessibilityFocusRequest(
            _ request: TimelineAccessibilityFocusRequest?,
            from view: NSView
        ) {
            guard let request, request != lastAccessibilityFocusRequest else { return }
            lastAccessibilityFocusRequest = request
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      self.bridge?.accessibilityFocusRequest == request,
                      let window = view.window,
                      window.isKeyWindow,
                      let contentView = window.contentView,
                      let element = TimelineAppKitAccessibility.descendant(
                        in: contentView,
                        identifier: request.identifier
                      ) else { return }
                TimelineAppKitAccessibility.focus(element)
            }
        }

        func handleKey(_ event: NSEvent, voiceOver: Bool, editingText: Bool) -> NSEvent? {
            guard let bridge else { return event }
            if event.type == .keyUp { return consumedKeys.remove(event.keyCode) != nil ? nil : event }
            let target = mouseSource ?? TimelineKeyAction.target(
                voiceOver: voiceOver,
                accessibilityFocus: bridge.accessibilitySelection,
                keyboardFocus: bridge.keyboardSelection,
                editingText: editingText
            )
            guard let target,
                  let action = TimelineKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, isMoving: bridge.isMoving || mouseSource != nil, allowsNudging: bridge.allowsNudging(target)) else { return event }
            if case .transition = target, action != .openEditor { return event }
            consumedKeys.insert(event.keyCode)
            if !event.isARepeat || action == .earlier || action == .later {
                if mouseSource != nil, action == .earlier || action == .later { beginMouseMovement() }
                bridge.perform(action, target)
            }
            return nil
        }

        func handleMouse(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard let bridge, let content = window.contentView else { return event }
            let row = TimelineRowAnchorView.row(at: event.locationInWindow, in: content)
            switch event.type {
            case .leftMouseDown:
                // Preserve control-click and the native context menu.
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]) != .control,
                      let target = row?.element, case .clip = target else { return event }
                mouseSource = target
                mouseMovementStarted = false
                let request = UUID()
                mousePressID = request
                // A short ordinary click still opens Clip Editor. A held mouse
                // press (including VoiceOver's sticky mouse command) picks up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.mousePressID == request, self.mouseSource != nil else { return }
                    self.beginMouseMovement()
                }
                return nil
            case .leftMouseDragged:
                guard mouseSource != nil else { return event }
                beginMouseMovement()
                if let row, let target = row.element {
                    let rect = row.convert(row.bounds, to: nil)
                    bridge.perform(event.locationInWindow.y >= rect.midY ? .previewBefore : .previewAfter, target)
                }
                return nil
            case .leftMouseUp:
                guard let source = mouseSource else { return event }
                let wasMoving = mouseMovementStarted
                clearMousePress()
                if wasMoving { bridge.perform(.finishMovement, source) }
                else if row?.element == source { bridge.perform(.openEditor, source) }
                return nil
            default: return event
            }
        }

        private func beginMouseMovement() {
            guard !mouseMovementStarted, let source = mouseSource else { return }
            mouseMovementStarted = true
            bridge?.perform(.beginMovement, source)
        }

        private func clearMousePress() {
            mousePressID = UUID()
            mouseSource = nil
            mouseMovementStarted = false
        }

        @objc private func menuOpened(_ notification: Notification) { menuDepth += 1 }
        @objc private func menuClosed(_ notification: Notification) { menuDepth = max(menuDepth - 1, 0) }
        @objc private func windowResigned(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === scope.view?.window else { return }
            if let id = bridge?.movingClipID { bridge?.perform(.cancelMovement, .clip(id)) }
            clearMousePress()
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            TimelineKeyboardFocus.scopes.removeValue(forKey: scope.id)
            NotificationCenter.default.removeObserver(self)
        }
    }
}

@MainActor
enum TimelineAppKitAccessibility {
    static func descendant(in root: NSObject, identifier: String) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        return descendant(in: root, identifier: identifier, visited: &visited)
    }

    static func focus(_ element: NSObject) {
        if let view = element as? NSView {
            view.scrollToVisible(view.bounds)
        }
        (element as? NSAccessibilityProtocol)?.setAccessibilityFocused(true)
    }

    private static func descendant(
        in element: NSObject,
        identifier: String,
        visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        let identity = ObjectIdentifier(element)
        guard visited.insert(identity).inserted else { return nil }
        guard let accessibilityElement = element as? NSAccessibilityProtocol else { return nil }
        if accessibilityElement.accessibilityIdentifier() == identifier { return element }

        if let view = element as? NSView {
            for child in view.subviews {
                if let match = descendant(in: child, identifier: identifier, visited: &visited) {
                    return match
                }
            }
        }
        for child in accessibilityElement.accessibilityChildren() ?? [] {
            guard let child = child as? NSObject else { continue }
            if let match = descendant(in: child, identifier: identifier, visited: &visited) {
                return match
            }
        }
        return nil
    }
}
