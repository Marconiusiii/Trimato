import SwiftUI

struct ProjectBrowserView: View {
    @ObservedObject var controller: ProjectController
    let linkedNamespace: Namespace.ID
    @State private var showingNewFolder = false
    @State private var folderName = ""
    @State private var folderBeingRenamed: ProjectFolder?
    @State private var renamedFolderName = ""

    private var filedAssetIDs: Set<UUID> {
        Set(controller.project.folders.flatMap(\.assetIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Browser")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            List {
                Section("Project") {
                    Button(controller.project.name) { controller.selection = .project }
                }

                Section("Media") {
                    ForEach(controller.project.media.filter { !filedAssetIDs.contains($0.id) }) { asset in
                        assetButton(asset)
                    }
                }

                ForEach(controller.project.folders) { folder in
                    Section {
                        ForEach(folder.assetIDs.compactMap { controller.project.asset(id: $0) }) { asset in
                            assetButton(asset)
                        }
                    } header: {
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Menu("Folder Actions") {
                                Button("Rename Folder\u{2026}") {
                                    folderBeingRenamed = folder
                                    renamedFolderName = folder.name
                                }
                                Button("Remove Folder") { controller.removeFolder(folder.id) }
                            }
                        }
                    }
                }
            }
            .accessibilityLinkedGroup(id: "browser-editor", in: linkedNamespace)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                controller.importFiles(at: files)
                return true
            }

            HStack {
                Button("Import Media\u{2026}") { controller.importFiles() }
                Button("New Folder") { showingNewFolder = true }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Project Folder")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                TextField("Folder Name", text: $folderName)
                HStack {
                    Button("Cancel", role: .cancel) { showingNewFolder = false }
                    Button("Create") {
                        controller.createFolder(named: folderName)
                        folderName = ""
                        showingNewFolder = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(item: $folderBeingRenamed) { folder in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Project Folder")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                TextField("Folder Name", text: $renamedFolderName)
                HStack {
                    Button("Cancel", role: .cancel) { folderBeingRenamed = nil }
                    Button("Rename") {
                        controller.renameFolder(folder.id, to: renamedFolderName)
                        folderBeingRenamed = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    private func assetButton(_ asset: MediaAssetRecord) -> some View {
        HStack {
            Button(asset.name) { controller.selection = .asset(asset.id) }
                .accessibilityValue(ProjectImportCoordinator.resolveURL(for: asset) == nil ? "Offline" : "Ready")
            Spacer()
            Menu("Move Media") {
                Button("Unfiled Media") { controller.moveAsset(asset.id, toFolder: nil) }
                ForEach(controller.project.folders) { folder in
                    Button(folder.name) { controller.moveAsset(asset.id, toFolder: folder.id) }
                }
            }
        }
    }
}
