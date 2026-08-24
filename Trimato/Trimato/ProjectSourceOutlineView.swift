import AppKit
import SwiftUI

struct ProjectSourceOutlineView: NSViewRepresentable {
    @ObservedObject var controller: ProjectController
    @Binding var selection: ProjectSourceItemID?
    let openClipEditor: (EditorSelection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .projectSourceColumn)
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .medium
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.autosaveExpandedItems = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Project Items")
        outline.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.outlineView = outline
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
                    if case .folder = item.id { return item.id }
                    return nil
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
                let cell: ProjectSourceButtonCellView
                if let reused = outlineView.makeView(
                    withIdentifier: .projectSourceButtonCell,
                    owner: self
                ) as? ProjectSourceButtonCellView {
                    cell = reused
                } else {
                    cell = ProjectSourceButtonCellView()
                    cell.identifier = .projectSourceButtonCell
                    cell.button.target = self
                    cell.button.action = #selector(openClipFromButton(_:))
                }
                cell.assetID = assetID
                cell.button.title = item.name
                cell.button.menu = contextMenu(for: assetID)
                return cell
            }

            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: .projectSourceCell, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = .projectSourceCell
                let field = NSTextField(labelWithString: "")
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
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection,
                  let outlineView,
                  outlineView.selectedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceItem else { return }
            parent.selection = item.id
            switch item.id {
            case .project, .timeline:
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
            guard let payload = sender.representedObject as? ProjectSourceMenuPayload else { return }
            selectSourceAsset(payload.assetID)
            switch payload.command {
            case .open:
                parent.openClipEditor(.asset(payload.assetID))
            case .place(let placement):
                guard let asset = parent.controller.project.asset(id: payload.assetID) else { return }
                parent.controller.place(
                    placement,
                    editing: .asset(payload.assetID),
                    segments: asset.sourceEdit
                )
            case .move(let folderID):
                parent.controller.moveAsset(payload.assetID, toFolder: folderID)
            case .relink:
                parent.controller.selection = .asset(payload.assetID)
                parent.controller.relinkSelectedAsset()
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

        private func contextMenu(for assetID: UUID) -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem("Open Clip Editor", assetID: assetID, command: .open))
            menu.addItem(.separator())
            for placement in PlacementAction.allCases {
                menu.addItem(menuItem(placement.title, assetID: assetID, command: .place(placement)))
            }
            menu.addItem(.separator())

            let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
            let moveMenu = NSMenu()
            moveMenu.addItem(menuItem("Project Root", assetID: assetID, command: .move(nil)))
            for folder in parent.controller.project.folders {
                moveMenu.addItem(menuItem(folder.name, assetID: assetID, command: .move(folder.id)))
            }
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)

            if let asset = parent.controller.project.asset(id: assetID),
               parent.controller.resolveURL(for: asset) == nil {
                menu.addItem(menuItem("Relink Clip…", assetID: assetID, command: .relink))
            }
            return menu
        }

        private func menuItem(
            _ title: String,
            assetID: UUID,
            command: ProjectSourceMenuCommand
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ProjectSourceMenuPayload(assetID: assetID, command: command)
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
            if let sourceItem = item as? ProjectSourceItem, case .folder(let id) = sourceItem.id {
                folderID = id
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

private final class ProjectSourceButton: NSButton {
    var assetID: UUID?
}

private final class ProjectSourceButtonCellView: NSTableCellView {
    let button = ProjectSourceButton(title: "", target: nil, action: nil)

    var assetID: UUID? {
        get { button.assetID }
        set { button.assetID = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum ProjectSourceMenuCommand {
    case open
    case place(PlacementAction)
    case move(UUID?)
    case relink
}

private final class ProjectSourceMenuPayload: NSObject {
    let assetID: UUID
    let command: ProjectSourceMenuCommand

    init(assetID: UUID, command: ProjectSourceMenuCommand) {
        self.assetID = assetID
        self.command = command
    }
}
