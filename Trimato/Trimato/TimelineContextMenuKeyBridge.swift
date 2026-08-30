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

import AppKit
import SwiftUI

nonisolated enum TimelineKeyAction: Equatable {
    case toggleMovement, finishMovement, openEditor, earlier, later, copy, paste, moveAfter

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isMoving: Bool) -> Self? {
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
        case 123, 126: return isMoving ? .earlier : nil
        case 124, 125: return isMoving ? .later : nil
        default: return nil
        }
    }
}

@MainActor
enum TimelineKeyboardFocus {
    static func identifiers(from object: NSObject?) -> [String] {
        var current = object
        var result: [String] = []
        for _ in 0..<16 {
            guard let element = current else { break }
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let value = element.value(forKey: "accessibilityIdentifier") as? String {
                result.append(value)
            }
            guard element.responds(to: NSSelectorFromString("accessibilityParent")),
                  let parent = element.value(forKey: "accessibilityParent") as? NSObject,
                  parent !== element else { break }
            current = parent
        }
        return result
    }

    static var isInTimeline: Bool {
        identifiers(from: NSApp.accessibilityFocusedUIElement as? NSObject)
            .contains { $0.hasPrefix("trimato.timeline.") }
    }
}

struct TimelineKeyboardBridge: NSViewRepresentable {
    let keyboardSelection: TimelineElementSelection?
    let isMoving: Bool
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
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        weak var view: NSView?
        var bridge: TimelineKeyboardBridge?
        var monitor: Any?
        var menuDepth = 0
        var consumedKeys: Set<UInt16> = []

        func install(_ view: NSView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let bridge = self.bridge,
                      let window = self.view?.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil,
                      NSApp.modalWindow == nil, self.menuDepth == 0 else { return event }
                if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
                if event.type == .keyUp {
                    return self.consumedKeys.remove(event.keyCode) != nil ? nil : event
                }
                let identifiers = TimelineKeyboardFocus.identifiers(from: NSApp.accessibilityFocusedUIElement as? NSObject)
                let accessibilitySelection = identifiers.compactMap { TimelineElementAccessibilityIdentifier.selection(from: $0) }.first
                let selection = NSWorkspace.shared.isVoiceOverEnabled ? accessibilitySelection : (bridge.keyboardSelection ?? accessibilitySelection)
                guard let selection,
                      let action = TimelineKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, isMoving: bridge.isMoving) else { return event }
                if case .transition = selection, action != .openEditor { return event }
                self.consumedKeys.insert(event.keyCode)
                if !event.isARepeat || action == .earlier || action == .later {
                    bridge.perform(action, selection)
                }
                return nil
            }
        }

        @objc private func menuOpened(_ notification: Notification) { menuDepth += 1 }
        @objc private func menuClosed(_ notification: Notification) { menuDepth = max(menuDepth - 1, 0) }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
        }
    }
}
