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
    case toggleMovement, beginMovement, finishMovement, cancelMovement, delete
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
        case 51, 117: return .delete
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
        guard scopes.values.contains(where: { $0.view?.window?.isKeyWindow == true }),
              let focused = NSApp.accessibilityFocusedUIElement as? NSObject else { return false }
        let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
        let parentSelector = NSSelectorFromString("accessibilityParent")
        var element: NSObject? = focused
        for _ in 0..<12 {
            guard let current = element else { return false }
            if current.responds(to: identifierSelector),
               let identifier = current.value(forKey: "accessibilityIdentifier") as? String,
               TimelineElementAccessibilityIdentifier.selection(from: identifier) != nil {
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

        func handleKey(_ event: NSEvent, voiceOver: Bool, editingText: Bool) -> NSEvent? {
            guard let bridge else { return event }
            if event.type == .keyUp { return consumedKeys.remove(event.keyCode) != nil ? nil : event }
            let target = mouseSource ?? TimelineKeyAction.target(
                voiceOver: voiceOver,
                accessibilityFocus: voiceOver
                    ? (focusedTimelineElement() ?? bridge.accessibilitySelection)
                    : bridge.accessibilitySelection,
                keyboardFocus: bridge.keyboardSelection,
                editingText: editingText
            )
            guard let target,
                  let action = TimelineKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, isMoving: bridge.isMoving || mouseSource != nil, allowsNudging: bridge.allowsNudging(target)) else { return event }
            if case .transition = target, action != .openEditor, action != .delete { return event }
            consumedKeys.insert(event.keyCode)
            if !event.isARepeat || action == .earlier || action == .later {
                if mouseSource != nil, action == .earlier || action == .later { beginMouseMovement() }
                bridge.perform(action, target)
            }
            return nil
        }

        private func focusedTimelineElement() -> TimelineElementSelection? {
            guard let focused = NSApp.accessibilityFocusedUIElement as? NSObject else { return nil }
            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            let parentSelector = NSSelectorFromString("accessibilityParent")
            var element: NSObject? = focused
            for _ in 0..<12 {
                guard let current = element else { return nil }
                if current.responds(to: identifierSelector),
                   let identifier = current.value(forKey: "accessibilityIdentifier") as? String,
                   let selection = TimelineElementAccessibilityIdentifier.selection(from: identifier) {
                    return selection
                }
                guard current.responds(to: parentSelector),
                      let parent = current.value(forKey: "accessibilityParent") as? NSObject,
                      parent !== current else { return nil }
                element = parent
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
                    bridge.perform(event.locationInWindow.x <= rect.midX ? .previewBefore : .previewAfter, target)
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

struct TimelineCollectionItemModel: Equatable {
    let selection: TimelineElementSelection
    let title: String
    let subtitle: String?
    let accessibilityValue: String
    let accessibilityHint: String
    let isSelected: Bool
    let isTransition: Bool
}

struct TimelineCollectionActions {
    let activate: (TimelineElementSelection) -> Void
    let focus: (TimelineElementSelection) -> Void
    let renameClip: (UUID) -> Void
    let copyClip: (UUID) -> Void
    let pasteClipAfter: (UUID) -> Void
    let toggleClipMovement: (UUID) -> Void
    let moveClip: (TimelineMoveDestination, UUID) -> Void
    let canMoveClip: (TimelineMoveDestination, UUID) -> Bool
    let delete: (TimelineElementSelection) -> Void
}

struct TimelineClipsCollection: NSViewRepresentable {
    let items: [TimelineCollectionItemModel]
    let accessibilityLabel: String
    let focusRequest: Int
    let focusTarget: TimelineElementSelection?
    let listFocusRequest: Int
    let movingClipID: UUID?
    let actions: TimelineCollectionActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 200, height: 72)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(TimelineCollectionItem.self,
                            forItemWithIdentifier: TimelineCollectionItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.setAccessibilityIdentifier("trimato.timeline.clips")

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.collectionView = collection
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?
        var models: [TimelineCollectionItemModel] = []
        var actions: TimelineCollectionActions?
        var previousFocusRequest = -1
        var previousListFocusRequest = -1
        var movingClipID: UUID?

        func update(from source: TimelineClipsCollection) {
            actions = source.actions
            movingClipID = source.movingClipID
            collectionView?.setAccessibilityLabel(source.accessibilityLabel)
            let structureChanged = models.map(\.selection) != source.items.map(\.selection)
            models = source.items
            if structureChanged {
                collectionView?.reloadData()
            } else {
                for item in collectionView?.visibleItems() ?? [] {
                    guard let timelineItem = item as? TimelineCollectionItem,
                          let indexPath = collectionView?.indexPath(for: item),
                          models.indices.contains(indexPath.item) else { continue }
                    configure(timelineItem, with: models[indexPath.item])
                }
            }
            if previousFocusRequest != source.focusRequest, source.focusRequest > 0 {
                previousFocusRequest = source.focusRequest
                if let target = source.focusTarget { select(target) }
            } else {
                previousFocusRequest = source.focusRequest
            }
            if previousListFocusRequest != source.listFocusRequest, source.listFocusRequest > 0 {
                previousListFocusRequest = source.listFocusRequest
                collectionView?.deselectAll(nil)
                scrollView?.window?.makeFirstResponder(collectionView)
            } else {
                previousListFocusRequest = source.listFocusRequest
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            max(models.count, 1)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: TimelineCollectionItem.identifier,
                                               for: indexPath) as! TimelineCollectionItem
            if models.indices.contains(indexPath.item) {
                configure(item, with: models[indexPath.item])
            } else {
                item.configureEmpty()
            }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let index = indexPaths.first?.item, models.indices.contains(index) else { return }
            actions?.focus(models[index].selection)
        }

        private func configure(_ item: TimelineCollectionItem, with model: TimelineCollectionItemModel) {
            item.configure(model: model,
                           activate: { [weak self] selection in self?.actions?.activate(selection) },
                           focus: { [weak self] selection in self?.actions?.focus(selection) },
                           menu: { [weak self] selection in self?.makeMenu(for: selection) ?? NSMenu() })
        }

        private func select(_ target: TimelineElementSelection) {
            guard let collectionView,
                  let index = models.firstIndex(where: { $0.selection == target }) else { return }
            let path = IndexPath(item: index, section: 0)
            collectionView.selectItems(at: [path], scrollPosition: .centeredHorizontally)
            collectionView.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
            collectionView.layoutSubtreeIfNeeded()
            if let button = (collectionView.item(at: path) as? TimelineCollectionItem)?.button {
                collectionView.window?.makeFirstResponder(button)
            }
        }

        private func makeMenu(for selection: TimelineElementSelection) -> NSMenu {
            let menu = NSMenu()
            switch selection {
            case .clip(let id):
                add("Open Clip Editor", to: menu) { [weak self] in self?.actions?.activate(selection) }
                add("Rename Clip…", to: menu) { [weak self] in self?.actions?.renameClip(id) }
                menu.addItem(.separator())
                add("Copy Clip", to: menu) { [weak self] in self?.actions?.copyClip(id) }
                add("Paste Clip After", to: menu) { [weak self] in self?.actions?.pasteClipAfter(id) }
                add(movingClipID == id ? "Finish Moving Clip" : "Select Clip for Moving", to: menu) {
                    [weak self] in self?.actions?.toggleClipMovement(id)
                }
                let moveMenu = NSMenu(title: "Move To…")
                for destination in TimelineMoveDestination.allCases {
                    let item = add(destination.title, to: moveMenu) { [weak self] in
                        self?.actions?.moveClip(destination, id)
                    }
                    item.isEnabled = actions?.canMoveClip(destination, id) == true
                }
                let moveItem = NSMenuItem(title: "Move To…", action: nil, keyEquivalent: "")
                moveItem.submenu = moveMenu
                menu.addItem(moveItem)
                menu.addItem(.separator())
                add("Delete from Timeline", to: menu) { [weak self] in self?.actions?.delete(selection) }
            case .transition:
                add("Edit Transition…", to: menu) { [weak self] in self?.actions?.activate(selection) }
                add("Delete Transition", to: menu) { [weak self] in self?.actions?.delete(selection) }
            }
            return menu
        }

        @discardableResult
        private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
            let target = TimelineMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(TimelineMenuAction.invoke), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.addItem(item)
            return item
        }
    }
}

private final class TimelineMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

private final class TimelineCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineCollectionItem")
    let button = TimelineCollectionButton()
    let eventAnchor = TimelineRowAnchorView()

    override func loadView() {
        view = NSView()
        eventAnchor.translatesAutoresizingMaskIntoConstraints = false
        eventAnchor.setAccessibilityElement(false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.alignment = .left
        button.lineBreakMode = .byWordWrapping
        button.cell?.wraps = true
        view.addSubview(eventAnchor)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            eventAnchor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            eventAnchor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            eventAnchor.topAnchor.constraint(equalTo: view.topAnchor),
            eventAnchor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func configure(model: TimelineCollectionItemModel,
                   activate: @escaping (TimelineElementSelection) -> Void,
                   focus: @escaping (TimelineElementSelection) -> Void,
                   menu: @escaping (TimelineElementSelection) -> NSMenu) {
        button.isEnabled = true
        button.title = [model.title, model.subtitle].compactMap { $0 }.joined(separator: "\n")
        eventAnchor.element = model.selection
        button.selection = model.selection
        button.activate = activate
        button.focus = focus
        button.menuProvider = menu
        button.setAccessibilityLabel(model.title)
        button.setAccessibilityValue(model.accessibilityValue)
        button.setAccessibilityHelp(model.accessibilityHint)
        switch model.selection {
        case .clip(let id): button.setAccessibilityIdentifier(TimelineElementAccessibilityIdentifier.clip(id))
        case .transition(let id): button.setAccessibilityIdentifier(TimelineElementAccessibilityIdentifier.transition(id))
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = model.isTransition ? 1.5 : 1
        button.layer?.borderColor = model.isTransition
            ? NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
            : NSColor.separatorColor.cgColor
        button.layer?.backgroundColor = model.isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.controlBackgroundColor.cgColor
    }

    func configureEmpty() {
        button.title = "No clips on this track"
        eventAnchor.element = nil
        button.isEnabled = false
        button.selection = nil
        button.activate = nil
        button.focus = nil
        button.menuProvider = nil
        button.setAccessibilityLabel("No clips on this track")
        button.setAccessibilityValue(nil)
        button.setAccessibilityHelp(nil)
        button.setAccessibilityIdentifier("trimato.timeline.empty")
    }
}

private final class TimelineCollectionButton: NSButton {
    var selection: TimelineElementSelection?
    var activate: ((TimelineElementSelection) -> Void)?
    var focus: ((TimelineElementSelection) -> Void)?
    var menuProvider: ((TimelineElementSelection) -> NSMenu)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pressed)
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() {
        guard let selection else { return }
        activate?(selection)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let selection { focus?(selection) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let selection else { return super.menu(for: event) }
        return menuProvider?(selection)
    }
}
