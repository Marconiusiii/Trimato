import AppKit
import Combine
import SwiftUI

/// Command ownership follows observed VoiceOver focus, independently of the
/// keyboard responder. Each document window has its own owner.
@MainActor
final class WorkspaceVoiceOverCommandFocus {
    enum Owner: Equatable {
        case editor(UUID)
        case timeline(UUID)
        case mixer(UUID)
    }

    private(set) var owner: Owner?
    private static let windows = NSMapTable<NSWindow, WorkspaceVoiceOverCommandFocus>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func forWindow(_ window: NSWindow) -> WorkspaceVoiceOverCommandFocus {
        if let focus = windows.object(forKey: window) { return focus }
        let focus = WorkspaceVoiceOverCommandFocus()
        windows.setObject(focus, forKey: window)
        return focus
    }

    func claim(_ owner: Owner) { self.owner = owner }
    func release(_ owner: Owner) {
        if self.owner == owner { self.owner = nil }
    }
}

@MainActor
final class EditorAccessibilityFocusScope: ObservableObject {
    private let ownerID = UUID()
    weak var boundaryView: NSView?
    private let mixer: Bool
    init(mixer: Bool = false) { self.mixer = mixer }
    private var commandOwner: WorkspaceVoiceOverCommandFocus.Owner {
        mixer ? .mixer(ownerID) : .editor(ownerID)
    }

    func recordVoiceOverFocus(_ focused: Bool) {
        guard let window = boundaryView?.window else { return }
        let commands = WorkspaceVoiceOverCommandFocus.forWindow(window)
        if focused { commands.claim(commandOwner) }
        else { commands.release(commandOwner) }
    }

    var containsInputFocus: Bool {
        Self.resolveInputFocus(
            voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled,
            voiceOverContainsFocus: containsVoiceOverFocus,
            keyboardContainsFocus: containsKeyboardFocus
        )
    }

    nonisolated static func resolveInputFocus(
        voiceOverEnabled: Bool,
        voiceOverContainsFocus: Bool,
        keyboardContainsFocus: Bool
    ) -> Bool {
        voiceOverEnabled ? voiceOverContainsFocus : keyboardContainsFocus
    }

    var containsKeyboardFocus: Bool {
        guard let boundaryView, let window = boundaryView.window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView else { return false }
        if responder === boundaryView || responder.isDescendant(of: boundaryView) { return true }
        guard responder.window === window else { return false }
        let windowFrame = boundaryView.convert(boundaryView.bounds, to: nil)
        let responderFrame = responder.convert(responder.bounds, to: nil)
        guard !responderFrame.isEmpty else { return false }
        return windowFrame.intersects(responderFrame)
    }

    private var containsVoiceOverFocus: Bool {
        guard let window = boundaryView?.window, window.isKeyWindow else { return false }
        return WorkspaceVoiceOverCommandFocus.forWindow(window).owner == commandOwner
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
