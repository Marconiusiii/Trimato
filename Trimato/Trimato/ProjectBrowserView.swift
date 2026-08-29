import SwiftUI

nonisolated enum ProjectSourceDeletionConfirmation {
    static let title = "Delete Source Clip?"

    static func message(clipName: String, timelineUseCount: Int) -> String {
        if timelineUseCount == 0 {
            return "Remove \(clipName) from Project Source? This can be undone."
        }
        let uses = timelineUseCount == 1 ? "1 timeline clip" : "\(timelineUseCount) timeline clips"
        return "\(clipName) is used by \(uses). Deleting it from Project Source will also remove those timeline clips and their transitions. This can be undone."
    }
}

nonisolated enum ProjectSourceDeletionFocus {
    static func target(
        afterDeleting assetID: UUID,
        from assets: [MediaAssetRecord],
        projectID: UUID
    ) -> ProjectSourceItemID {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else {
            return .clips(projectID)
        }
        if assets.indices.contains(index + 1) { return .asset(assets[index + 1].id) }
        if index > assets.startIndex { return .asset(assets[index - 1].id) }
        return .clips(projectID)
    }
}

nonisolated struct ProjectSourceFocusRequest: Equatable, Sendable {
    var target: ProjectSourceItemID?
    var revision = 0
}

struct ProjectBrowserView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID
    @State private var sourceSelection: ProjectSourceItemID?
    @State private var showingNewFolder = false
    @State private var folderName = ""
    @State private var folderBeingRenamed: ProjectFolder?
    @State private var renamedFolderName = ""
    @State private var assetPendingDeletion: MediaAssetRecord?
    @State private var sourceFocusRequest = ProjectSourceFocusRequest()
    @State private var newTrackRequest: NewTrackFromSourceRequest?
    @State private var newTrackSourceFocusTarget: ProjectSourceItemID?
    @State private var newTrackTimelineFocusTarget: TimelineElementSelection?

    init(
        controller: ProjectController,
        openClipEditor: @escaping (EditorSelection) -> Void,
        workspacePaneLinks: Namespace.ID
    ) {
        self.controller = controller
        self.openClipEditor = openClipEditor
        self.workspacePaneLinks = workspacePaneLinks
        _sourceSelection = State(initialValue: .timeline(controller.project.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Project")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(EditorTheme.controlSurface)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sourceImportControls
                    Spacer()
                    importProgress
                }
                VStack(alignment: .leading, spacing: 8) {
                    sourceImportControls
                    importProgress
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            ProjectSourceOutlineView(
                controller: controller,
                selection: $sourceSelection,
                openClipEditor: openClipEditor,
                requestNewFolder: { showingNewFolder = true },
                requestRenameFolder: beginRenamingFolder,
                requestDeleteAsset: beginDeletingAsset,
                requestNewTrack: beginNewTrackFromSource,
                focusRequest: sourceFocusRequest
            )

            Divider()

            HStack {
                sourceActions
                    .disabled(!hasSourceActions)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
        .sheet(isPresented: $showingNewFolder) {
            folderEditor(
                title: "New Project Folder",
                fieldValue: $folderName,
                actionTitle: "Create"
            ) {
                controller.createFolder(named: folderName)
                folderName = ""
                showingNewFolder = false
            } cancel: {
                showingNewFolder = false
            }
        }
        .sheet(item: $folderBeingRenamed) { folder in
            folderEditor(
                title: "Rename Project Folder",
                fieldValue: $renamedFolderName,
                actionTitle: "Rename"
            ) {
                controller.renameFolder(folder.id, to: renamedFolderName)
                folderBeingRenamed = nil
            } cancel: {
                folderBeingRenamed = nil
            }
        }
        .sheet(item: $newTrackRequest, onDismiss: newTrackSheetDismissed) { request in
            if let asset = controller.project.asset(id: request.assetID) {
                NewTrackFromSourceView(
                    kind: request.kind,
                    suggestedTrackName: request.kind.suggestedTrackName(
                        sourceName: asset.name,
                        sourceHasVideo: asset.hasVideo
                    ),
                    presentedError: $controller.presentedError,
                    create: { name in
                        createNewTrackFromSource(request, asset: asset, name: name)
                    },
                    close: { newTrackRequest = nil }
                )
            }
        }
        .alert(ProjectSourceDeletionConfirmation.title, isPresented: deleteAssetConfirmationPresented) {
            Button("Cancel", role: .cancel) { cancelAssetDeletion() }
            Button("Delete Source Clip", role: .destructive) { confirmAssetDeletion() }
        } message: {
            Text(deleteAssetConfirmationMessage)
        }
    }

    @ViewBuilder
    private var sourceImportControls: some View {
        Button("Import Clips\u{2026}") { controller.importFiles() }
        Button("New Folder") { showingNewFolder = true }
    }

    @ViewBuilder
    private var importProgress: some View {
        if controller.isImporting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Importing Clips")
        }
    }

    private var hasSourceActions: Bool {
        switch sourceSelection {
        case .asset: true
        case .folder(let id): controller.project.folders.contains { $0.id == id }
        case .project, .timeline, .clips, .none: false
        }
    }

    @ViewBuilder
    private var sourceActions: some View {
        Menu("Actions") {
            switch sourceSelection {
            case .folder(let id):
                if controller.project.folders.contains(where: { $0.id == id }) {
                    Button("Import Clips into Folder\u{2026}") { controller.importFiles(into: id) }
                    Button("Rename Folder\u{2026}") {
                        beginRenamingFolder(id)
                    }
                    Button("Remove Folder") { controller.removeFolder(id) }
                }
            case .asset(let id):
                Button("Open Clip Editor") { openClipEditor(.asset(id)) }
                Divider()
                ForEach(PlacementAction.allCases) { placement in
                    Button(placement.title) {
                        guard let asset = controller.project.asset(id: id) else { return }
                        controller.place(placement, editing: .asset(id), segments: asset.sourceEdit)
                    }
                }
                if let asset = controller.project.asset(id: id) {
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
                            beginNewTrackFromSource(id, kind)
                        }
                    }
                }
                Divider()
                Menu("Move Clip") {
                    Button("Project Root") { controller.moveAsset(id, toFolder: nil) }
                    ForEach(controller.project.folders) { folder in
                        Button(folder.name) { controller.moveAsset(id, toFolder: folder.id) }
                    }
                }
                if let asset = controller.project.asset(id: id), controller.resolveURL(for: asset) == nil {
                    Button("Relink Clip\u{2026}") {
                        controller.selection = .asset(id)
                        controller.relinkSelectedAsset()
                    }
                }
                Divider()
                Button("Delete Source Clip", role: .destructive) {
                    beginDeletingAsset(id)
                }
            case .project, .timeline, .clips, .none:
                Text("No Actions Available")
            }
        }
    }

    private func beginDeletingAsset(_ assetID: UUID) {
        guard let asset = controller.project.asset(id: assetID) else { return }
        sourceSelection = .asset(assetID)
        controller.selection = .asset(assetID)
        assetPendingDeletion = asset
    }

    private var deleteAssetConfirmationPresented: Binding<Bool> {
        Binding(
            get: { assetPendingDeletion != nil },
            set: { presented in
                if !presented, assetPendingDeletion != nil { cancelAssetDeletion() }
            }
        )
    }

    private var deleteAssetConfirmationMessage: String {
        guard let asset = assetPendingDeletion else { return "Remove this clip from Project Source?" }
        return ProjectSourceDeletionConfirmation.message(
            clipName: asset.name,
            timelineUseCount: controller.project.sourceAssetTimelineUseCount(asset.id)
        )
    }

    private func cancelAssetDeletion() {
        guard let asset = assetPendingDeletion else { return }
        assetPendingDeletion = nil
        requestSourceFocus(.asset(asset.id))
    }

    private func confirmAssetDeletion() {
        guard let asset = assetPendingDeletion else { return }
        let target = ProjectSourceDeletionFocus.target(
            afterDeleting: asset.id,
            from: controller.project.media,
            projectID: controller.project.id
        )
        assetPendingDeletion = nil
        sourceSelection = target
        controller.deleteSourceAsset(asset.id)
        requestSourceFocus(target)
    }

    private func requestSourceFocus(_ target: ProjectSourceItemID) {
        sourceFocusRequest.target = target
        sourceFocusRequest.revision += 1
    }

    private func beginNewTrackFromSource(_ assetID: UUID, _ kind: NewTrackSourceKind) {
        guard controller.project.asset(id: assetID) != nil else { return }
        let sourceTarget = ProjectSourceItemID.asset(assetID)
        sourceSelection = sourceTarget
        controller.selection = .asset(assetID)
        newTrackSourceFocusTarget = sourceTarget
        newTrackTimelineFocusTarget = nil
        newTrackRequest = NewTrackFromSourceRequest(assetID: assetID, kind: kind)
    }

    private func createNewTrackFromSource(
        _ request: NewTrackFromSourceRequest,
        asset: MediaAssetRecord,
        name: String
    ) -> Bool {
        do {
            let result = try controller.createTrackAndPlaceThrowing(
                .append,
                editing: .asset(request.assetID),
                segments: asset.sourceEdit,
                trackKind: request.kind.trackKind,
                trackName: name,
                audioSettings: nil
            )
            newTrackTimelineFocusTarget = .clip(result.clipID)
            return true
        } catch {
            controller.presentedError = ProjectPresentedError(
                title: "Track Could Not Be Created",
                message: error.localizedDescription
            )
            return false
        }
    }

    private func newTrackSheetDismissed() {
        if let target = newTrackTimelineFocusTarget {
            controller.requestTimelineFocusRestore(to: target)
        } else if let target = newTrackSourceFocusTarget {
            requestSourceFocus(target)
        }
        newTrackTimelineFocusTarget = nil
        newTrackSourceFocusTarget = nil
    }

    private func folderEditor(
        title: String,
        fieldValue: Binding<String>,
        actionTitle: String,
        action: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            LabeledContent("Folder Name") {
                TextField("Folder Name", text: fieldValue)
                    .labelsHidden()
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func beginRenamingFolder(_ id: UUID) {
        guard let folder = controller.project.folders.first(where: { $0.id == id }) else { return }
        folderBeingRenamed = folder
        renamedFolderName = folder.name
    }

    private var trackPlacementActions: [PlacementAction] {
        [.append, .insert, .replaceRemainder]
    }

    private func compatibleTracks(for asset: MediaAssetRecord) -> [TimelineTrack] {
        controller.project.tracks.filter { track in
            (track.kind == .video && asset.hasVideo) || (track.kind == .audio && asset.hasAudio)
        }
    }

    private func place(_ asset: MediaAssetRecord, action: PlacementAction, on track: TimelineTrack) {
        guard let clipID = controller.place(
            action,
            editing: .asset(asset.id),
            segments: asset.sourceEdit,
            onTrack: track.id
        ) else { return }
        controller.requestTimelineFocusRestore(to: .clip(clipID))
    }
}
