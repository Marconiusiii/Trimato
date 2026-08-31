import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

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

    @State private var expandedItems: Set<ProjectSourceItemID>
    @State private var pastedImportBaselineAssetIDs: Set<UUID>?
    @State private var pendingPastedAssetFocusID: UUID?
    @State private var handledFocusRequestRevision = 0
    @State private var focusTask: Task<Void, Never>?
    @FocusState private var keyboardFocusedItem: ProjectSourceItemID?
    @AccessibilityFocusState private var focusedItem: ProjectSourceItemID?

    init(
        controller: ProjectController,
        selection: Binding<ProjectSourceItemID?>,
        openClipEditor: @escaping (EditorSelection) -> Void,
        requestNewFolder: @escaping () -> Void,
        requestRenameFolder: @escaping (UUID) -> Void,
        requestDeleteAsset: @escaping (UUID) -> Void,
        requestNewTrack: @escaping (UUID, NewTrackSourceKind) -> Void,
        focusRequest: ProjectSourceFocusRequest
    ) {
        self.controller = controller
        _selection = selection
        self.openClipEditor = openClipEditor
        self.requestNewFolder = requestNewFolder
        self.requestRenameFolder = requestRenameFolder
        self.requestDeleteAsset = requestDeleteAsset
        self.requestNewTrack = requestNewTrack
        self.focusRequest = focusRequest
        _expandedItems = State(initialValue: Set(
            [.project(controller.project.id), .clips(controller.project.id), .generators(controller.project.id)] +
                controller.project.folders.map { .folder($0.id) }
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                projectHierarchy
            }
            .accessibilityLabel("Project Source")
            .onChange(of: selection) { _, selectedItem in
                synchronizeControllerSelection(selectedItem)
            }
            .onChange(of: controller.project.media.map(\.id)) {
                capturePastedAssetFocusIfAvailable()
            }
            .onChange(of: controller.isImporting) {
                capturePastedAssetFocusIfAvailable()
                restorePastedAssetFocusIfReady(using: proxy)
            }
            .onChange(of: controller.project.folders.map(\.id)) { _, folderIDs in
                expandedItems.formUnion(folderIDs.map { .folder($0) })
            }
            .onChange(of: focusRequest) { _, request in
                handleFocusRequest(request, using: proxy)
            }
            .onPasteCommand(of: [.fileURL]) { providers in
                pasteFiles(from: providers)
            }
            .onDeleteCommand {
                deleteSelectedAsset()
            }
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls, into: selectedDestinationFolderID())
            }
            .onDisappear {
                focusTask?.cancel()
            }
        }
    }

    private var projectHierarchy: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: .project(controller.project.id))
        ) {
            projectTimelineRow
            clipsGroup
            ForEach(controller.project.folders) { folder in
                folderGroup(folder)
            }
            if !generatorAssets.isEmpty { generatorsGroup }
        } label: {
            Text(controller.project.name)
        }
        .tag(ProjectSourceItemID.project(controller.project.id))
        .id(ProjectSourceItemID.project(controller.project.id))
        .accessibilityFocused($focusedItem, equals: .project(controller.project.id))
        .contextMenu {
            Button("Import Clips\u{2026}") { controller.importFiles() }
            Button("New Folder") { requestNewFolder() }
        }
    }

    private var projectTimelineRow: some View {
        Text("Project Timeline")
            .tag(ProjectSourceItemID.timeline(controller.project.id))
            .id(ProjectSourceItemID.timeline(controller.project.id))
            .accessibilityFocused($focusedItem, equals: .timeline(controller.project.id))
    }

    private var clipsGroup: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: .clips(controller.project.id))
        ) {
            ForEach(unfiledAssets) { asset in
                assetRow(asset)
            }
        } label: {
            Text("Clips")
        }
        .tag(ProjectSourceItemID.clips(controller.project.id))
        .id(ProjectSourceItemID.clips(controller.project.id))
        .accessibilityFocused($focusedItem, equals: .clips(controller.project.id))
    }

    private var generatorAssets: [MediaAssetRecord] {
        controller.project.media.filter { $0.generator != nil }
    }

    private var generatorsGroup: some View {
        DisclosureGroup(isExpanded: expansionBinding(for: .generators(controller.project.id))) {
            ForEach(generatorAssets) { asset in assetRow(asset) }
        } label: {
            Text("Generators")
        }
        .tag(ProjectSourceItemID.generators(controller.project.id))
        .id(ProjectSourceItemID.generators(controller.project.id))
        .accessibilityFocused($focusedItem, equals: .generators(controller.project.id))
    }

    private func folderGroup(_ folder: ProjectFolder) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: .folder(folder.id))
        ) {
            ForEach(folder.assetIDs.compactMap(controller.project.asset(id:)).filter { $0.generator == nil }) { asset in
                assetRow(asset)
            }
        } label: {
            Text(folder.name)
        }
        .tag(ProjectSourceItemID.folder(folder.id))
        .id(ProjectSourceItemID.folder(folder.id))
        .accessibilityFocused($focusedItem, equals: .folder(folder.id))
        .contextMenu {
            Button("Import Clips into Folder\u{2026}") {
                controller.importFiles(into: folder.id)
            }
            Button("Rename Folder\u{2026}") {
                select(.folder(folder.id))
                requestRenameFolder(folder.id)
            }
            Divider()
            Button("Remove Folder", role: .destructive) {
                select(.folder(folder.id))
                controller.removeFolder(folder.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls, into: folder.id)
        }
    }

    private func assetRow(_ asset: MediaAssetRecord) -> some View {
        Button(asset.name) {
            select(.asset(asset.id))
            openClipEditor(.asset(asset.id))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(ProjectSourceItemID.asset(asset.id))
        .id(ProjectSourceItemID.asset(asset.id))
        .focused($keyboardFocusedItem, equals: .asset(asset.id))
        .accessibilityFocused($focusedItem, equals: .asset(asset.id))
        .contextMenu {
            assetContextMenu(asset)
        }
    }

    @ViewBuilder
    private func assetContextMenu(_ asset: MediaAssetRecord) -> some View {
        Button("Open Clip Editor") {
            select(.asset(asset.id))
            openClipEditor(.asset(asset.id))
        }
        Divider()
        ForEach(PlacementAction.allCases) { placement in
            Button(placement.title) {
                select(.asset(asset.id))
                controller.place(
                    placement,
                    editing: .asset(asset.id),
                    segments: asset.sourceEdit
                )
            }
        }
        Divider()
        ForEach(trackPlacementActions) { placement in
            Menu("\(placement.title) to Track") {
                ForEach(compatibleTracks(for: asset)) { track in
                    Button(track.name) {
                        place(asset, action: placement, on: track)
                    }
                }
            }
            .disabled(compatibleTracks(for: asset).isEmpty)
        }
        Divider()
        ForEach(NewTrackSourceKind.availableKinds(
            hasVideo: asset.hasVideo,
            hasAudio: asset.hasAudio
        )) { kind in
            Button(kind.commandTitle) {
                select(.asset(asset.id))
                requestNewTrack(asset.id, kind)
            }
        }
        Divider()
        if asset.generator == nil {
            Menu("Move to Folder") {
                Button("Project Root") {
                    select(.asset(asset.id))
                    controller.moveAsset(asset.id, toFolder: nil)
                }
                ForEach(controller.project.folders) { folder in
                    Button(folder.name) {
                        select(.asset(asset.id))
                        controller.moveAsset(asset.id, toFolder: folder.id)
                    }
                }
            }
        }
        if asset.generator == nil, controller.resolveURL(for: asset) == nil {
            Button("Relink Clip\u{2026}") {
                select(.asset(asset.id))
                controller.relinkSelectedAsset()
            }
        }
        Divider()
        Button("Delete Source Clip", role: .destructive) {
            select(.asset(asset.id))
            requestDeleteAsset(asset.id)
        }
    }

    private var unfiledAssets: [MediaAssetRecord] {
        let filedIDs = Set(controller.project.folders.flatMap(\.assetIDs))
        return ProjectSourceItem.importedAssets(in: controller.project).filter { !filedIDs.contains($0.id) }
    }

    private var trackPlacementActions: [PlacementAction] {
        [.append, .insert, .replaceRemainder]
    }

    private func compatibleTracks(for asset: MediaAssetRecord) -> [TimelineTrack] {
        controller.project.orderedTimelineTracks.filter { track in
            (track.kind == .video && asset.hasVideo) ||
                (track.kind == .audio && asset.hasAudio)
        }
    }

    private func place(_ asset: MediaAssetRecord, action: PlacementAction, on track: TimelineTrack) {
        select(.asset(asset.id))
        guard let clipID = controller.place(
            action,
            editing: .asset(asset.id),
            segments: asset.sourceEdit,
            onTrack: track.id
        ) else { return }
        controller.requestTimelineFocusRestore(to: .clip(clipID))
    }

    private func expansionBinding(for item: ProjectSourceItemID) -> Binding<Bool> {
        Binding(
            get: { expandedItems.contains(item) },
            set: { isExpanded in
                if isExpanded {
                    expandedItems.insert(item)
                } else {
                    expandedItems.remove(item)
                }
            }
        )
    }

    private func select(_ item: ProjectSourceItemID) {
        selection = item
        synchronizeControllerSelection(item)
    }

    private func synchronizeControllerSelection(_ item: ProjectSourceItemID?) {
        switch item {
        case .asset(let id):
            controller.selection = .asset(id)
            controller.setProjectInfoTarget(.selection(.asset(id)))
        case .project, .timeline, .clips:
            controller.selection = .project
            controller.setProjectInfoTarget(.selection(.project))
        case .folder(let id):
            controller.setProjectInfoTarget(.folder(id))
        case .generators, .none:
            break
        }
    }

    private func deleteSelectedAsset() {
        guard case .asset(let assetID) = selection else { return }
        requestDeleteAsset(assetID)
    }

    private func selectedDestinationFolderID() -> UUID? {
        guard case .folder(let folderID) = selection else { return nil }
        return folderID
    }

    private func pasteFiles(from providers: [NSItemProvider]) {
        guard !controller.isImporting else { return }
        let destinationFolderID = selectedDestinationFolderID()
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await fileURL(from: provider),
                   url.isFileURL,
                   !urls.contains(url) {
                    urls.append(url)
                }
            }
            importFiles(urls, into: destinationFolderID)
        }
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: URL.self) { result in
                continuation.resume(returning: try? result.get())
            }
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
            let target = ProjectSourceItemID.asset(assetID)
            prepareExpansion(for: target)
            select(target)
        } else if !controller.isImporting {
            self.pastedImportBaselineAssetIDs = nil
        }
    }

    private func restorePastedAssetFocusIfReady(using proxy: ScrollViewProxy) {
        guard ProjectSourcePasteFocus.shouldRestoreFocus(
            pendingAssetID: pendingPastedAssetFocusID,
            importIsRunning: controller.isImporting
        ), let assetID = pendingPastedAssetFocusID else { return }
        pendingPastedAssetFocusID = nil
        requestFocus(.asset(assetID), using: proxy)
    }

    private func handleFocusRequest(_ request: ProjectSourceFocusRequest, using proxy: ScrollViewProxy) {
        guard request.revision > handledFocusRequestRevision,
              let target = request.target else { return }
        handledFocusRequestRevision = request.revision
        requestFocus(target, using: proxy)
    }

    private func requestFocus(_ target: ProjectSourceItemID, using proxy: ScrollViewProxy) {
        prepareExpansion(for: target)
        select(target)
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(target, anchor: .center)
            if NSWorkspace.shared.isVoiceOverEnabled {
                if focusedItem != target { focusedItem = target }
            } else {
                keyboardFocusedItem = target
            }
        }
    }

    private func prepareExpansion(for target: ProjectSourceItemID) {
        expandedItems.insert(.project(controller.project.id))
        guard case .asset(let assetID) = target else { return }
        if controller.project.asset(id: assetID)?.generator != nil {
            expandedItems.insert(.generators(controller.project.id))
        } else if let folder = controller.project.folders.first(where: { $0.assetIDs.contains(assetID) }) {
            expandedItems.insert(.folder(folder.id))
        } else {
            expandedItems.insert(.clips(controller.project.id))
        }
    }
}
