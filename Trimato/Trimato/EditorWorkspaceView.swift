import SwiftUI

struct EditorWorkspaceView: View {
    @StateObject private var controller: ProjectController
    @State private var showingProjectSetup: Bool

    init(document: ProjectDocument) {
        _controller = StateObject(wrappedValue: ProjectController(document: document))
        _showingProjectSetup = State(initialValue:
            document.project.name == "Untitled Project" &&
            document.project.media.isEmpty &&
            document.project.primaryTimeline.isEmpty
        )
    }

    var body: some View {
        HSplitView {
            MacEditorPane("Project Source") {
                ProjectBrowserView(controller: controller)
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VSplitView {
                MacEditorPane("Editor") {
                    activeEditor
                }
                .frame(minHeight: 360)

                HSplitView {
                    MacEditorPane("Project Timeline") {
                        ProjectTimelineView(controller: controller)
                    }
                        .frame(minWidth: 460)
                    MacEditorPane("Inspector") {
                        ClipInspectorView(controller: controller)
                    }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }
                .frame(minHeight: 240)
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
        .background(EditorTheme.workspace)
        .preferredColorScheme(.dark)
        .focusedObject(controller)
        .sheet(isPresented: $showingProjectSetup) {
            ProjectCreationView(controller: controller) { showingProjectSetup = false }
        }
        .alert(item: $controller.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var activeEditor: some View {
        switch controller.selection {
        case .project:
            ProjectViewerView(
                controller: controller,
                showProjectSettings: { showingProjectSetup = true }
            )
        case .asset(let id):
            if let asset = controller.project.asset(id: id) {
                SourceClipEditorView(
                    controller: controller,
                    asset: asset,
                    editSelection: .asset(id),
                    initialSegments: asset.sourceEdit
                )
                .id("asset-\(id)")
            }
        case .timelineClip(let id):
            if let clip = controller.project.primaryTimeline.first(where: { $0.id == id }),
               let asset = controller.project.asset(id: clip.assetID) {
                SourceClipEditorView(
                    controller: controller,
                    asset: asset,
                    editSelection: .timelineClip(id),
                    initialSegments: clip.segments
                )
                .id("timeline-\(id)")
            }
        case .cutaway(let id):
            if let cutaway = controller.project.cutaways.first(where: { $0.id == id }),
               let asset = controller.project.asset(id: cutaway.assetID) {
                SourceClipEditorView(
                    controller: controller,
                    asset: asset,
                    editSelection: .cutaway(id),
                    initialSegments: cutaway.segments
                )
                .id("cutaway-\(id)")
            }
        }
    }
}

private struct ProjectViewerView: View {
    @ObservedObject var controller: ProjectController
    let showProjectSettings: () -> Void
    @StateObject private var viewModel = ProjectPlayerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                VideoPlayerView(player: viewModel.player)
                if controller.project.primaryTimeline.isEmpty {
                    Text("Add a clip to the project timeline")
                        .foregroundStyle(.secondary)
                } else if viewModel.isPreparing {
                    ProgressView("Preparing Project Preview")
                        .padding()
                }
            }

            HStack {
                Button(viewModel.isPlaying ? "Pause" : "Play") { viewModel.togglePlayback() }
                    .disabled(controller.project.primaryTimeline.isEmpty || viewModel.isPreparing)
                Text(ProjectTimecodeFormatter.string(viewModel.currentTime))
                    .monospacedDigit()
                Spacer()
                Button("Project Settings\u{2026}", action: showProjectSettings)
                Button("Export Project\u{2026}") { controller.exportProject() }
                    .disabled(controller.project.primaryTimeline.isEmpty || controller.isExporting)
                if controller.isExporting {
                    if let progress = controller.exportProgress {
                        ProgressView(value: progress) { Text("Exporting Project") }
                    } else {
                        ProgressView("Exporting Project")
                    }
                    Button("Cancel Export") { controller.cancelExport() }
                }
            }
            .padding(10)
        }
        .onAppear { prepare() }
        .onChange(of: controller.project) { _ in prepare() }
        .onChange(of: controller.timelinePlayhead) { time in
            guard abs(viewModel.currentTime.seconds - time.seconds) > 0.02 else { return }
            viewModel.seek(to: time)
        }
        .onChange(of: viewModel.currentTime) { time in
            if viewModel.isPlaying { controller.timelinePlayhead = time }
        }
        .alert("Project Preview Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { presented in if !presented { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "The project preview could not be prepared.")
        }
    }

    private func prepare() {
        viewModel.prepare(project: controller.project, mediaURLs: controller.resolvedMediaURLs())
    }
}
