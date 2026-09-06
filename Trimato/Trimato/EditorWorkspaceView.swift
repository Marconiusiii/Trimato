import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var controller: ProjectController
    @StateObject private var projectPlayer: ProjectPlayerViewModel
    @StateObject private var clipEditorWindows: ClipEditorWindowCoordinator
    @StateObject private var captionEditorWindows: CaptionEditorWindowCoordinator
    @StateObject private var projectWindowSaveCoordinator: ProjectWindowSaveCoordinator
    @State private var restoresEditorFocusAfterTransitionSheet = false
    @State private var timelineFocusAfterTransitionSheet: TimelineElementSelection?
    @State private var pendingTransitions: [TimelineTransition]?
    @State private var transitionTask: Task<Void, Never>?
    @State private var transitionOutcome = OperationProgressOutcome.completed
    @State private var hasRequestedInitialImportFocus = false
    @State private var initialImportFocusRequest = 0
    @Namespace private var workspacePaneLinks

    init(document: ProjectDocument) {
        let controller = ProjectController(document: document)
        let hasTimelineContent = document.project.tracks.contains { !$0.clips.isEmpty }
        _controller = StateObject(wrappedValue: controller)
        _projectPlayer = StateObject(wrappedValue: ProjectPlayerViewModel(
            awaitingInitialPreparation: hasTimelineContent
        ))
        _clipEditorWindows = StateObject(wrappedValue: ClipEditorWindowCoordinator(controller: controller))
        _captionEditorWindows = StateObject(wrappedValue: CaptionEditorWindowCoordinator(controller: controller))
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
                projectWindowSaveCoordinator.onWindowBecameKey { [weak controller, weak projectPlayer] in
                    guard let controller else { return }
                    ExternalMediaOpenCoordinator.shared.activate(controller: controller)
                    Task { @MainActor in
                        await Task.yield()
                        guard projectPlayer?.isInitialPreparationPending == false else { return }
                        requestInitialImportFocus()
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
                controller.installCaptionEditorActions(
                    open: { [weak captionEditorWindows] in captionEditorWindows?.openNew() },
                    close: { [weak captionEditorWindows] in captionEditorWindows?.close() }
                )
                NotificationCenter.default.post(name: .trimatoProjectDidOpen, object: nil)
            }
            .sheet(item: $controller.recordingSession, onDismiss: {
                controller.recordingWindowDidDismiss()
            }) { session in
                ProjectRecordingView(session: session)
            }
            .onChange(of: controller.generatorRequestID) { _, id in
                if let id {
                    GeneratorWindowRegistry.shared.present(
                        id: id,
                        parentWindow: projectWindowSaveCoordinator.attachedWindow
                    )
                    controller.generatorRequestID = nil
                }
            }
            .onChange(of: controller.isShowingProjectSettings) { _, isShowing in
                if !isShowing { controller.requestEditorFocusRestore() }
            }
            .onChange(of: controller.captionFinalizationReport) { _, report in
                if let report { presentCaptionFinalizationReport(report) }
            }
            .onDisappear {
                ExternalMediaOpenCoordinator.shared.unregister(controller: controller)
            }
            .sheet(isPresented: Binding(
                get: { controller.isShowingProjectSettings },
                set: { if !$0 { controller.dismissProjectSettings() } }
            )) {
                ProjectCreationView(
                    initialProject: controller.project,
                    heading: "Project Settings",
                    finish: { values in
                        controller.updateProjectSettings(
                            name: values.name,
                            format: values.format,
                            targetDuration: values.targetDuration
                        )
                        controller.dismissProjectSettings()
                    },
                    primaryTitle: "Save Project Settings",
                    cancel: controller.dismissProjectSettings
                )
            }
            .sheet(isPresented: Binding(
                get: { controller.transitionRequest != nil },
                set: { if !$0 { dismissTransitionSheet() } }
            ), onDismiss: transitionSheetDismissed) {
                if let request = controller.transitionRequest {
                    transitionSheet(for: request)
                }
            }
            .applicationMessage(controller.presentedError.map {
                ApplicationMessageDescriptor(title: $0.title, message: $0.message)
            }) {
                controller.presentedError = nil
            }
            .applicationMessage(projectWindowSaveCoordinator.presentedError.map {
                ApplicationMessageDescriptor(title: $0.title, message: $0.message)
            }) {
                projectWindowSaveCoordinator.presentedError = nil
            }
    }

    private func presentCaptionFinalizationReport(_ report: CaptionFinalizationReport) {
        controller.dismissCaptionFinalizationReport()
        CaptionFinalizationWindowCoordinator.shared.present(
            report: report,
            parentWindow: projectWindowSaveCoordinator.attachedWindow,
            reveal: { [weak controller] cueID in
                controller?.revealCaptionFinalizationIssue(cueID)
            }
        )
    }

    private var progressEditor: some View {
        editor
            .disabled(projectPlayer.isInitialPreparationPending)
            .accessibilityHidden(projectPlayer.isInitialPreparationPending)
            .operationProgress(
                initialPreparationOperation,
                outcome: projectPlayer.errorMessage == nil ? .completed : .failed,
                returnWindow: projectWindowSaveCoordinator.attachedWindow,
                waitsForReturnWindow: true,
                dismissed: initialPreparationDismissed
            )
            .operationProgress(
                exportOperation,
                outcome: controller.presentedError == nil ? .completed : .failed,
                returnWindow: projectWindowSaveCoordinator.attachedWindow,
                waitsForReturnWindow: true
            )
            .operationProgress(
                importOperation,
                outcome: controller.importOutcome,
                returnWindow: projectWindowSaveCoordinator.attachedWindow,
                waitsForReturnWindow: true,
                dismissed: restoreImportFocus
            )
            .operationProgress(transitionOperation, outcome: transitionOutcome,
                               completionPending: transitionTask != nil,
                               returnWindow: projectWindowSaveCoordinator.attachedWindow,
                               waitsForReturnWindow: true,
                               dismissed: restoreTransitionFocus)
    }

    private var initialPreparationOperation: OperationProgress? {
        guard projectPlayer.isInitialPreparationPending else { return nil }
        return OperationProgress(
            title: "Preparing Project",
            progress: projectPlayer.preparationProgress,
            announceCompletion: false
        )
    }

    private func initialPreparationDismissed() {
        guard projectPlayer.errorMessage == nil else { return }
        requestInitialImportFocus()
    }

    private func requestInitialImportFocus() {
        guard !hasRequestedInitialImportFocus else { return }
        hasRequestedInitialImportFocus = true
        initialImportFocusRequest += 1
    }

    private var exportOperation: OperationProgress? {
        guard controller.isExporting else { return nil }
        return OperationProgress(title: "Exporting Project", progress: controller.exportProgress,
                                 cancel: { controller.cancelExport() })
    }

    private var importOperation: OperationProgress? {
        guard controller.isImporting else { return nil }
        var operation = OperationProgress(
            title: "Importing Files",
            progress: controller.importProgress,
            detail: controller.importDetail
        )
        if controller.canCancelImport { operation.cancel = { controller.cancelImport() } }
        return operation
    }

    private func restoreImportFocus() {
        initialImportFocusRequest += 1
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
                    workspacePaneLinks: workspacePaneLinks,
                    initialImportFocusRequest: initialImportFocusRequest
                )
            }
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)

            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(
                        controller: controller,
                        openClipEditor: clipEditorWindows.open,
                        workspacePaneLinks: workspacePaneLinks,
                        viewModel: projectPlayer
                    )
                }
                .frame(minHeight: 360)

                MacEditorPane("Timeline") {
                    ProjectTimelineView(
                        controller: controller,
                        openClipEditor: clipEditorWindows.open,
                        openCaptionEditor: captionEditorWindows.open,
                        workspacePaneLinks: workspacePaneLinks
                    )
                }
                .frame(minWidth: 460)
                .frame(minHeight: 240)
            }
        }
        .frame(minWidth: 800, minHeight: 720)
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

    private var transitionPanelTitle: String {
        guard let request = controller.transitionRequest else { return "Transition" }
        if request.mode == .standard { return "Add Transition" }
        if request.mode == .quickFade { return "Quick Fade" }
        let track = controller.project.track(id: request.trackID)
        return track?.kind == .audio ? "Quick Cross Fade" : "Quick Cross Dissolve"
    }

    private var transitionPrimaryTitle: String {
        guard let request = controller.transitionRequest else { return "Apply" }
        if request.mode == .standard { return "Add" }
        if request.mode == .quickFade { return "Apply Fade" }
        let track = controller.project.track(id: request.trackID)
        return track?.kind == .audio ? "Apply Cross Fade" : "Apply Cross Dissolve"
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
        }
    }

    private func restoreTransitionFocus() {
        guard transitionTask == nil else { return }
        if controller.presentedError != nil {
            restoresEditorFocusAfterTransitionSheet = false
            timelineFocusAfterTransitionSheet = nil
            return
        }
        if restoresEditorFocusAfterTransitionSheet {
            restoresEditorFocusAfterTransitionSheet = false
            controller.requestEditorFocusRestoreIfNeeded()
        } else if let target = timelineFocusAfterTransitionSheet {
            timelineFocusAfterTransitionSheet = nil
            controller.requestTimelineFocusRestore(to: target)
        }
    }
}

struct ProjectViewerView: View {
    private enum AccessibilityTarget: Hashable {
        case videoFrame
        case playhead
        case goToBeginning
        case previousEdit
        case blade
        case nextEdit
        case goToEnd
        case goToVideoEnd
        case markIn
        case clearIn
        case markOut
        case clearOut
        case timecode
        case stepBackward
        case skipBackward
        case playPause
        case skipForward
        case stepForward
    }

    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    let workspacePaneLinks: Namespace.ID
    @ObservedObject var viewModel: ProjectPlayerViewModel
    @StateObject private var focusScope = EditorAccessibilityFocusScope()
    @AccessibilityFocusState private var focusedAccessibilityTarget: AccessibilityTarget?
    @State private var pendingProjectPlayheadFocus = false

    init(controller: ProjectController, openClipEditor: @escaping (EditorSelection) -> Void,
         workspacePaneLinks: Namespace.ID, viewModel: ProjectPlayerViewModel) {
        self.controller = controller
        self.openClipEditor = openClipEditor
        self.workspacePaneLinks = workspacePaneLinks
        self.viewModel = viewModel
    }

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
            viewModel.selectEditPointTrack(controller.activeTimelineTrackID, in: controller.project)
            controller.installEditorAccessibilityFocusProvider { [weak focusScope] in
                focusScope?.containsInputFocus == true
            }
            viewModel.scopeKeyboardCommands { [weak focusScope, weak controller] in
                (NSWorkspace.shared.isVoiceOverEnabled || controller?.timelineHasKeyboardFocus != true) &&
                    focusScope?.containsInputFocus == true
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
            viewModel.onOpenGenerator { [weak controller] in
                controller?.requestGenerator()
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
            requestPreparation()
        }
        .onChange(of: controller.project) { previous, project in
            guard !controller.consumePreparedTransitionPreview(for: project),
                  ProjectPreviewInput(previous) != ProjectPreviewInput(project) else { return }
            requestPreparation()
        }
        .onChange(of: controller.activeTimelineTrackID) { _, trackID in
            viewModel.selectEditPointTrack(trackID, in: controller.project)
        }
        .onChange(of: controller.editorFocusRestoreRequest) {
            restoreProjectPlayheadFocus()
        }
        .onChange(of: focusedAccessibilityTarget) { _, target in
            if target != nil { controller.setProjectInfoTarget(.editor) }
            if target == .playhead {
                viewModel.refreshAccessibilityValueForFocus()
            }
        }
        // Timeline edits rebuild playback in the background. They must never
        // present a sheet or announce preparation over the active Clip Editor.
        .onChange(of: viewModel.isPreparing) { _, preparing in
            preparationChanged(preparing)
        }
    }

    private func prepare() {
        viewModel.prepare(
            project: controller.project,
            mediaURLs: controller.resolvedMediaURLs(),
            initialTime: controller.timelinePlayhead
        )
    }

    private func requestPreparation() {
        viewModel.requestPreparation(
            project: controller.project,
            mediaURLs: controller.resolvedMediaURLs(),
            initialTime: controller.timelinePlayhead
        )
    }

    private func restoreProjectPlayheadFocus() {
        guard focusScope.boundaryView?.window?.isKeyWindow == true else {
            pendingProjectPlayheadFocus = true
            return
        }
        guard viewModel.canControlPlayback else {
            pendingProjectPlayheadFocus = true
            return
        }
        pendingProjectPlayheadFocus = false
        viewModel.refreshAccessibilityValueForFocus()
        focusedAccessibilityTarget = .playhead
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

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayerView(
                player: viewModel.player,
                captionCues: controller.project.captionTrack?.captionCues ?? [],
                captionDuration: controller.project.duration,
                captionRenderSize: controller.project.format.width.flatMap { width in
                    controller.project.format.height.map { height in
                        CGSize(width: width, height: height)
                    }
                },
                accessibleFrame: controller.project.hasTimelineVideo && viewModel.canControlPlayback && viewModel.errorMessage == nil,
                frameDescription: "Project time \(String(format: "%.3f", viewModel.currentTime.seconds)) seconds, frame \(Int((viewModel.currentTime.seconds * (controller.project.format.frameRate ?? 30)).rounded()))"
            )
            .accessibilityFocused($focusedAccessibilityTarget, equals: .videoFrame)
            if !controller.project.tracks.contains(where: { !$0.clips.isEmpty }) {
                Text("Add a clip to the project timeline")
                    .foregroundStyle(.secondary)
            } else if viewModel.isPreparing {
                EmptyView()
            } else if viewModel.preparationWasCancelled {
                Button("Retry Project Preview", action: prepare)
            } else if let failure = viewModel.presentedPreviewFailure {
                previewFailureView(failure)
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

    private func previewFailureView(_ failure: ProjectPreviewFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title)
                .font(.headline)
            Text(failure.message)
                .textSelection(.enabled)
            HStack {
                if let transitionID = failure.transitionID {
                    Button("Remove Transition", role: .destructive) {
                        viewModel.dismissPreviewFailure()
                        controller.deleteTransition(id: transitionID)
                        controller.requestEditorFocusRestore()
                    }
                } else {
                    Button("Retry") {
                        viewModel.dismissPreviewFailure()
                        prepare()
                    }
                }
                Button("Dismiss") {
                    viewModel.dismissPreviewFailure()
                    controller.requestEditorFocusRestore()
                }
            }
        }
        .padding()
        .frame(maxWidth: 480)
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
            .accessibilityFocused($focusedAccessibilityTarget, equals: .playhead)

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
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .goToBeginning)
                Button { viewModel.goToPreviousEdit() } label: { Image(systemName: "chevron.left.2") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous edit point")
                    .accessibilityIdentifier("trimato.editor.previous-edit")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .previousEdit)
                Button { controller.splitClipAtPlayhead() } label: { Image(systemName: "scissors") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Blade at playhead")
                    .accessibilityHint("Splits the primary timeline clip beneath the playhead")
                    .accessibilityIdentifier("trimato.editor.blade")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .blade)
                Button { viewModel.goToNextEdit() } label: { Image(systemName: "chevron.right.2") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next edit point")
                    .accessibilityIdentifier("trimato.editor.next-edit")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .nextEdit)
                Button { viewModel.goToEnd() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to end")
                    .accessibilityIdentifier("trimato.editor.go-to-end")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .goToEnd)
                Button { viewModel.goToVideoEnd() } label: { Image(systemName: "film.stack") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to end of video")
                    .accessibilityIdentifier("trimato.editor.go-to-video-end")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .goToVideoEnd)
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
                        .accessibilityFocused($focusedAccessibilityTarget, equals: .markIn)
                    Text("In: \(viewModel.inMarkerDisplay)").monospacedDigit()
                    Button("Clear In") { viewModel.clearIn() }
                        .disabled(viewModel.inMarker == nil)
                        .accessibilityIdentifier("trimato.editor.clear-in")
                        .accessibilityFocused($focusedAccessibilityTarget, equals: .clearIn)
                }
                HStack {
                    Button("Mark Out") { viewModel.markOut() }
                        .accessibilityIdentifier("trimato.editor.mark-out")
                        .accessibilityFocused($focusedAccessibilityTarget, equals: .markOut)
                    Text("Out: \(viewModel.outMarkerDisplay)").monospacedDigit()
                    Button("Clear Out") { viewModel.clearOut() }
                        .disabled(viewModel.outMarker == nil)
                        .accessibilityIdentifier("trimato.editor.clear-out")
                        .accessibilityFocused($focusedAccessibilityTarget, equals: .clearOut)
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
                .accessibilityFocused($focusedAccessibilityTarget, equals: .timecode)

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
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .stepBackward)
                    Button { viewModel.seekBackward() } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip back 10 seconds")
                    .accessibilityIdentifier("trimato.editor.skip-backward")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .skipBackward)
                    Button { viewModel.togglePlayback() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .frame(width: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("trimato.editor.play-pause")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .playPause)
                    Button { viewModel.seekForward() } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 10 seconds")
                    .accessibilityIdentifier("trimato.editor.skip-forward")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .skipForward)
                    Button { viewModel.stepForward() } label: {
                        Image(systemName: "forward.frame.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Step forward one frame")
                    .accessibilityIdentifier("trimato.editor.step-forward")
                    .accessibilityFocused($focusedAccessibilityTarget, equals: .stepForward)
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
