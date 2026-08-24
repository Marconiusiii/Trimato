import SwiftUI

struct ProjectBrowserView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    @State private var sourceSelection: ProjectSourceItemID?
    @State private var showingNewFolder = false
    @State private var folderName = ""
    @State private var folderBeingRenamed: ProjectFolder?
    @State private var renamedFolderName = ""

    init(
        controller: ProjectController,
        openClipEditor: @escaping (EditorSelection) -> Void
    ) {
        self.controller = controller
        self.openClipEditor = openClipEditor
        _sourceSelection = State(initialValue: .timeline(controller.project.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Import Clips\u{2026}") { controller.importFiles() }
                Button("New Folder") { showingNewFolder = true }
                sourceActions
                Spacer()
                if controller.isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Importing Clips")
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            ProjectSourceOutlineView(
                controller: controller,
                selection: $sourceSelection,
                openClipEditor: openClipEditor
            )
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
    private var sourceActions: some View {
        Menu("Actions") {
            switch sourceSelection {
            case .folder(let id):
                if let folder = controller.project.folders.first(where: { $0.id == id }) {
                    Button("Rename Folder\u{2026}") {
                        folderBeingRenamed = folder
                        renamedFolderName = folder.name
                    }
                    Button("Remove Folder") { controller.removeFolder(id) }
                }
            case .asset(let id):
                Menu("Move Clip") {
                    Button("Project Root") { controller.moveAsset(id, toFolder: nil) }
                    ForEach(controller.project.folders) { folder in
                        Button(folder.name) { controller.moveAsset(id, toFolder: folder.id) }
                    }
                }
            case .project, .timeline, .none:
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
}
