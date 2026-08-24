import SwiftUI

struct EditorWorkspaceView: View {
    @StateObject private var controller: ProjectController
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @State private var showingProjectSetup: Bool

    init(document: ProjectDocument) {
        let controller = ProjectController(document: document)
        _controller = StateObject(wrappedValue: controller)
        _clipEditorWindows = StateObject(wrappedValue: ClipEditorWindowCoordinator(controller: controller))
        _showingProjectSetup = State(initialValue:
            document.project.name == "Untitled Project" &&
            document.project.media.isEmpty &&
            document.project.primaryTimeline.isEmpty
        )
    }

    var body: some View {
        HSplitView {
            MacEditorPane("Project Source") {
                ProjectBrowserView(
                    controller: controller,
                    openClipEditor: clipEditorWindows.open
                )
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(
                        controller: controller,
                        showProjectSettings: { showingProjectSetup = true }
                    )
                }
                .frame(minHeight: 360)

                HSplitView {
                    MacEditorPane("Project Timeline") {
                        ProjectTimelineView(
                            controller: controller,
                            openClipEditor: clipEditorWindows.open
                        )
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
