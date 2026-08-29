import AppKit
import SwiftUI

nonisolated enum ProjectSourcePasteFocus {
    static func firstImportedAssetID(
        existingAssetIDs: Set<UUID>,
        assets: [MediaAssetRecord]
    ) -> UUID? {
        assets.first { !existingAssetIDs.contains($0.id) }?.id
    }

    static func shouldAttemptFocus(hasPendingAsset: Bool, importIsRunning: Bool) -> Bool {
        hasPendingAsset && !importIsRunning
    }

    static func shouldRetryFocus(didResolveTarget: Bool, didEstablishFocus: Bool) -> Bool {
        !didResolveTarget || !didEstablishFocus
    }

    static func selectedAccessibilityRow<Element>(from rows: [Element]?) -> Element? {
        rows?.first
    }
}

nonisolated enum ProjectSourceKeyboardCommand: Equatable {
    case none
    case delete

    static func resolve(keyCode: UInt16, hasAnyModifiers: Bool) -> Self {
        !hasAnyModifiers && (keyCode == 51 || keyCode == 117) ? .delete : .none
    }
}

struct ProjectSourceOutlineView: NSViewRepresentable {
    @ObservedObject var controller: ProjectController
    @Binding var selection: ProjectSourceItemID?
    let openClipEditor: (EditorSelection) -> Void
    let requestNewFolder: () -> Void
    let requestRenameFolder: (UUID) -> Void
    let requestDeleteAsset: (UUID) -> Void
    let requestNewTrack: (UUID, NewTrackSourceKind) -> Void
    let focusRequest: ProjectSourceFocusRequest

    func makeCoordinator() -> Coordinator {
        Coordinator(
            parent: self,
            root: ProjectSourceNode(item: ProjectSourceItem.hierarchy(for: controller.project))
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProjectSourceOutline()
        outline.setAccessibilityElement(false)
        let column = NSTableColumn(identifier: .projectSourceColumn)
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .medium
        outline.usesAutomaticRowHeights = true
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.autosaveExpandedItems = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Project Source")
        outline.registerForDraggedTypes([.fileURL])
        outline.menuForSelectedRow = { [weak coordinator = context.coordinator] in
            coordinator?.contextMenuForSelectedRow()
        }
        outline.canPasteFiles = { [weak coordinator = context.coordinator] in
            coordinator?.pasteboardFileURLs().isEmpty == false
        }
        outline.pasteFiles = { [weak coordinator = context.coordinator] in
            coordinator?.pasteFilesFromFinder()
        }
        outline.deleteSelectedAsset = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelectedAsset()
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.installInitialContent(in: outline)
        scrollView.documentView = outline
        outline.setAccessibilityElement(true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(
            with: ProjectSourceItem.hierarchy(for: controller.project),
            importIsRunning: controller.isImporting
        )
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: ProjectSourceOutlineView
        weak var outlineView: NSOutlineView?
        private var root: ProjectSourceNode
        private var expandedIDs: Set<ProjectSourceItemID> = []
        private var isSynchronizingSelection = false
        private var pastedImportBaselineAssetIDs: Set<UUID>?
        private var pendingPastedAssetFocusID: UUID?
        private var pastedAssetFocusTask: Task<Void, Never>?
        private var handledFocusRequestRevision = 0
        private var pendingRequestedFocusTarget: ProjectSourceItemID?
        private var requestedFocusTask: Task<Void, Never>?

        init(parent: ProjectSourceOutlineView, root: ProjectSourceNode) {
            self.parent = parent
            self.root = root
        }

        func installInitialContent(in outlineView: NSOutlineView) {
            self.outlineView = outlineView
            expandedIDs = Set([root.id] + root.children.compactMap { node in
                switch node.id {
                case .clips, .folder: node.id
                case .project, .timeline, .asset: nil
                }
            })

            isSynchronizingSelection = true
            outlineView.reloadData()
            restoreExpansion(in: outlineView, item: root)
            synchronizeSelection(in: outlineView)
            isSynchronizingSelection = false
        }

        func reload(with item: ProjectSourceItem, importIsRunning: Bool) {
            guard let outlineView else { return }
            captureExpansion(in: outlineView)
            let change = root.reconcile(with: item)
            capturePastedAssetFocusIfAvailable(importIsRunning: importIsRunning)
            captureRequestedFocusIfAvailable()
            guard change.hasChanges else {
                synchronizeSelection(in: outlineView)
                schedulePastedAssetFocusIfNeeded(importIsRunning: importIsRunning)
                scheduleRequestedFocusIfNeeded()
                return
            }

            isSynchronizingSelection = true
            if change.structureChanged {
                outlineView.reloadItem(root, reloadChildren: true)
                restoreExpansion(in: outlineView, item: root)
            } else {
                for id in change.renamedIDs {
                    updateVisibleName(for: id, in: outlineView)
                }
            }
            synchronizeSelection(in: outlineView)
            isSynchronizingSelection = false
            schedulePastedAssetFocusIfNeeded(importIsRunning: importIsRunning)
            scheduleRequestedFocusIfNeeded()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let item = item as? ProjectSourceNode { return item.children.count }
            return 1
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let item = item as? ProjectSourceNode { return item.children[index] }
            return root
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ProjectSourceNode)?.isExpandable == true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? ProjectSourceNode else { return nil }
            if case .asset(let assetID) = item.id {
                let button: ProjectSourceButton
                if let reused = outlineView.makeView(
                    withIdentifier: .projectSourceButtonCell,
                    owner: self
                ) as? ProjectSourceButton {
                    button = reused
                } else {
                    button = ProjectSourceButton(title: "", target: self, action: #selector(openClipFromButton(_:)))
                    button.identifier = .projectSourceButtonCell
                    button.setButtonType(.momentaryPushIn)
                    button.bezelStyle = .inline
                    button.isBordered = false
                    button.alignment = .left
                    button.lineBreakMode = .byTruncatingTail
                }
                button.assetID = assetID
                button.setAccessibilityIdentifier("trimato.project-source.asset.\(assetID.uuidString)")
                button.deleteAsset = { [weak self] in
                    self?.requestDeletion(of: assetID)
                }
                button.title = item.name
                button.menu = contextMenu(for: item.id)
                return button
            }

            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: .projectSourceCell, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = .projectSourceCell
                let field = ProjectSourceLabel(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                cell.textField = field
                cell.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = item.name
            cell.textField?.menu = contextMenu(for: item.id)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection,
                  let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceNode else { return }
            parent.selection = item.id
            switch item.id {
            case .project, .timeline, .clips:
                parent.controller.selection = .project
            case .asset(let id):
                parent.controller.selection = .asset(id)
            case .folder:
                break
            }
        }

        @objc private func openClipFromButton(_ sender: ProjectSourceButton) {
            guard let assetID = sender.assetID else { return }
            selectSourceAsset(assetID)
            parent.openClipEditor(.asset(assetID))
        }

        @objc private func performContextAction(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? ProjectSourceMenuPayload else { return }
            switch command.command {
            case .open(let assetID):
                selectSourceAsset(assetID)
                parent.openClipEditor(.asset(assetID))
            case .place(let assetID, let placement):
                selectSourceAsset(assetID)
                guard let asset = parent.controller.project.asset(id: assetID) else { return }
                parent.controller.place(
                    placement,
                    editing: .asset(assetID),
                    segments: asset.sourceEdit
                )
            case .placeOnTrack(let assetID, let placement, let trackID):
                selectSourceAsset(assetID)
                guard let asset = parent.controller.project.asset(id: assetID),
                      let clipID = parent.controller.place(
                        placement,
                        editing: .asset(assetID),
                        segments: asset.sourceEdit,
                        onTrack: trackID
                      ) else { return }
                parent.controller.requestTimelineFocusRestore(to: .clip(clipID))
            case .newTrack(let assetID, let kind):
                selectSourceAsset(assetID)
                parent.requestNewTrack(assetID, kind)
            case .move(let assetID, let folderID):
                selectSourceAsset(assetID)
                parent.controller.moveAsset(assetID, toFolder: folderID)
            case .relink(let assetID):
                selectSourceAsset(assetID)
                parent.controller.relinkSelectedAsset()
            case .delete(let assetID):
                requestDeletion(of: assetID)
            case .importClips(let folderID):
                parent.controller.importFiles(into: folderID)
            case .newFolder:
                parent.requestNewFolder()
            case .renameFolder(let folderID):
                parent.requestRenameFolder(folderID)
            case .removeFolder(let folderID):
                parent.controller.removeFolder(folderID)
            }
        }

        private func selectSourceAsset(_ assetID: UUID) {
            let sourceID = ProjectSourceItemID.asset(assetID)
            parent.selection = sourceID
            parent.controller.selection = .asset(assetID)
            guard let outlineView,
                  let item = root.item(withID: sourceID) else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        private func contextMenu(for itemID: ProjectSourceItemID) -> NSMenu? {
            let menu = NSMenu()
            switch itemID {
            case .project:
                menu.addItem(menuItem("Import Clips…", command: .importClips(nil)))
                menu.addItem(menuItem("New Folder", command: .newFolder))
            case .timeline, .clips:
                return nil
            case .folder(let folderID):
                menu.addItem(menuItem("Import Clips into Folder…", command: .importClips(folderID)))
                menu.addItem(menuItem("Rename Folder…", command: .renameFolder(folderID)))
                menu.addItem(.separator())
                menu.addItem(menuItem("Remove Folder", command: .removeFolder(folderID)))
            case .asset(let assetID):
                menu.addItem(menuItem("Open Clip Editor", command: .open(assetID)))
                menu.addItem(.separator())
                for placement in PlacementAction.allCases {
                    menu.addItem(menuItem(placement.title, command: .place(assetID, placement)))
                }
                if let asset = parent.controller.project.asset(id: assetID) {
                    menu.addItem(.separator())
                    for placement in [PlacementAction.append, .insert, .replaceRemainder] {
                        let trackItem = NSMenuItem(
                            title: "\(placement.title) to Track",
                            action: nil,
                            keyEquivalent: ""
                        )
                        let trackMenu = NSMenu()
                        let tracks = parent.controller.project.tracks.filter { track in
                            (track.kind == .video && asset.hasVideo) ||
                                (track.kind == .audio && asset.hasAudio)
                        }
                        for track in tracks {
                            trackMenu.addItem(menuItem(
                                track.name,
                                command: .placeOnTrack(assetID, placement, track.id)
                            ))
                        }
                        trackItem.submenu = trackMenu
                        trackItem.isEnabled = !tracks.isEmpty
                        menu.addItem(trackItem)
                    }
                    menu.addItem(.separator())
                    for kind in NewTrackSourceKind.availableKinds(
                        hasVideo: asset.hasVideo,
                        hasAudio: asset.hasAudio
                    ) {
                        menu.addItem(menuItem(
                            kind.commandTitle,
                            command: .newTrack(assetID, kind)
                        ))
                    }
                }
                menu.addItem(.separator())

                let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
                let moveMenu = NSMenu()
                moveMenu.addItem(menuItem("Project Root", command: .move(assetID, nil)))
                for folder in parent.controller.project.folders {
                    moveMenu.addItem(menuItem(folder.name, command: .move(assetID, folder.id)))
                }
                moveItem.submenu = moveMenu
                menu.addItem(moveItem)

                if let asset = parent.controller.project.asset(id: assetID),
                   parent.controller.resolveURL(for: asset) == nil {
                    menu.addItem(menuItem("Relink Clip…", command: .relink(assetID)))
                }
                menu.addItem(.separator())
                menu.addItem(menuItem("Delete Source Clip", command: .delete(assetID)))
            }
            return menu
        }

        func contextMenuForSelectedRow() -> NSMenu? {
            guard let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceNode else {
                return nil
            }
            return contextMenu(for: item.id)
        }

        func pasteboardFileURLs() -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [URL] ?? []
        }

        func pasteFilesFromFinder() {
            let urls = pasteboardFileURLs()
            guard !urls.isEmpty, !parent.controller.isImporting else { return }
            pastedImportBaselineAssetIDs = Set(parent.controller.project.media.map(\.id))
            pendingPastedAssetFocusID = nil
            pastedAssetFocusTask?.cancel()
            parent.controller.importFiles(at: urls, into: selectedDestinationFolderID())
        }

        func deleteSelectedAsset() {
            guard let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceNode,
                  case .asset(let assetID) = item.id else { return }
            requestDeletion(of: assetID)
        }

        private func requestDeletion(of assetID: UUID) {
            selectSourceAsset(assetID)
            parent.requestDeleteAsset(assetID)
        }

        private func capturePastedAssetFocusIfAvailable(importIsRunning: Bool) {
            guard let pastedImportBaselineAssetIDs else { return }
            if let assetID = ProjectSourcePasteFocus.firstImportedAssetID(
                existingAssetIDs: pastedImportBaselineAssetIDs,
                assets: parent.controller.project.media
            ) {
                let sourceID = ProjectSourceItemID.asset(assetID)
                pendingPastedAssetFocusID = assetID
                self.pastedImportBaselineAssetIDs = nil
                parent.selection = sourceID
                parent.controller.selection = .asset(assetID)
            } else if !importIsRunning {
                self.pastedImportBaselineAssetIDs = nil
            }
        }

        private func captureRequestedFocusIfAvailable() {
            let request = parent.focusRequest
            guard request.revision > handledFocusRequestRevision,
                  let target = request.target else { return }
            handledFocusRequestRevision = request.revision
            pendingRequestedFocusTarget = target
        }

        private func scheduleRequestedFocusIfNeeded() {
            guard pendingRequestedFocusTarget != nil else { return }
            requestedFocusTask?.cancel()
            requestedFocusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                if self.focusPendingRequestedItem() { return }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                _ = self.focusPendingRequestedItem()
            }
        }

        private func focusPendingRequestedItem() -> Bool {
            guard let target = pendingRequestedFocusTarget,
                  let outlineView,
                  let item = root.item(withID: target) else { return false }
            expandAncestors(of: target, in: outlineView)
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { return false }

            isSynchronizingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isSynchronizingSelection = false

            let focusedElement: Any
            if case .asset = target,
               let button = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
               ) as? ProjectSourceButton {
                guard outlineView.window?.makeFirstResponder(button) == true else { return false }
                focusedElement = button
            } else {
                guard outlineView.window?.makeFirstResponder(outlineView) == true else { return false }
                focusedElement = outlineView
            }

            pendingRequestedFocusTarget = nil
            requestedFocusTask = nil
            NSAccessibility.post(element: outlineView, notification: .selectedRowsChanged)
            NSAccessibility.post(element: focusedElement, notification: .focusedUIElementChanged)
            return true
        }

        private func schedulePastedAssetFocusIfNeeded(importIsRunning: Bool) {
            guard ProjectSourcePasteFocus.shouldAttemptFocus(
                hasPendingAsset: pendingPastedAssetFocusID != nil,
                importIsRunning: importIsRunning
            ) else { return }
            pastedAssetFocusTask?.cancel()
            pastedAssetFocusTask = Task { @MainActor [weak self] in
                let delays = [0, 200, 550]
                for delay in delays {
                    if delay == 0 {
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    guard !Task.isCancelled, let self else { return }
                    if self.focusPendingPastedAsset() { return }
                }
                self?.pastedAssetFocusTask = nil
            }
        }

        private func focusPendingPastedAsset() -> Bool {
            guard let assetID = pendingPastedAssetFocusID,
                  let outlineView,
                  let item = root.item(withID: .asset(assetID)) else { return false }
            expandAncestors(of: item.id, in: outlineView)
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { return false }

            isSynchronizingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isSynchronizingSelection = false

            guard let button = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) as? ProjectSourceButton else { return false }

            guard outlineView.window?.makeFirstResponder(outlineView) == true else { return false }
            outlineView.setAccessibilityFocused(true)
            guard let rowElement = ProjectSourcePasteFocus.selectedAccessibilityRow(
                from: outlineView.accessibilitySelectedRows()
            ),
                  let focusTarget = NSAccessibility.unignoredDescendant(of: button) else { return false }

            NSApp.setAccessibilityApplicationFocusedUIElement(focusTarget)
            NSAccessibility.post(element: outlineView, notification: .selectedRowsChanged)
            NSAccessibility.post(element: focusTarget, notification: .focusedUIElementChanged)

            var didEstablishFocus = accessibilityFocus(
                NSApp.accessibilityFocusedUIElement,
                matches: focusTarget,
                within: rowElement
            )
            if !didEstablishFocus {
                NSApp.setAccessibilityApplicationFocusedUIElement(rowElement)
                NSAccessibility.post(element: rowElement, notification: .focusedUIElementChanged)
                didEstablishFocus = accessibilityFocus(
                    NSApp.accessibilityFocusedUIElement,
                    matches: rowElement,
                    within: rowElement
                )
            }
            guard !ProjectSourcePasteFocus.shouldRetryFocus(
                didResolveTarget: true,
                didEstablishFocus: didEstablishFocus
            ) else { return false }

            pendingPastedAssetFocusID = nil
            pastedAssetFocusTask = nil
            return true
        }

        private func accessibilityFocus(_ focusedElement: Any?, matches target: Any, within row: Any) -> Bool {
            if sameAccessibilityObject(focusedElement, target) || sameAccessibilityObject(focusedElement, row) {
                return true
            }
            guard var candidate = focusedElement as? NSObject else { return false }
            for _ in 0..<8 {
                guard let accessibleCandidate = candidate as? any NSAccessibilityProtocol,
                      let parent = accessibleCandidate.accessibilityParent() as? NSObject else { return false }
                if sameAccessibilityObject(parent, target) || sameAccessibilityObject(parent, row) {
                    return true
                }
                candidate = parent
            }
            return false
        }

        private func sameAccessibilityObject(_ lhs: Any?, _ rhs: Any) -> Bool {
            guard let lhs = lhs as AnyObject? else { return false }
            return lhs === (rhs as AnyObject)
        }

        private func expandAncestors(of id: ProjectSourceItemID, in outlineView: NSOutlineView) {
            guard let path = nodePath(to: id, from: root) else { return }
            for ancestor in path.dropLast() where ancestor.isExpandable {
                expandedIDs.insert(ancestor.id)
                outlineView.expandItem(ancestor)
            }
        }

        private func nodePath(
            to id: ProjectSourceItemID,
            from node: ProjectSourceNode
        ) -> [ProjectSourceNode]? {
            if node.id == id { return [node] }
            for child in node.children {
                if let path = nodePath(to: id, from: child) {
                    return [node] + path
                }
            }
            return nil
        }

        private func selectedDestinationFolderID() -> UUID? {
            guard let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceNode else {
                return nil
            }
            switch item.id {
            case .folder(let folderID):
                return folderID
            case .asset(let assetID):
                return parent.controller.project.folders.first { $0.assetIDs.contains(assetID) }?.id
            case .project, .timeline, .clips:
                return nil
            }
        }

        private func menuItem(
            _ title: String,
            command: ProjectSourceMenuCommand
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ProjectSourceMenuPayload(command: command)
            return item
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            fileURLs(from: info).isEmpty ? [] : .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            let urls = fileURLs(from: info)
            guard !urls.isEmpty else { return false }
            let folderID: UUID?
            if let sourceItem = item as? ProjectSourceNode {
                switch sourceItem.id {
                case .folder(let id): folderID = id
                case .project, .timeline, .clips, .asset: folderID = nil
                }
            } else {
                folderID = nil
            }
            parent.controller.importFiles(at: urls, into: folderID)
            return true
        }

        private func fileURLs(from info: NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        }

        private func captureExpansion(in outlineView: NSOutlineView) {
            expandedIDs.removeAll()
            captureExpansion(of: root, in: outlineView)
        }

        private func captureExpansion(of item: ProjectSourceNode, in outlineView: NSOutlineView) {
            if outlineView.isItemExpanded(item) { expandedIDs.insert(item.id) }
            for child in item.children where child.isExpandable {
                captureExpansion(of: child, in: outlineView)
            }
        }

        private func restoreExpansion(in outlineView: NSOutlineView, item: ProjectSourceNode) {
            if expandedIDs.contains(item.id) { outlineView.expandItem(item) }
            for child in item.children where child.isExpandable {
                restoreExpansion(in: outlineView, item: child)
            }
        }

        private func synchronizeSelection(in outlineView: NSOutlineView) {
            let requested = parent.selection ?? .timeline(parent.controller.project.id)
            guard let item = root.item(withID: requested) else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0, outlineView.selectedRow != row else { return }
            let wasSynchronizing = isSynchronizingSelection
            isSynchronizingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isSynchronizingSelection = wasSynchronizing
        }

        private func updateVisibleName(for id: ProjectSourceItemID, in outlineView: NSOutlineView) {
            guard let node = root.item(withID: id) else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0,
                  let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
            if let button = view as? ProjectSourceButton {
                button.title = node.name
            } else if let cell = view as? NSTableCellView {
                cell.textField?.stringValue = node.name
            }
        }
    }
}

nonisolated struct ProjectSourceNodeChange: Equatable, Sendable {
    var structureChanged = false
    var renamedIDs: Set<ProjectSourceItemID> = []

    var hasChanges: Bool {
        structureChanged || !renamedIDs.isEmpty
    }

    mutating func merge(_ other: Self) {
        structureChanged = structureChanged || other.structureChanged
        renamedIDs.formUnion(other.renamedIDs)
    }
}

final class ProjectSourceNode: NSObject {
    let id: ProjectSourceItemID
    private(set) var name: String
    private(set) var children: [ProjectSourceNode]

    var isExpandable: Bool {
        switch id {
        case .project, .clips, .folder: true
        case .timeline, .asset: false
        }
    }

    init(item: ProjectSourceItem) {
        id = item.id
        name = item.name
        var childNodes: [ProjectSourceNode] = []
        for child in item.children {
            childNodes.append(ProjectSourceNode(item: child))
        }
        children = childNodes
    }

    func item(withID requestedID: ProjectSourceItemID) -> ProjectSourceNode? {
        if id == requestedID { return self }
        for child in children {
            if let match = child.item(withID: requestedID) { return match }
        }
        return nil
    }

    func reconcile(with item: ProjectSourceItem) -> ProjectSourceNodeChange {
        precondition(id == item.id)
        var change = ProjectSourceNodeChange()
        if name != item.name {
            name = item.name
            change.renamedIDs.insert(id)
        }

        let previousIDs = children.map(\.id)
        let existingChildren = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        var reconciledChildren: [ProjectSourceNode] = []
        for childItem in item.children {
            if let existing = existingChildren[childItem.id] {
                change.merge(existing.reconcile(with: childItem))
                reconciledChildren.append(existing)
            } else {
                reconciledChildren.append(ProjectSourceNode(item: childItem))
            }
        }
        let reconciledIDs = reconciledChildren.map(\.id)
        if previousIDs != reconciledIDs {
            change.structureChanged = true
        }
        children = reconciledChildren
        return change
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let projectSourceColumn = NSUserInterfaceItemIdentifier("ProjectSourceColumn")
    static let projectSourceCell = NSUserInterfaceItemIdentifier("ProjectSourceCell")
    static let projectSourceButtonCell = NSUserInterfaceItemIdentifier("ProjectSourceButtonCell")
}

private final class ProjectSourceOutline: NSOutlineView {
    var menuForSelectedRow: (() -> NSMenu?)?
    var canPasteFiles: (() -> Bool)?
    var pasteFiles: (() -> Void)?
    var deleteSelectedAsset: (() -> Void)?

    @IBAction func paste(_ sender: Any?) {
        pasteFiles?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !event.isARepeat,
           ProjectSourceKeyboardCommand.resolve(
            keyCode: event.keyCode,
            hasAnyModifiers: !modifiers.isEmpty
           ) == .delete {
            deleteSelectedAsset?()
            return
        }
        super.keyDown(with: event)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return canPasteFiles?() == true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        if clickedRow >= 0 {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return menuForSelectedRow?()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard selectedRow >= 0, let menu = menuForSelectedRow?() else { return false }
        let rowFrame = rect(ofRow: selectedRow)
        menu.popUp(positioning: nil, at: NSPoint(x: rowFrame.minX, y: rowFrame.maxY), in: self)
        return true
    }
}

private final class ProjectSourceButton: NSButton {
    var assetID: UUID?
    var deleteAsset: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !event.isARepeat,
           ProjectSourceKeyboardCommand.resolve(
            keyCode: event.keyCode,
            hasAnyModifiers: !modifiers.isEmpty
           ) == .delete {
            deleteAsset?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
        return true
    }
}

private final class ProjectSourceLabel: NSTextField {
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
        return true
    }
}

private enum ProjectSourceMenuCommand {
    case open(UUID)
    case place(UUID, PlacementAction)
    case placeOnTrack(UUID, PlacementAction, UUID)
    case newTrack(UUID, NewTrackSourceKind)
    case move(UUID, UUID?)
    case relink(UUID)
    case delete(UUID)
    case importClips(UUID?)
    case newFolder
    case renameFolder(UUID)
    case removeFolder(UUID)
}

private final class ProjectSourceMenuPayload: NSObject {
    let command: ProjectSourceMenuCommand

    init(command: ProjectSourceMenuCommand) {
        self.command = command
    }
}
