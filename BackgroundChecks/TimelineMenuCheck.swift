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
        let actionRecorder = MenuActionRecorder()
        var requested: [TimelineElementSelection] = []
        let provider: (TimelineElementSelection) -> NSMenu = { selection in
            requested.append(selection)
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Remove from Timeline", action: #selector(MenuActionRecorder.choose(_:)), keyEquivalent: "")
            item.target = actionRecorder
            item.representedObject = selection
            return menu
        }
        let focus = TimelineNativeFocus()
        func configure(_ button: TimelineCollectionButton, selection: TimelineElementSelection) {
            button.configure(model: TimelineCollectionItemModel(selection: selection, title: "Clip",
                subtitle: nil, accessibilityValue: "", accessibilityHint: "", isSelected: false,
                isTransition: false), nativeFocus: focus, activate: { _ in }, focus: { _ in }, menu: provider)
        }
        configure(first, selection: firstID)
        configure(second, selection: secondID)
        precondition(first.showClipMenu { menu, view in
            precondition(view === first && requested.last == firstID)
            let item = menu.items[0]
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
            precondition(actionRecorder.selected == firstID)
        })
        let reused = TimelineElementSelection.caption(UUID())
        configure(first, selection: reused)
        precondition(first.showClipMenu { _, _ in precondition(requested.last == reused) })
        first.configureEmpty(title: "Empty")
        precondition(!first.showClipMenu { _, _ in fatalError("Empty item presented a menu") })
        let coordinator = TimelineClipsCollection.Coordinator()
        coordinator.models = [firstID, secondID].map {
            TimelineCollectionItemModel(selection: $0, title: "Kitchen AD", subtitle: nil,
                accessibilityValue: "", accessibilityHint: "", isSelected: $0 == secondID, isTransition: false)
        }
        var removedTarget: TimelineElementSelection?
        var deletedMediaTarget: UUID?
        coordinator.actions = TimelineCollectionActions(
            activate: { _ in }, focus: { _ in }, renameClip: { _ in }, copyClip: { _ in },
            pasteClipAfter: { _ in }, toggleClipMovement: { _ in }, moveClip: { _, _ in },
            canMoveClip: { _, _ in true }, movePlayheadToCaption: { _ in },
            delete: { removedTarget = $0 }, deleteMedia: { deletedMediaTarget = $0 })
        let productionMenu = coordinator.menuForSelectedItem(target: firstID)!
        for title in ["Remove from Timeline", "Delete Media"] {
            let item = productionMenu.item(withTitle: title)!
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        precondition(removedTarget == firstID)
        if case .clip(let id) = firstID { precondition(deletedMediaTarget == id) }
        precondition(productionMenu.item(withTitle: "Delete from Timeline") == nil)
        precondition(coordinator.menuForSelectedItem(target: .clip(UUID())) == nil)
        precondition(!window.isVisible && !window.isKeyWindow)
        print("Hosted-item menu targeting, reuse cleanup, and production removal/deletion action targets passed; native VoiceOver menu delivery requires manual testing")
    }
}
