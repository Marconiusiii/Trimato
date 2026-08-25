import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var controller: ProjectController
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @StateObject private var projectWindowSaveCoordinator: ProjectWindowSaveCoordinator
    @State private var returnsToLauncherOnClose = false

    init(document: ProjectDocument) {
        let controller = ProjectController(document: document)
        _controller = StateObject(wrappedValue: controller)
        _clipEditorWindows = StateObject(wrappedValue: ClipEditorWindowCoordinator(controller: controller))
        _projectWindowSaveCoordinator = StateObject(
            wrappedValue: ProjectWindowSaveCoordinator(projectDocument: document)
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
                    ProjectViewerView(controller: controller)
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
        .background(ProjectWindowSaveBridge(saveCoordinator: projectWindowSaveCoordinator))
        .preferredColorScheme(.dark)
        .focusedObject(controller)
        .handlesTrimatoMediaOpening()
        .onAppear {
            controller.installSaveCoordinator(projectWindowSaveCoordinator)
            ExternalMediaOpenCoordinator.shared.register(
                controller: controller,
                openClipEditor: { [weak clipEditorWindows] selection in
                    clipEditorWindows?.open(selection)
                }
            )
            ExternalMediaOpenCoordinator.shared.activate(controller: controller)
            projectWindowSaveCoordinator.onWindowBecameKey { [weak controller] in
                guard let controller else { return }
                ExternalMediaOpenCoordinator.shared.activate(controller: controller)
            }
            controller.installCloseProjectAction { [weak clipEditorWindows, weak projectWindowSaveCoordinator] in
                clipEditorWindows?.requestCloseAll { didClose in
                    guard didClose else { return }
                    projectWindowSaveCoordinator?.requestClose { shouldClose in
                        if shouldClose { returnsToLauncherOnClose = true }
                    }
                }
            }
            NotificationCenter.default.post(name: .trimatoProjectDidOpen, object: nil)
        }
        .onDisappear {
            ExternalMediaOpenCoordinator.shared.unregister(controller: controller)
            if returnsToLauncherOnClose {
                openWindow(id: "project-launcher")
            }
        }
        .sheet(isPresented: $controller.isShowingProjectSettings) {
            ProjectCreationView(controller: controller) {
                controller.isShowingProjectSettings = false
            }
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
    @StateObject private var viewModel = ProjectPlayerViewModel()
    @StateObject private var focusScope = EditorAccessibilityFocusScope()

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            controlsArea
        }
        .background(EditorAccessibilityFocusBridge(scope: focusScope))
        .focusedObject(viewModel)
        .onAppear {
            controller.installProjectPlayer(viewModel)
            viewModel.scopeKeyboardCommands { [weak focusScope] in
                focusScope?.containsAccessibilityFocus == true
            }
            viewModel.onPointNavigation { [weak controller] time in
                controller?.selectTimelineEntry(at: time)
            }
            prepare()
        }
        .onChange(of: controller.project) { _ in prepare() }
        .onChange(of: controller.timelinePlayhead) { time in
            guard abs(viewModel.currentTime.seconds - time.seconds) > 0.02 else { return }
            viewModel.seek(to: time)
        }
        .onChange(of: viewModel.currentTime) { time in
            controller.timelinePlayhead = time
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

    private var videoArea: some View {
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
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorTheme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private var controlsArea: some View {
        VStack(spacing: 10) {
            if viewModel.duration > .zero {
                Slider(
                    value: Binding(
                        get: { viewModel.playbackFraction },
                        set: { viewModel.seek(toFraction: $0) }
                    ),
                    in: 0...1
                )
                .accessibilityHidden(true)
            }

            Button { viewModel.toggleTimecodeDisplay() } label: {
                VStack(spacing: 2) {
                    Text(viewModel.showingFrames
                         ? String(format: "%06d", viewModel.currentFrame)
                         : viewModel.displayTimecode)
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(EditorTheme.accent)
                    Text(viewModel.showingFrames ? "FRAMES" : "TIMECODE")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canControlPlayback)
            .accessibilityLabel(viewModel.accessibilityTimecodeLabel)
            .accessibilityHint(viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")

            VStack(alignment: .leading, spacing: 8) {
                Text("Selection")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                HStack {
                    Button("Mark In") { viewModel.markIn() }
                    Text("In: \(viewModel.inMarkerDisplay)")
                        .monospacedDigit()
                    Button("Clear In") { viewModel.clearIn() }
                        .disabled(viewModel.inMarker == nil)
                }
                HStack {
                    Button("Mark Out") { viewModel.markOut() }
                    Text("Out: \(viewModel.outMarkerDisplay)")
                        .monospacedDigit()
                    Button("Clear Out") { viewModel.clearOut() }
                        .disabled(viewModel.outMarker == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!viewModel.canControlPlayback)

            HStack {
                Button("Start") { viewModel.goToStart() }
                Button("Previous Point") { viewModel.goToPreviousEdit() }
                Button("Next Point") { viewModel.goToNextEdit() }
                Button("End") { viewModel.goToEnd() }
            }
            .disabled(!viewModel.canControlPlayback)

            if viewModel.isPlaying, viewModel.playbackRate != 1 {
                Text(viewModel.playbackRate < 0
                     ? "\(Int(abs(viewModel.playbackRate))) times backward"
                     : "\(Int(viewModel.playbackRate)) times forward")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(EditorTheme.raisedSurface, in: Capsule())
                    .accessibilityHidden(true)
            }

            HStack(spacing: 20) {
                Button { viewModel.stepBackward() } label: {
                    Image(systemName: "backward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step backward one frame")

                Button { viewModel.seekBackward() } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back 10 seconds")

                Button { viewModel.togglePlayback() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Button { viewModel.seekForward() } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward 10 seconds")

                Button { viewModel.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step forward one frame")
            }
            .foregroundStyle(EditorTheme.accent)
            .disabled(!viewModel.canControlPlayback)

            if controller.isExporting {
                if let progress = controller.exportProgress {
                    ProgressView(value: progress) { Text("Exporting Project") }
                        .accessibilityHidden(true)
                } else {
                    ProgressView("Exporting Project")
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }
}
