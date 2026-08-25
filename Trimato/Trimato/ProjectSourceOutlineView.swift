import AppKit
import SwiftUI

struct ProjectSourceOutlineView: NSViewRepresentable {
    @ObservedObject var controller: ProjectController
    @Binding var selection: ProjectSourceItemID?
    let openClipEditor: (EditorSelection) -> Void
    let requestNewFolder: () -> Void
    let requestRenameFolder: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProjectSourceOutline()
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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.outlineView = outline
        context.coordinator.reload(with: ProjectSourceItem.hierarchy(for: controller.project))
        scrollView.documentView = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(with: ProjectSourceItem.hierarchy(for: controller.project))
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: ProjectSourceOutlineView
        weak var outlineView: NSOutlineView?
        private var root: ProjectSourceItem?
        private var expandedIDs: Set<ProjectSourceItemID> = []
        private var hasEstablishedExpansion = false
        private var isSynchronizingSelection = false

        init(parent: ProjectSourceOutlineView) {
            self.parent = parent
        }

        func reload(with root: ProjectSourceItem) {
            guard let outlineView else { return }

            if self.root == root {
                synchronizeSelection(in: outlineView)
                return
            }

            if hasEstablishedExpansion {
                captureExpansion(in: outlineView)
            } else {
                expandedIDs = Set([root.id] + root.children.compactMap { item in
                    switch item.id {
                    case .clips, .folder: item.id
                    case .project, .timeline, .asset: nil
                    }
                })
                hasEstablishedExpansion = true
            }

            isSynchronizingSelection = true
            self.root = root
            outlineView.reloadData()
            restoreExpansion(in: outlineView, item: root)
            synchronizeSelection(in: outlineView)
            isSynchronizingSelection = false
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let item = item as? ProjectSourceItem { return item.children.count }
            return root == nil ? 0 : 1
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let item = item as? ProjectSourceItem { return item.children[index] }
            return root as Any
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ProjectSourceItem)?.isExpandable == true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? ProjectSourceItem else { return nil }
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
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceItem else { return }
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
            case .move(let assetID, let folderID):
                selectSourceAsset(assetID)
                parent.controller.moveAsset(assetID, toFolder: folderID)
            case .relink(let assetID):
                selectSourceAsset(assetID)
                parent.controller.relinkSelectedAsset()
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
                  let item = root?.item(withID: sourceID) else { return }
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
            }
            return menu
        }

        func contextMenuForSelectedRow() -> NSMenu? {
            guard let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceItem else {
                return nil
            }
            return contextMenu(for: item.id)
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
            if let sourceItem = item as? ProjectSourceItem {
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
            guard let root else { return }
            expandedIDs.removeAll()
            captureExpansion(of: root, in: outlineView)
        }

        private func captureExpansion(of item: ProjectSourceItem, in outlineView: NSOutlineView) {
            if outlineView.isItemExpanded(item) { expandedIDs.insert(item.id) }
            for child in item.children where child.isExpandable {
                captureExpansion(of: child, in: outlineView)
            }
        }

        private func restoreExpansion(in outlineView: NSOutlineView, item: ProjectSourceItem) {
            if expandedIDs.contains(item.id) { outlineView.expandItem(item) }
            for child in item.children where child.isExpandable {
                restoreExpansion(in: outlineView, item: child)
            }
        }

        private func synchronizeSelection(in outlineView: NSOutlineView) {
            let requested = parent.selection ?? .timeline(parent.controller.project.id)
            guard let root, let item = root.item(withID: requested) else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0, outlineView.selectedRow != row else { return }
            let wasSynchronizing = isSynchronizingSelection
            isSynchronizingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isSynchronizingSelection = wasSynchronizing
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let projectSourceColumn = NSUserInterfaceItemIdentifier("ProjectSourceColumn")
    static let projectSourceCell = NSUserInterfaceItemIdentifier("ProjectSourceCell")
    static let projectSourceButtonCell = NSUserInterfaceItemIdentifier("ProjectSourceButtonCell")
}

private final class ProjectSourceOutline: NSOutlineView {
    var menuForSelectedRow: (() -> NSMenu?)?

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
    case move(UUID, UUID?)
    case relink(UUID)
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
