import AppKit
import SwiftUI

nonisolated enum ProjectSourcePasteFocus {
    static func firstImportedAssetID(
        existingAssetIDs: Set<UUID>,
        assets: [MediaAssetRecord]
    ) -> UUID? {
        assets.first { !existingAssetIDs.contains($0.id) }?.id
    }

    static func shouldRestoreFocus(pendingAssetID: UUID?, importIsRunning: Bool) -> Bool {
        pendingAssetID != nil && !importIsRunning
    }
}

struct ProjectSourceOutlineView: View {
    @ObservedObject var controller: ProjectController
    @Binding var selection: ProjectSourceItemID?
    let openClipEditor: (EditorSelection) -> Void
    let requestNewFolder: () -> Void
    let requestRenameFolder: (UUID) -> Void
    let requestDeleteAsset: (UUID) -> Void
    let requestNewTrack: (UUID, NewTrackSourceKind) -> Void
    let focusRequest: ProjectSourceFocusRequest

    @State private var pastedImportBaselineAssetIDs: Set<UUID>?
    @State private var pendingPastedAssetFocusID: UUID?
    @State private var pastedFocusRequest = ProjectSourceFocusRequest()

    var body: some View {
        ProjectSourceNativeOutline(
            controller: controller,
            hierarchy: ProjectSourceItem.hierarchy(for: controller.project),
            selection: $selection,
            focusRequest: focusRequest,
            pastedFocusRequest: pastedFocusRequest,
            openClipEditor: openClipEditor,
            requestNewFolder: requestNewFolder,
            requestRenameFolder: requestRenameFolder,
            requestDeleteAsset: requestDeleteAsset,
            requestNewTrack: requestNewTrack,
            importFiles: importFiles,
            selectionChanged: synchronizeControllerSelection
        )
        .onChange(of: selection) { _, selectedItem in
            synchronizeControllerSelection(selectedItem)
        }
        .onChange(of: controller.project.media.map(\.id)) {
            capturePastedAssetFocusIfAvailable()
        }
        .onChange(of: controller.isImporting) {
            capturePastedAssetFocusIfAvailable()
            restorePastedAssetFocusIfReady()
        }
    }

    private func synchronizeControllerSelection(_ item: ProjectSourceItemID?) {
        switch item {
        case .asset(let id):
            if controller.selection != .asset(id) { controller.selection = .asset(id) }
            controller.setProjectInfoTarget(.selection(.asset(id)))
        case .project, .timeline, .clips:
            if controller.selection != .project { controller.selection = .project }
            controller.setProjectInfoTarget(.selection(.project))
        case .folder(let id):
            controller.setProjectInfoTarget(.folder(id))
        case .generators, .none:
            break
        }
    }

    @discardableResult
    private func importFiles(_ urls: [URL], into folderID: UUID?) -> Bool {
        guard !urls.isEmpty, !controller.isImporting else { return false }
        pastedImportBaselineAssetIDs = Set(controller.project.media.map(\.id))
        pendingPastedAssetFocusID = nil
        controller.importFiles(at: urls, into: folderID)
        return true
    }

    private func capturePastedAssetFocusIfAvailable() {
        guard let pastedImportBaselineAssetIDs else { return }
        if let assetID = ProjectSourcePasteFocus.firstImportedAssetID(
            existingAssetIDs: pastedImportBaselineAssetIDs,
            assets: controller.project.media
        ) {
            pendingPastedAssetFocusID = assetID
            self.pastedImportBaselineAssetIDs = nil
            selection = .asset(assetID)
            synchronizeControllerSelection(.asset(assetID))
        } else if !controller.isImporting {
            self.pastedImportBaselineAssetIDs = nil
        }
    }

    private func restorePastedAssetFocusIfReady() {
        guard ProjectSourcePasteFocus.shouldRestoreFocus(
            pendingAssetID: pendingPastedAssetFocusID,
            importIsRunning: controller.isImporting
        ), let assetID = pendingPastedAssetFocusID else { return }
        pendingPastedAssetFocusID = nil
        let nextRevision = pastedFocusRequest.revision + 1
        pastedFocusRequest = ProjectSourceFocusRequest(target: .asset(assetID), revision: nextRevision)
    }
}

private struct ProjectSourceNativeOutline: NSViewRepresentable {
    let controller: ProjectController
    let hierarchy: ProjectSourceItem
    @Binding var selection: ProjectSourceItemID?
    let focusRequest: ProjectSourceFocusRequest
    let pastedFocusRequest: ProjectSourceFocusRequest
    let openClipEditor: (EditorSelection) -> Void
    let requestNewFolder: () -> Void
    let requestRenameFolder: (UUID) -> Void
    let requestDeleteAsset: (UUID) -> Void
    let requestNewTrack: (UUID, NewTrackSourceKind) -> Void
    let importFiles: ([URL], UUID?) -> Bool
    let selectionChanged: (ProjectSourceItemID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProjectSourceAppKitOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectSourceName"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = false
        outline.autosaveExpandedItems = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openSelectedItem)
        outline.setAccessibilityLabel("Project Source")
        outline.setAccessibilityIdentifier("trimato.project-source.outline")
        outline.registerForDraggedTypes([.fileURL])

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.outlineView = outline
        outline.owner = context.coordinator
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: ProjectSourceAppKitOutlineView?
        private var source: ProjectSourceNativeOutline?
        private var root: ProjectSourceNode?
        private var nodes: [ProjectSourceItemID: ProjectSourceNode] = [:]
        private var snapshot: ProjectSourceItem?
        private var expandedIDs: Set<ProjectSourceItemID> = []
        private var handledFocusRevision = 0
        private var handledPastedFocusRevision = 0
        private var isUpdating = false
        private let cellIdentifier = NSUserInterfaceItemIdentifier("ProjectSourceCell")
        private let assetButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectSourceAssetButton")

        func update(from source: ProjectSourceNativeOutline) {
            self.source = source
            guard let outlineView else { return }
            if snapshot != source.hierarchy {
                let priorIDs = Set(nodes.keys)
                var activeIDs: Set<ProjectSourceItemID> = []
                root = updateNode(from: source.hierarchy, activeIDs: &activeIDs)
                nodes = nodes.filter { activeIDs.contains($0.key) }

                if snapshot == nil {
                    expandedIDs = source.hierarchy.defaultExpandedIDs
                } else {
                    let addedIDs = activeIDs.subtracting(priorIDs)
                    expandedIDs.formUnion(addedIDs.filter {
                        source.hierarchy.item(withID: $0)?.isExpandable == true
                    })
                    expandedIDs.formIntersection(activeIDs)
                }
                snapshot = source.hierarchy

                isUpdating = true
                outlineView.reloadData()
                restoreExpansion()
                restoreSelection(source.selection)
                isUpdating = false
            } else if selectedID != source.selection {
                restoreSelection(source.selection)
            }

            if focusRequestIsNew(source.focusRequest) {
                focus(source.focusRequest.target)
            }
            if pastedFocusRequestIsNew(source.pastedFocusRequest) {
                focus(source.pastedFocusRequest.target)
            }
        }

        private func updateNode(
            from item: ProjectSourceItem,
            activeIDs: inout Set<ProjectSourceItemID>
        ) -> ProjectSourceNode {
            activeIDs.insert(item.id)
            let node = nodes[item.id] ?? ProjectSourceNode(id: item.id, name: item.name)
            nodes[item.id] = node
            node.name = item.name
            node.children = item.children.map { updateNode(from: $0, activeIDs: &activeIDs) }
            return node
        }

        private func focusRequestIsNew(_ request: ProjectSourceFocusRequest) -> Bool {
            guard request.revision > handledFocusRevision else { return false }
            handledFocusRevision = request.revision
            return request.target != nil
        }

        private func pastedFocusRequestIsNew(_ request: ProjectSourceFocusRequest) -> Bool {
            guard request.revision > handledPastedFocusRevision else { return false }
            handledPastedFocusRevision = request.revision
            return request.target != nil
        }

        private var selectedID: ProjectSourceItemID? {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? ProjectSourceNode else { return nil }
            return node.id
        }

        private func restoreExpansion() {
            guard let root else { return }
            restoreExpansion(of: root)
        }

        private func restoreExpansion(of node: ProjectSourceNode) {
            guard let outlineView else { return }
            if expandedIDs.contains(node.id) { outlineView.expandItem(node) }
            for child in node.children { restoreExpansion(of: child) }
        }

        private func restoreSelection(_ id: ProjectSourceItemID?) {
            guard let outlineView, let id, let node = nodes[id] else { return }
            expandAncestors(of: id)
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            let wasUpdating = isUpdating
            isUpdating = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isUpdating = wasUpdating
        }

        private func focus(_ id: ProjectSourceItemID?) {
            guard let outlineView, let id else { return }
            restoreSelection(id)
            let row = nodes[id].map(outlineView.row(forItem:)) ?? -1
            guard row >= 0 else { return }
            outlineView.scrollRowToVisible(row)
            outlineView.window?.makeFirstResponder(outlineView)
        }

        private func expandAncestors(of id: ProjectSourceItemID) {
            guard let source, let outlineView else { return }
            for ancestorID in source.hierarchy.ancestorIDs(of: id) {
                guard let node = nodes[ancestorID] else { continue }
                expandedIDs.insert(ancestorID)
                outlineView.expandItem(node)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? ProjectSourceNode { return node.children.count }
            return root == nil ? 0 : 1
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? ProjectSourceNode { return node.children[index] }
            return root!
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ProjectSourceNode)?.isExpandable == true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? ProjectSourceNode else { return nil }
            if case .asset(let assetID) = node.id {
                let button: ProjectSourceAssetButton
                if let reusable = outlineView.makeView(
                    withIdentifier: assetButtonIdentifier,
                    owner: self
                ) as? ProjectSourceAssetButton {
                    button = reusable
                } else {
                    button = ProjectSourceAssetButton()
                    button.identifier = assetButtonIdentifier
                }
                button.configure(
                    assetID: assetID,
                    title: node.name,
                    owner: self,
                    accessibilityIdentifier: accessibilityIdentifier(for: node.id)
                )
                return button
            }
            let cell: NSTableCellView
            if let reusable = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
                cell = reusable
            } else {
                cell = NSTableCellView()
                cell.identifier = cellIdentifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                cell.textField = label
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = node.name
            cell.setAccessibilityLabel(node.isExpandable ? node.name : nil)
            cell.setAccessibilityIdentifier(accessibilityIdentifier(for: node.id))
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let id = selectedID else { return }
            setSelection(id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? ProjectSourceNode else { return }
            expandedIDs.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? ProjectSourceNode else { return }
            expandedIDs.remove(node.id)
        }

        @objc func openSelectedItem() {
            guard case .asset(let id) = selectedID else { return }
            activateAsset(id)
        }

        func selectAsset(_ id: UUID) {
            guard let outlineView, let node = nodes[.asset(id)] else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            let wasUpdating = isUpdating
            isUpdating = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isUpdating = wasUpdating
            setSelection(.asset(id))
        }

        func activateAsset(_ id: UUID) {
            selectAsset(id)
            source?.openClipEditor(.asset(id))
        }

        func deleteSelectedItem() {
            guard case .asset(let id) = selectedID else { return }
            setSelection(.asset(id))
            source?.requestDeleteAsset(id)
        }

        func pasteFiles(_ urls: [URL]) {
            guard let source, !urls.isEmpty else { return }
            _ = source.importFiles(urls, destinationFolderID(for: selectedID))
        }

        func menu(for id: ProjectSourceItemID) -> NSMenu? {
            guard let source else { return nil }
            setSelection(id)
            let menu = NSMenu()
            switch id {
            case .project:
                add("Import Clips…", to: menu) { source.controller.importFiles() }
                add("New Folder", to: menu, action: source.requestNewFolder)
            case .folder(let folderID):
                add("Import Clips into Folder…", to: menu) { source.controller.importFiles(into: folderID) }
                add("Rename Folder…", to: menu) { source.requestRenameFolder(folderID) }
                menu.addItem(.separator())
                add("Remove Folder", to: menu) { source.controller.removeFolder(folderID) }
            case .asset(let assetID):
                guard let asset = source.controller.project.asset(id: assetID) else { return nil }
                add("Open Clip Editor", to: menu) { source.openClipEditor(.asset(assetID)) }
                menu.addItem(.separator())
                for placement in PlacementAction.allCases {
                    add(placement.title, to: menu) {
                        source.controller.place(placement, editing: .asset(assetID), segments: asset.sourceEdit)
                    }
                }
                menu.addItem(.separator())
                for placement in trackPlacementActions {
                    let submenu = NSMenu(title: "\(placement.title) to Track")
                    let tracks = compatibleTracks(for: asset)
                    for track in tracks {
                        add(track.name, to: submenu) {
                            guard let clipID = source.controller.place(
                                placement,
                                editing: .asset(assetID),
                                segments: asset.sourceEdit,
                                onTrack: track.id
                            ) else { return }
                            source.controller.requestTimelineFocusRestore(to: .clip(clipID))
                        }
                    }
                    let item = NSMenuItem(title: "\(placement.title) to Track", action: nil, keyEquivalent: "")
                    item.submenu = submenu
                    item.isEnabled = !tracks.isEmpty
                    menu.addItem(item)
                }
                menu.addItem(.separator())
                for kind in NewTrackSourceKind.availableKinds(hasVideo: asset.hasVideo, hasAudio: asset.hasAudio) {
                    add(kind.commandTitle, to: menu) { source.requestNewTrack(assetID, kind) }
                }
                if asset.generator == nil {
                    menu.addItem(.separator())
                    let folderMenu = NSMenu(title: "Move Clip")
                    add("Project Root", to: folderMenu) { source.controller.moveAsset(assetID, toFolder: nil) }
                    for folder in source.controller.project.folders {
                        add(folder.name, to: folderMenu) {
                            source.controller.moveAsset(assetID, toFolder: folder.id)
                        }
                    }
                    let folderItem = NSMenuItem(title: "Move Clip", action: nil, keyEquivalent: "")
                    folderItem.submenu = folderMenu
                    menu.addItem(folderItem)
                    if source.controller.resolveURL(for: asset) == nil {
                        add("Relink Clip…", to: menu) {
                            source.controller.selection = .asset(assetID)
                            source.controller.relinkSelectedAsset()
                        }
                    }
                }
                menu.addItem(.separator())
                add("Delete Source Clip", to: menu) { source.requestDeleteAsset(assetID) }
            case .timeline, .clips, .generators:
                return nil
            }
            return menu
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            fileURLs(from: info.draggingPasteboard).isEmpty ? [] : .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let source else { return false }
            let urls = fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            let id = (item as? ProjectSourceNode)?.id
            return source.importFiles(urls, destinationFolderID(for: id))
        }

        private func setSelection(_ id: ProjectSourceItemID) {
            guard let source else { return }
            if source.selection != id { source.$selection.wrappedValue = id }
            source.selectionChanged(id)
        }

        private func destinationFolderID(for id: ProjectSourceItemID?) -> UUID? {
            guard let source else { return nil }
            switch id {
            case .folder(let folderID): return folderID
            case .asset(let assetID):
                return source.controller.project.folders.first { $0.assetIDs.contains(assetID) }?.id
            default: return nil
            }
        }

        private var trackPlacementActions: [PlacementAction] {
            [.append, .insert, .replaceRemainder]
        }

        private func compatibleTracks(for asset: MediaAssetRecord) -> [TimelineTrack] {
            guard let source else { return [] }
            return source.controller.project.orderedTimelineTracks.filter { track in
                (track.kind == .video && asset.hasVideo) || (track.kind == .audio && asset.hasAudio)
            }
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let values = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL] ?? []
            return values.compactMap { $0 as URL }
        }

        private func accessibilityIdentifier(for id: ProjectSourceItemID) -> String {
            switch id {
            case .project(let value): "trimato.project-source.project.\(value.uuidString)"
            case .timeline(let value): "trimato.project-source.timeline.\(value.uuidString)"
            case .clips(let value): "trimato.project-source.clips.\(value.uuidString)"
            case .generators(let value): "trimato.project-source.generators.\(value.uuidString)"
            case .folder(let value): "trimato.project-source.folder.\(value.uuidString)"
            case .asset(let value): "trimato.project-source.asset.\(value.uuidString)"
            }
        }

        @discardableResult
        private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
            let target = ProjectSourceMenuAction(action)
            let item = NSMenuItem(
                title: title,
                action: #selector(ProjectSourceMenuAction.invoke),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = target
            menu.addItem(item)
            return item
        }
    }
}

private final class ProjectSourceNode: NSObject {
    let id: ProjectSourceItemID
    var name: String
    var children: [ProjectSourceNode] = []

    init(id: ProjectSourceItemID, name: String) {
        self.id = id
        self.name = name
    }

    var isExpandable: Bool {
        switch id {
        case .project, .clips, .generators, .folder: true
        case .timeline, .asset: false
        }
    }
}

private final class ProjectSourceAppKitOutlineView: NSOutlineView {
    weak var owner: ProjectSourceNativeOutline.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            owner?.openSelectedItem()
        case 51, 117:
            owner?.deleteSelectedItem()
        default:
            super.keyDown(with: event)
        }
    }

    @objc func paste(_ sender: Any?) {
        let values = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        let urls = values.compactMap { $0 as URL }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        owner?.pasteFiles(urls)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        guard selectedRow >= 0, let node = item(atRow: selectedRow) as? ProjectSourceNode else {
            return super.menu(for: event)
        }
        return owner?.menu(for: node.id)
    }
}

private final class ProjectSourceAssetButton: NSButton {
    private var assetID: UUID?
    private weak var owner: ProjectSourceNativeOutline.Coordinator?

    init() {
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        assetID: UUID,
        title: String,
        owner: ProjectSourceNativeOutline.Coordinator,
        accessibilityIdentifier: String
    ) {
        self.assetID = assetID
        self.title = title
        self.owner = owner
        setAccessibilityLabel(nil)
        setAccessibilityIdentifier(accessibilityIdentifier)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let assetID { owner?.selectAsset(assetID) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let assetID else { return super.menu(for: event) }
        owner?.selectAsset(assetID)
        return owner?.menu(for: .asset(assetID))
    }

    @objc private func pressed() {
        guard let assetID else { return }
        owner?.activateAsset(assetID)
    }
}

private final class ProjectSourceMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
