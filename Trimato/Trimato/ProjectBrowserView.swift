import SwiftUI

struct ProjectBrowserView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID
    @State private var sourceSelection: ProjectSourceItemID?
    @State private var showingNewFolder = false
    @State private var folderName = ""
    @State private var folderBeingRenamed: ProjectFolder?
    @State private var renamedFolderName = ""

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
                requestRenameFolder: beginRenamingFolder
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
            case .project, .timeline, .clips, .none:
                Text("No Actions Available")
            }
        }
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
            TextField("Folder Name", text: fieldValue)
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
}
