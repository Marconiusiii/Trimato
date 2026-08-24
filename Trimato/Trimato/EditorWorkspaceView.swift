import SwiftUI

struct EditorWorkspaceView: View {
    @StateObject private var controller: ProjectController
    @State private var showingProjectSetup: Bool
    @Namespace private var linkedNavigation

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
            ProjectBrowserView(controller: controller, linkedNamespace: linkedNavigation)
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VStack(spacing: 0) {
                activeEditor
                    .frame(minHeight: 360)

                Divider()

                HSplitView {
                    ProjectTimelineView(controller: controller, linkedNamespace: linkedNavigation)
                        .frame(minWidth: 460)
                    ClipInspectorView(controller: controller, linkedNamespace: linkedNavigation)
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
    }

    @ViewBuilder
    private var activeEditor: some View {
        switch controller.selection {
        case .project:
            ProjectViewerView(
                controller: controller,
                linkedNamespace: linkedNavigation,
                showProjectSettings: { showingProjectSetup = true }
            )
        case .asset(let id):
            if let asset = controller.project.asset(id: id) {
                SourceClipEditorView(
                    controller: controller,
                    asset: asset,
                    editSelection: .asset(id),
                    initialSegments: asset.sourceEdit,
                    linkedNamespace: linkedNavigation
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
                    initialSegments: clip.segments,
                    linkedNamespace: linkedNavigation
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
                    initialSegments: cutaway.segments,
                    linkedNamespace: linkedNavigation
                )
                .id("cutaway-\(id)")
            }
        }
    }
}

private struct ProjectViewerView: View {
    @ObservedObject var controller: ProjectController
    let linkedNamespace: Namespace.ID
    let showProjectSettings: () -> Void
    @StateObject private var viewModel = ProjectPlayerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Viewer and Project Editor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            ZStack {
                Color.black
                VideoPlayerView(player: viewModel.player)
                if let status = viewModel.status {
                    Text(status)
                        .foregroundStyle(.secondary)
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
        .accessibilityLinkedGroup(id: "browser-editor", in: linkedNamespace)
        .onAppear { prepare() }
        .onChange(of: controller.project) { _ in prepare() }
        .onChange(of: controller.timelinePlayhead) { time in
            guard abs(viewModel.currentTime.seconds - time.seconds) > 0.02 else { return }
            viewModel.seek(to: time)
        }
        .onChange(of: viewModel.currentTime) { time in
            if viewModel.isPlaying { controller.timelinePlayhead = time }
        }
    }

    private func prepare() {
        viewModel.prepare(project: controller.project, mediaURLs: controller.resolvedMediaURLs())
    }
}
