import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var controller: ProjectController
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @StateObject private var projectWindowSaveCoordinator: ProjectWindowSaveCoordinator
    @State private var hasRequestedInitialEditorFocus = false
    @Namespace private var workspacePaneLinks

    init(document: ProjectDocument) {
        let controller = ProjectController(document: document)
        _controller = StateObject(wrappedValue: controller)
        _clipEditorWindows = StateObject(wrappedValue: ClipEditorWindowCoordinator(controller: controller))
        _projectWindowSaveCoordinator = StateObject(
            wrappedValue: ProjectWindowSaveCoordinator(projectDocument: document)
        )
    }

    var body: some View {
        editor
            .background(EditorTheme.workspace)
            .background(ProjectWindowSaveBridge(saveCoordinator: projectWindowSaveCoordinator))
            .preferredColorScheme(.dark)
            .focusedSceneObject(controller)
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
                    if !controller.isShowingProjectSettings, !hasRequestedInitialEditorFocus {
                        requestEditorFocus()
                    }
                }
                projectWindowSaveCoordinator.onLastProjectWindowWillClose {
                    openWindow(id: "project-launcher")
                }
                controller.installCloseProjectAction { [weak clipEditorWindows, weak projectWindowSaveCoordinator] in
                    clipEditorWindows?.requestCloseAll { didClose in
                        guard didClose else { return }
                        projectWindowSaveCoordinator?.requestClose { _ in }
                    }
                }
                NotificationCenter.default.post(name: .trimatoProjectDidOpen, object: nil)
            }
            .onChange(of: controller.isShowingProjectSettings) { isShowing in
                if !isShowing { requestEditorFocus() }
            }
            .onDisappear {
                ExternalMediaOpenCoordinator.shared.unregister(controller: controller)
            }
            .sheet(isPresented: $controller.isShowingProjectSettings) {
                ProjectCreationView(
                    initialProject: controller.project,
                    heading: "Project Settings",
                    actionTitle: "Save Project Settings",
                    finish: { values in
                        controller.updateProjectSettings(
                            name: values.name,
                            format: values.format,
                            targetDuration: values.targetDuration
                        )
                        controller.dismissProjectSettings()
                    },
                    cancel: controller.dismissProjectSettings
                )
            }
            .sheet(isPresented: Binding(
                get: { controller.isExporting },
                set: { presented in
                    if !presented, controller.isExporting { controller.cancelExport() }
                }
            )) {
                ExportProgressSheet(
                    title: "Exporting Project",
                    progress: controller.exportProgress,
                    cancel: controller.cancelExport
                )
            }
            .sheet(item: $controller.transitionRequest, onDismiss: transitionSheetDidDismiss) { request in
                transitionSheet(for: request)
            }
            .alert(item: $controller.presentedError) { error in
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private var editor: some View {
        HSplitView {
            MacEditorPane("Project") {
                ProjectBrowserView(
                    controller: controller,
                    openClipEditor: clipEditorWindows.open
                )
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)
                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)

            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(
                        controller: controller
                    )
                }
                .frame(minHeight: 360)
                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)

                HSplitView {
                    MacEditorPane("Timeline") {
                        ProjectTimelineView(
                            controller: controller,
                            openClipEditor: clipEditorWindows.open
                        )
                    }
                        .frame(minWidth: 460)
                        .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
                    MacEditorPane("Inspector") {
                        VStack(spacing: 0) {
                            Text("Inspector")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(EditorTheme.controlSurface)

                            Divider()

                            ClipInspectorView(controller: controller)
                        }
                    }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                        .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
                }
                .frame(minHeight: 240)
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
    }

    @ViewBuilder
    private func transitionSheet(for request: TransitionRequest) -> some View {
        if request.mode == .standard {
            AddTransitionView(
                project: controller.project,
                request: request,
                add: addTransitions,
                cancel: dismissStandardTransition
            )
        } else {
            QuickTransitionView(
                project: controller.project,
                request: request,
                add: { transitions in
                    try controller.addTransitions(transitions, selectAddedTransition: false)
                },
                finished: dismissQuickTransition
            )
        }
    }

    private func addTransitions(_ transitions: [TimelineTransition]) {
        let returnsToEditor = controller.transitionRequestReturnsToEditor
        do {
            try controller.addTransitions(transitions, selectAddedTransition: !returnsToEditor)
            controller.transitionRequest = nil
        } catch {
            controller.presentedError = ProjectPresentedError(
                title: "Transition Could Not Be Added",
                message: error.localizedDescription
            )
        }
    }

    private func dismissStandardTransition() {
        controller.transitionRequest = nil
    }

    private func dismissQuickTransition() {
        controller.transitionRequest = nil
    }

    private func transitionSheetDidDismiss() {
        guard controller.transitionRequestReturnsToEditor else { return }
        Task { @MainActor in
            await Task.yield()
            controller.requestEditorFocusRestore()
        }
    }

    private func requestEditorFocus() {
        hasRequestedInitialEditorFocus = true
        controller.requestEditorFocusRestore()
    }

}

private struct ProjectViewerView: View {
    @ObservedObject var controller: ProjectController
    @StateObject private var viewModel = ProjectPlayerViewModel()
    @StateObject private var focusScope = EditorAccessibilityFocusScope()
    @AccessibilityFocusState private var playPauseFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Editor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("trimato.editor.heading")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(EditorTheme.controlSurface)

            Divider()

            videoArea
                .frame(minHeight: 180)
                .layoutPriority(1)
            controlsArea
        }
        .accessibilityIdentifier("trimato.editor.root")
        .background(EditorAccessibilityFocusBridge(scope: focusScope))
        .focusedObject(viewModel)
        .onAppear {
            controller.installProjectPlayer(viewModel)
            viewModel.scopeKeyboardCommands { [weak focusScope] in
                focusScope?.containsAccessibilityFocus == true
            }
            viewModel.onBladeAtPlayhead { [weak controller] in
                controller?.splitClipAtPlayhead()
            }
            viewModel.onStandardTransition { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.requestTransition(at: viewModel.currentTime)
            }
            viewModel.onQuickCrossTransition { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.requestQuickTransition(at: viewModel.currentTime, mode: .quickCross)
            }
            viewModel.onQuickFade { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.requestQuickTransition(at: viewModel.currentTime, mode: .quickFade)
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
        .onChange(of: controller.editorFocusRestoreRequest) { _ in
            restorePlayPauseFocus()
        }
        .alert(item: Binding(
            get: { viewModel.presentedPreviewFailure },
            set: { failure in
                if failure == nil { viewModel.dismissPreviewFailure() }
            }
        )) { failure in
            previewFailureAlert(failure)
        }
    }

    private func prepare() {
        viewModel.prepare(
            project: controller.project,
            mediaURLs: controller.resolvedMediaURLs(),
            initialTime: controller.timelinePlayhead
        )
    }

    private func restorePlayPauseFocus() {
        playPauseFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            playPauseFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            playPauseFocused = true
        }
    }

    private func previewFailureAlert(_ failure: ProjectPreviewFailure) -> Alert {
        if let transitionID = failure.transitionID {
            return Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                primaryButton: .destructive(Text("Remove Transition")) {
                    viewModel.dismissPreviewFailure()
                    controller.deleteTransition(id: transitionID)
                    controller.requestEditorFocusRestore()
                },
                secondaryButton: .cancel(Text("Dismiss")) {
                    viewModel.dismissPreviewFailure()
                    controller.requestEditorFocusRestore()
                }
            )
        }
        return Alert(
            title: Text(failure.title),
            message: Text(failure.message),
            primaryButton: .default(Text("Retry")) {
                viewModel.dismissPreviewFailure()
                prepare()
            },
            secondaryButton: .cancel(Text("Dismiss")) {
                viewModel.dismissPreviewFailure()
                controller.requestEditorFocusRestore()
            }
        )
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayerView(player: viewModel.player)
                .accessibilityHidden(true)
            if !controller.project.tracks.contains(where: { !$0.clips.isEmpty }) {
                Text("Add a clip to the project timeline")
                    .foregroundStyle(.secondary)
            } else if viewModel.isPreparing {
                ProgressView("Preparing Project Preview")
                    .padding()
                    .accessibilityHidden(true)
            } else if viewModel.errorMessage != nil {
                VStack(spacing: 12) {
                    Text("Project preview unavailable")
                        .font(.headline)
                    Button("Show Preview Error") { viewModel.showPreviewFailure() }
                }
                .padding()
                .frame(maxWidth: 480)
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
            Slider(
                value: Binding(
                    get: { viewModel.playbackFraction },
                    set: { viewModel.seek(toFraction: $0) }
                ),
                in: 0...1
            )
            .disabled(!viewModel.canControlPlayback)
            .accessibilityLabel("Project playhead")
            .accessibilityValue(viewModel.accessibilityTimecodeLabel)
            .accessibilityIdentifier("trimato.editor.playhead")

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
            .accessibilityIdentifier("trimato.editor.timecode")

            HStack(spacing: 20) {
                Button { viewModel.goToStart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to beginning")
                .accessibilityIdentifier("trimato.editor.go-to-beginning")

                Button { viewModel.goToPreviousEdit() } label: {
                    Image(systemName: "chevron.left.2")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous edit point")
                .accessibilityIdentifier("trimato.editor.previous-edit")

                Button { controller.splitClipAtPlayhead() } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Blade at playhead")
                .accessibilityHint("Splits the primary timeline clip beneath the playhead")
                .accessibilityIdentifier("trimato.editor.blade")

                Button { viewModel.goToNextEdit() } label: {
                    Image(systemName: "chevron.right.2")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next edit point")
                .accessibilityIdentifier("trimato.editor.next-edit")

                Button { viewModel.goToEnd() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to end")
                .accessibilityIdentifier("trimato.editor.go-to-end")
            }
            .font(.title2)
            .foregroundStyle(EditorTheme.accent)
            .disabled(!viewModel.canControlPlayback)

            GroupBox("In and Out Points") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Mark In") { viewModel.markIn() }
                            .accessibilityIdentifier("trimato.editor.mark-in")
                        Text("In: \(viewModel.inMarkerDisplay)")
                            .monospacedDigit()
                        Button("Clear In") { viewModel.clearIn() }
                            .disabled(viewModel.inMarker == nil)
                            .accessibilityIdentifier("trimato.editor.clear-in")
                    }
                    HStack {
                        Button("Mark Out") { viewModel.markOut() }
                            .accessibilityIdentifier("trimato.editor.mark-out")
                        Text("Out: \(viewModel.outMarkerDisplay)")
                            .monospacedDigit()
                        Button("Clear Out") { viewModel.clearOut() }
                            .disabled(viewModel.outMarker == nil)
                            .accessibilityIdentifier("trimato.editor.clear-out")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!viewModel.canControlPlayback)
            .accessibilityIdentifier("trimato.editor.in-out-points")

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
                .accessibilityIdentifier("trimato.editor.step-backward")

                Button { viewModel.seekBackward() } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back 10 seconds")
                .accessibilityIdentifier("trimato.editor.skip-backward")

                Button { viewModel.togglePlayback() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("trimato.editor.play-pause")
                .accessibilityFocused($playPauseFocused)

                Button { viewModel.seekForward() } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward 10 seconds")
                .accessibilityIdentifier("trimato.editor.skip-forward")

                Button { viewModel.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step forward one frame")
                .accessibilityIdentifier("trimato.editor.step-forward")
            }
            .foregroundStyle(EditorTheme.accent)
            .disabled(!viewModel.canControlPlayback)

        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }
}
