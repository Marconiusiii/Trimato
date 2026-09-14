import Foundation
@testable import Trimato

/// Checks production shortcut routing without creating an application, views, or menus.
@main struct TimelineMenuRoutingCheck {
    @MainActor static func main() {
        let first = TimelineElementSelection.clip(UUID())
        let focused = TimelineElementSelection.clip(UUID())
        var requests: [TimelineElementSelection?] = []
        func show(_ selection: TimelineElementSelection?) -> Bool { requests.append(selection); return true }
        precondition(TimelineContextMenuRouting.present(voiceOver: true,
            accessibilityFocus: focused, keyboardFocus: first, show: show))
        precondition(requests == [focused], "Keyboard clip displaced VoiceOver target")
        requests.removeAll()
        precondition(TimelineContextMenuRouting.present(voiceOver: true,
            accessibilityFocus: nil, keyboardFocus: first, show: show))
        precondition(requests.isEmpty, "Missing VoiceOver target fell back to keyboard clip")
        precondition(TimelineContextMenuRouting.present(voiceOver: true,
            accessibilityFocus: focused, keyboardFocus: first, show: { target in
                precondition(target == focused)
                return false
            }), "Unavailable target allowed shortcut to fall through")
        precondition(TimelineContextMenuRouting.present(voiceOver: false,
            accessibilityFocus: focused, keyboardFocus: first, show: show))
        precondition(requests == [first], "Keyboard-only targeting changed")
        requests.removeAll()
        precondition(TimelineContextMenuRouting.present(voiceOver: false,
            accessibilityFocus: focused, keyboardFocus: nil, show: show))
        precondition(requests.count == 1 && requests[0] == nil, "Collection selection fallback changed")
        for code: UInt16 in [36, 76] {
            precondition(NativeContextMenuShortcut.matches(keyCode: code, modifiers: .control))
            precondition(!NativeContextMenuShortcut.matches(keyCode: code, modifiers: [.control, .option]))
        }
        print("PASS: VoiceOver target, missing target, failed presentation, keyboard target, collection fallback, Return and Enter")
    }
}
