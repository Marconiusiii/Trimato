import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var controller: ProjectController
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @StateObject private var projectWindowSaveCoordinator: ProjectWindowSaveCoordinator
    @State private var restoresEditorFocusAfterTransitionSheet = false
    @State private var timelineFocusAfterTransitionSheet: TimelineElementSelection?
    @State private var pendingTransitions: [TimelineTransition]?
    @State private var transitionTask: Task<Void, Never>?
    @State private var transitionOutcome = OperationProgressOutcome.completed
    @State private var transitionFinished = false
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
        progressEditor
            .background(EditorTheme.workspace)
            .background(ProjectWindowSaveBridge(saveCoordinator: projectWindowSaveCoordinator))
            .preferredColorScheme(.dark)
            .focusedSceneObject(controller)
            .handlesTrimatoMediaOpening()
            .onAppear {
                controller.installSaveCoordinator(projectWindowSaveCoordinator)
                projectWindowSaveCoordinator.onUndoManagerAvailable { [weak controller] undoManager in
                    controller?.installUndoManager(undoManager)
                }
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
            .onChange(of: controller.generatorRequestID) { _, id in
                if let id { openWindow(id: "generator", value: id) }
            }
            .onChange(of: controller.isShowingProjectSettings) { _, isShowing in
                if !isShowing { controller.requestEditorFocusRestore() }
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
            .sheet(item: $controller.transitionRequest, onDismiss: transitionSheetDismissed) { request in
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

    private var progressEditor: some View {
        editor
            .operationProgress(exportOperation, outcome: controller.presentedError == nil ? .completed : .failed)
            .operationProgress(importOperation, outcome: controller.presentedError == nil ? .completed : .failed)
            .operationProgress(transitionOperation, outcome: transitionOutcome,
                               completionPending: transitionFinished, dismissed: restoreTransitionFocus)
    }

    private var exportOperation: OperationProgress? {
        guard controller.isExporting else { return nil }
        return OperationProgress(title: "Exporting Project", progress: controller.exportProgress,
                                 cancel: { controller.cancelExport() })
    }

    private var importOperation: OperationProgress? {
        guard controller.isImporting else { return nil }
        var operation = OperationProgress(title: "Importing Clips")
        if controller.canCancelImport { operation.cancel = { controller.cancelImport() } }
        return operation
    }

    private var transitionOperation: OperationProgress? {
        guard let name = controller.applyingTransitionName else { return nil }
        return OperationProgress(title: "Applying \(name)", progress: controller.applyingTransitionProgress,
                                 cancel: { transitionTask?.cancel() })
    }

    private var editor: some View {
        HSplitView {
            MacEditorPane("Project") {
                ProjectBrowserView(
                    controller: controller,
                    openClipEditor: clipEditorWindows.open,
                    workspacePaneLinks: workspacePaneLinks
                )
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(
                        controller: controller,
                        openClipEditor: clipEditorWindows.open,
                        workspacePaneLinks: workspacePaneLinks
                    )
                }
                .frame(minHeight: 360)

                HSplitView {
                    MacEditorPane("Timeline") {
                        ProjectTimelineView(
                            controller: controller,
                            openClipEditor: clipEditorWindows.open,
                            workspacePaneLinks: workspacePaneLinks
                        )
                    }
                        .frame(minWidth: 460)
                    MacEditorPane("Inspector") {
                        VStack(spacing: 0) {
                            Text("Inspector")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(EditorTheme.controlSurface)

                            Divider()

                            ClipInspectorView(controller: controller)
                        }
                    }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
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
                add: addTransitions,
                finished: dismissQuickTransition
            )
        }
    }

    private func addTransitions(_ transitions: [TimelineTransition]) {
        pendingTransitions = transitions
        dismissTransitionSheet()
    }

    private func dismissStandardTransition() {
        dismissTransitionSheet()
    }

    private func dismissQuickTransition() {
        dismissTransitionSheet()
    }

    private func dismissTransitionSheet() {
        restoresEditorFocusAfterTransitionSheet = controller.transitionRequestReturnsToEditor
        if !controller.transitionRequestReturnsToEditor {
            switch controller.selection {
            case .transition(let id):
                timelineFocusAfterTransitionSheet = .transition(id)
            case .timelineClip(let id):
                timelineFocusAfterTransitionSheet = .clip(id)
            default:
                if let clipID = controller.transitionRequest?.clipID {
                    timelineFocusAfterTransitionSheet = .clip(clipID)
                }
            }
        }
        controller.transitionRequest = nil
    }

    private func transitionSheetDismissed() {
        guard let transitions = pendingTransitions else { restoreTransitionFocus(); return }
        pendingTransitions = nil
        let returnsToEditor = restoresEditorFocusAfterTransitionSheet
        transitionOutcome = .completed
        transitionFinished = false
        transitionTask = Task { @MainActor in
            do {
                try await controller.applyTransitions(transitions, selectAddedTransition: !returnsToEditor)
                if !returnsToEditor, case .transition(let id) = controller.selection {
                    timelineFocusAfterTransitionSheet = .transition(id)
                }
            } catch is CancellationError {
                transitionOutcome = .cancelled
            } catch {
                transitionOutcome = .failed
                controller.presentedError = ProjectPresentedError(title: "Transition Could Not Be Applied",
                                                                 message: error.localizedDescription)
            }
            transitionTask = nil
            transitionFinished = true
        }
    }

    private func restoreTransitionFocus() {
        guard transitionTask == nil else { return }
        transitionFinished = false
        if controller.presentedError != nil {
            restoresEditorFocusAfterTransitionSheet = false
            timelineFocusAfterTransitionSheet = nil
            return
        }
        if restoresEditorFocusAfterTransitionSheet {
            restoresEditorFocusAfterTransitionSheet = false
            controller.requestEditorFocusRestore()
        } else if let target = timelineFocusAfterTransitionSheet {
            timelineFocusAfterTransitionSheet = nil
            controller.requestTimelineFocusRestore(to: target)
        }
    }
}

private struct ProjectViewerView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID
    @StateObject private var viewModel = ProjectPlayerViewModel()
    @StateObject private var focusScope = EditorAccessibilityFocusScope()
    @AccessibilityFocusState private var projectPlayheadFocused: Bool
    @State private var pendingProjectPlayheadFocus = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Editor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLinkedGroup(id: "workspace-panes", in: workspacePaneLinks)
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
            viewModel.scopeKeyboardCommands { [weak focusScope, weak controller] in
                (NSWorkspace.shared.isVoiceOverEnabled || controller?.timelineHasKeyboardFocus != true) &&
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
            viewModel.onOpenClipAtPlayhead { [weak controller, weak viewModel] in
                guard let controller, let viewModel,
                      let selection = controller.editorClipSelection(at: viewModel.currentTime) else { return }
                openClipEditor(selection)
            }
            viewModel.onSelectAdjacentTrack { [weak controller] offset in
                controller?.selectAdjacentTrack(offset, restoreTimelineFocus: false)
            }
            viewModel.onPositionActiveClipHead { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.positionActiveAdditionalTrackClip(edge: .head, at: viewModel.currentTime)
            }
            viewModel.onPositionActiveClipTail { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.positionActiveAdditionalTrackClip(edge: .tail, at: viewModel.currentTime)
            }
            viewModel.onTrimActiveClipStart { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.trimActiveTrackClip(edge: .head, at: viewModel.currentTime)
            }
            viewModel.onTrimActiveClipEnd { [weak controller, weak viewModel] in
                guard let controller, let viewModel else { return }
                controller.trimActiveTrackClip(edge: .tail, at: viewModel.currentTime)
            }
            prepare()
        }
        .onChange(of: controller.project) { _, project in
            if !controller.consumePreparedTransitionPreview(for: project) { prepare() }
        }
        .onChange(of: controller.timelinePlayhead) { _, time in
            guard abs(viewModel.currentTime.seconds - time.seconds) > 0.02 else { return }
            viewModel.seek(to: time)
        }
        .onChange(of: viewModel.currentTime) { _, time in
            controller.timelinePlayhead = time
        }
        .onChange(of: controller.editorFocusRestoreRequest) {
            restoreProjectPlayheadFocus()
        }
        .operationProgress(viewModel.isPreparing && controller.applyingTransitionName == nil ?
            OperationProgress(title: "Preparing Project Preview", cancel: viewModel.cancelPreparation) : nil,
            outcome: viewModel.errorMessage == nil ? .completed : .failed,
            dismissed: { preparationChanged(false) })
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

    private func restoreProjectPlayheadFocus() {
        guard viewModel.canControlPlayback else {
            pendingProjectPlayheadFocus = true
            return
        }
        pendingProjectPlayheadFocus = false
        if !projectPlayheadFocused { projectPlayheadFocused = true }
    }

    private func preparationChanged(_ isPreparing: Bool) {
        if isPreparing { return }
        Task { @MainActor in
            await Task.yield()
            if pendingProjectPlayheadFocus,
               viewModel.presentedPreviewFailure == nil,
               viewModel.canControlPlayback {
                restoreProjectPlayheadFocus()
            }
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
            VideoPlayerView(
                player: viewModel.player,
                accessibleFrame: controller.project.hasTimelineVideo && !viewModel.isPreparing && viewModel.errorMessage == nil,
                frameDescription: "Project time \(String(format: "%.3f", viewModel.currentTime.seconds)) seconds, frame \(Int((viewModel.currentTime.seconds * (controller.project.format.frameRate ?? 30)).rounded()))"
            )
            if !controller.project.tracks.contains(where: { !$0.clips.isEmpty }) {
                Text("Add a clip to the project timeline")
                    .foregroundStyle(.secondary)
            } else if viewModel.isPreparing {
                EmptyView()
            } else if viewModel.preparationWasCancelled {
                Button("Retry Project Preview", action: prepare)
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
                in: 0...1,
                step: viewModel.playbackFractionStep
            )
            .disabled(!viewModel.canControlPlayback)
            .accessibilityLabel("Project playhead")
            .accessibilityValue(viewModel.accessibilityTimecodeLabel)
            .accessibilityIdentifier("trimato.editor.playhead")
            .accessibilityFocused($projectPlayheadFocused)

            moveAndEditGroup
            markersGroup
            playbackGroup

        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(EditorTheme.controlSurface)
    }

    private var moveAndEditGroup: some View {
        GroupBox {
            HStack(spacing: 20) {
                Button { viewModel.goToStart() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to beginning")
                    .accessibilityIdentifier("trimato.editor.go-to-beginning")
                Button { viewModel.goToPreviousEdit() } label: { Image(systemName: "chevron.left.2") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous edit point")
                    .accessibilityIdentifier("trimato.editor.previous-edit")
                Button { controller.splitClipAtPlayhead() } label: { Image(systemName: "scissors") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Blade at playhead")
                    .accessibilityHint("Splits the primary timeline clip beneath the playhead")
                    .accessibilityIdentifier("trimato.editor.blade")
                Button { viewModel.goToNextEdit() } label: { Image(systemName: "chevron.right.2") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next edit point")
                    .accessibilityIdentifier("trimato.editor.next-edit")
                Button { viewModel.goToEnd() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to end")
                    .accessibilityIdentifier("trimato.editor.go-to-end")
                Button { viewModel.goToVideoEnd() } label: { Image(systemName: "film.stack") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to end of video")
                    .accessibilityIdentifier("trimato.editor.go-to-video-end")
            }
            .font(.title2)
            .foregroundStyle(EditorTheme.accent)
            .padding(.top, 4)
        } label: {
            Text("Move and Edit").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!viewModel.canControlPlayback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move and Edit")
        .accessibilityIdentifier("trimato.editor.move-and-edit")
    }

    private var markersGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Mark In") { viewModel.markIn() }
                        .accessibilityIdentifier("trimato.editor.mark-in")
                    Text("In: \(viewModel.inMarkerDisplay)").monospacedDigit()
                    Button("Clear In") { viewModel.clearIn() }
                        .disabled(viewModel.inMarker == nil)
                        .accessibilityIdentifier("trimato.editor.clear-in")
                }
                HStack {
                    Button("Mark Out") { viewModel.markOut() }
                        .accessibilityIdentifier("trimato.editor.mark-out")
                    Text("Out: \(viewModel.outMarkerDisplay)").monospacedDigit()
                    Button("Clear Out") { viewModel.clearOut() }
                        .disabled(viewModel.outMarker == nil)
                        .accessibilityIdentifier("trimato.editor.clear-out")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("Markers").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!viewModel.canControlPlayback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markers")
        .accessibilityIdentifier("trimato.editor.markers")
    }

    private var playbackGroup: some View {
        GroupBox {
            VStack(spacing: 8) {
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
                .accessibilityLabel("Project timecode")
                .accessibilityValue(viewModel.accessibilityTimecodeLabel)
                .accessibilityHint(viewModel.showingFrames ? "Toggles to timecode" : "Toggles to frames")
                .accessibilityIdentifier("trimato.editor.timecode")

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
            }
            .padding(.top, 4)
        } label: {
            Text("Playback").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!viewModel.canControlPlayback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback")
        .accessibilityIdentifier("trimato.editor.playback")
    }
}
