import AppKit
import SwiftUI

nonisolated enum ProjectCommandContext {
    static func resolve<Project>(focused: Project?, active: Project?) -> Project? {
        focused ?? active
    }
}

@main
struct TrimatoApp: App {
    @NSApplicationDelegateAdaptor(TrimatoApplicationDelegate.self) private var appDelegate
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @FocusedObject private var projectPlayer: ProjectPlayerViewModel?
    @FocusedObject private var projectController: ProjectController?
    @ObservedObject private var activeProjects = ExternalMediaOpenCoordinator.shared
    @Environment(\.openWindow) private var openWindow

    private var projectCommandController: ProjectController? {
        ProjectCommandContext.resolve(
            focused: projectController,
            active: activeProjects.activeProjectController
        )
    }

    var body: some Scene {
        Window("Trimato", id: "project-launcher") {
            ProjectLauncherView()
                .handlesTrimatoMediaOpening()
        }
        .defaultSize(width: 560, height: 680)
        .windowResizability(.contentSize)

        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            EditorWorkspaceView(document: file.document)
        }
        .commands {
            ProjectFileCommands()
            ContextualExportCommands()
            GetInfoCommands()
            FeedbackCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Trimato") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Delete Selection (Delete)") {
                    if projectController?.selectedCaptionCue != nil {
                        projectController?.deleteSelectedCaptionCue()
                    } else if projectController?.selectedTimelineClip != nil || projectController?.selectedCutaway != nil || projectController?.selectedTransition != nil {
                        projectController?.deleteSelection()
                    } else {
                        viewModel?.deleteSelection()
                    }
                }
                .disabled(
                    viewModel?.canDeleteSelection != true &&
                    projectController?.selectedTimelineClip == nil &&
                    projectController?.selectedCutaway == nil &&
                    projectController?.selectedTransition == nil
                    && projectController?.selectedCaptionCue == nil
                )
            }
            CommandMenu("Playback") {
                Button("Play or Pause (Space)") {
                    if let projectPlayer { projectPlayer.togglePlayback() }
                    else { viewModel?.togglePlayPause() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Play Backward (J)") {
                    if let projectPlayer { projectPlayer.pressJ() }
                    else { viewModel?.pressJ() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Play or Pause (K)") {
                    if let projectPlayer { projectPlayer.pressK() }
                    else { viewModel?.pressK() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Play Forward (L)") {
                    if let projectPlayer { projectPlayer.pressL() }
                    else { viewModel?.pressL() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Divider()
                Button("Step Backward (Left Arrow)") {
                    if let projectPlayer { projectPlayer.stepBackward() }
                    else { viewModel?.stepBackward() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Step Forward (Right Arrow)") {
                    if let projectPlayer { projectPlayer.stepForward() }
                    else { viewModel?.stepForward() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Divider()
                Button("Previous Edit Point (Command-Left Arrow)") {
                    if let projectPlayer { projectPlayer.goToPreviousEdit() }
                    else { viewModel?.goToPreviousTimelinePoint() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Next Edit Point (Command-Right Arrow)") {
                    if let projectPlayer { projectPlayer.goToNextEdit() }
                    else { viewModel?.goToNextTimelinePoint() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Go to Beginning (Command-Up Arrow)") {
                    if let projectPlayer { projectPlayer.goToStart() }
                    else { viewModel?.goToStart() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Go to End (Command-Down Arrow)") {
                    if let projectPlayer { projectPlayer.goToEnd() }
                    else { viewModel?.goToEnd() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasMedia != true)
                Button("Go to End of Video") {
                    projectPlayer?.goToVideoEnd()
                }
                .disabled(projectPlayer?.canControlPlayback != true)
            }
            CommandMenu("Markers") {
                Button("Mark In (I)") {
                    if let projectPlayer { projectPlayer.markIn() }
                    else { viewModel?.markIn() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasMedia != true || viewModel?.isExporting == true))
                Button("Mark Out (O)") {
                    if let projectPlayer { projectPlayer.markOut() }
                    else { viewModel?.markOut() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasMedia != true || viewModel?.isExporting == true))
                Divider()
                Button("Clear In") {
                    if let projectPlayer { projectPlayer.clearIn() }
                    else { viewModel?.clearIn() }
                }
                .keyboardShortcut("i", modifiers: .option)
                .disabled(projectPlayer?.inMarker == nil && viewModel?.inMarker == nil)
                Button("Clear Out") {
                    if let projectPlayer { projectPlayer.clearOut() }
                    else { viewModel?.clearOut() }
                }
                .keyboardShortcut("o", modifiers: .option)
                .disabled(projectPlayer?.outMarker == nil && viewModel?.outMarker == nil)
            }
            ClipPlacementCommands()
            CommandMenu("Timeline") {
                Button("Generator…") { projectCommandController?.requestGenerator() }
                    .disabled(projectCommandController == nil)
                Divider()
                Button("Blade at Playhead") { projectCommandController?.splitClipAtPlayhead() }
                    .disabled(projectCommandController?.project.primaryTimeline.isEmpty != false)
                Button("Trim Start to Playhead") {
                    if let projectPlayer { projectPlayer.trimActiveClipStartToPlayhead() }
                    else { viewModel?.trimStartToPlayhead() }
                }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(projectPlayer?.canControlPlayback != true && viewModel?.canTrimStart != true)
                Button("Trim End from Playhead") {
                    if let projectPlayer { projectPlayer.trimActiveClipEndToPlayhead() }
                    else { viewModel?.trimEndFromPlayhead() }
                }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(projectPlayer?.canControlPlayback != true && viewModel?.canTrimEnd != true)
                Button("Add Transition…") { projectCommandController?.requestTransitionForSelection() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(projectCommandController?.project.tracks.contains(where: { !$0.clips.isEmpty }) != true)
                Divider()
                Button("Describer…") { projectCommandController?.requestRecording(.audioDescription) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(projectCommandController == nil)
                Button("Voicer…") { projectCommandController?.requestRecording(.voiceOver) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(projectCommandController == nil)
                Button("Export Description Transcript…") { projectCommandController?.exportDescriptions() }
                    .disabled(projectCommandController?.project.descriptionTranscriptTrack?.captionCues.isEmpty != false)
                Menu("Captions") {
                    Button("New Caption…") { projectCommandController?.requestCaptionEditor() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .disabled(projectCommandController?.canCreateCaption != true)
                    Button("Finalize Captions") { projectCommandController?.finalizeCaptions() }
                        .disabled(projectCommandController?.canFinalizeCaptions != true)
                    Button("Export Captions…") { projectCommandController?.exportCaptions() }
                        .disabled(projectCommandController?.project.captionTrack?.captionCues.isEmpty != false)
                }
                Divider()
                Button("Previous Track") { projectCommandController?.selectAdjacentTrack(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(projectCommandController?.project.tracks.isEmpty != false)
                Button("Next Track") { projectCommandController?.selectAdjacentTrack(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(projectCommandController?.project.tracks.isEmpty != false)
                Divider()
                Menu("Move To…") {
                    ForEach(TimelineMoveDestination.allCases, id: \.self) { destination in
                        Button(destination.title) {
                            guard let controller = projectCommandController,
                                  let target = controller.selectedTimelineClip else { return }
                            controller.moveClip(to: destination, targetID: target.id)
                        }
                        .disabled(projectCommandController?.selectedTimelineClip.map { clip in
                            projectCommandController?.canMoveClip(to: destination, targetID: clip.id) != true
                        } ?? true)
                    }
                }
                Button("Move Clip Earlier") { projectCommandController?.moveSelectedClip(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(projectCommandController?.selectedTimelineClip == nil)
                Button("Move Clip Later") { projectCommandController?.moveSelectedClip(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(projectCommandController?.selectedTimelineClip == nil)
                Toggle("Mute Track", isOn: Binding(
                    get: { projectCommandController?.activeTimelineTrack?.isMuted ?? false },
                    set: { projectCommandController?.setActiveTrackMuted($0) }
                ))
                .disabled(projectCommandController?.activeTimelineTrack?.kind != .audio)
            }
        }

        WindowGroup("Recording", id: "recording", for: UUID.self) { $id in
            if let id { RecordingWindowContent(id: id) }
        }
        .windowResizability(.contentSize)

        WindowGroup("Clip Editor", for: ExternalMediaOpenRequest.self) { $request in
            if let request {
                StandaloneClipEditorView(request: request)
            }
        }
        .defaultSize(width: 940, height: 760)
        .commandsReplaced {
            ProjectFileCommands()
        }

        Window("About Trimato", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        WindowGroup("Get Info", id: "get-info", for: ProjectInfoSnapshot.self) { $snapshot in
            if let snapshot {
                ProjectInfoView(snapshot: snapshot)
            }
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            TrimatoSettingsView()
        }

        Window("FFmpeg License", id: "ffmpeg-license") {
            FFmpegLicenseView()
        }
        .defaultSize(width: 720, height: 600)
        .commandsRemoved()
    }
}

private struct GetInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var projectController: ProjectController?
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @ObservedObject private var clipCommands = ClipEditorCommandRouter.shared
    @ObservedObject private var activeProjects = ExternalMediaOpenCoordinator.shared

    private var snapshot: ProjectInfoSnapshot? {
        if let context = clipCommands.activeContext {
            return context.controller.projectInfoSnapshot(selection: context.editSelection)
        }
        if let projectController {
            return projectController.projectInfoSnapshot()
        }
        if let viewModel {
            let filename = viewModel.sourceFilename ?? "Clip"
            return ProjectInfoSnapshot(title: "\(filename) Info", rows: [
                ProjectInfoRow("Current Time", ProjectInfoTimeFormatter.string(ProjectTime(seconds: viewModel.currentTime))),
                ProjectInfoRow("Length", ProjectInfoTimeFormatter.string(ProjectTime(seconds: viewModel.duration)))
            ])
        }
        return activeProjects.activeProjectController?.projectInfoSnapshot()
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") {
                if let context = clipCommands.activeContext {
                    Task { @MainActor in
                        let snapshot = await context.controller.projectInfoSnapshotWithTechnicalDetails(
                            selection: context.editSelection
                        )
                        openWindow(id: "get-info", value: snapshot)
                    }
                } else if let projectController {
                    Task { @MainActor in
                        let snapshot = await projectController.projectInfoSnapshotWithTechnicalDetails()
                        openWindow(id: "get-info", value: snapshot)
                    }
                } else if let snapshot {
                    openWindow(id: "get-info", value: snapshot)
                }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(snapshot == nil)
        }
    }
}

private struct ClipPlacementCommands: Commands {
    @ObservedObject private var clipCommands = ClipEditorCommandRouter.shared

    var body: some Commands {
        CommandMenu("Clip") {
            ForEach(ClipEditorPlacementCommand.allCases) { command in
                if command == .append || command == .insertOnTopWithAudio { Divider() }
                Button(command.title) { clipCommands.perform(command) }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(!clipCommands.isAvailable(command))
            }
        }
    }
}

private final class TrimatoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let documents = SingleProjectCoordinator.shared
    private var projectCommandMonitor: Any?
    private var quitPending = false

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "trimato" {
            documents.openDocument(at: url)
        }
        ExternalMediaOpenCoordinator.shared.receive(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let project = ExternalMediaOpenCoordinator.shared.activeProjectController else { return .terminateNow }
        guard !quitPending else { return .terminateLater }
        quitPending = true
        Task { @MainActor [weak self] in
            project.closeProjectForQuit { closed in
                self?.quitPending = false
                sender.reply(toApplicationShouldTerminate: closed)
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        documents.refreshRecentProjects()
        projectCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                ProjectSaveKeyboard.handle(event, controller: ExternalMediaOpenCoordinator.shared.activeProjectController)
            }
        }
        guard !Self.isRunningTests else { return }
        Task { @MainActor in
            await AudioInputManager.requestPermissionIfNeeded()
            await ExportNotificationCenter.requestAuthorizationIfNeeded()
        }
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private struct ProjectFileCommands: Commands {
    @ObservedObject private var projectOpening = SingleProjectCoordinator.shared
    @FocusedValue(\.closeRecording) private var closeRecording
    @FocusedValue(\.closeSettings) private var closeSettings
    @FocusedObject private var standaloneContext: StandaloneClipCommandContext?
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var projectController: ProjectController?
    @ObservedObject private var clipCommands = ClipEditorCommandRouter.shared
    private var clipPlacement: ClipPlacementCommandContext? { clipCommands.activeContext }
    @ObservedObject private var activeProjects = ExternalMediaOpenCoordinator.shared

    private var controller: ProjectController? {
        projectController ?? clipPlacement?.controller ?? activeProjects.activeProjectController
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                ProjectLauncherNavigation.shared.showProjectCreation {
                    openWindow(id: "project-launcher")
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Open Project…") { SingleProjectCoordinator.shared.chooseProject() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(projectOpening.recentURLs, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        SingleProjectCoordinator.shared.openDocument(at: url)
                    }
                }
            }

        }
        CommandGroup(replacing: .saveItem) {
            Button(closeSettings != nil ? "Close Settings" : (closeRecording != nil ? controller?.recordingSession.map { "Close \($0.purpose.toolTitle)" } : nil) ?? (controller?.isCaptionEditorOpen == true ? "Close Caption Editor" : (clipPlacement?.isKeyWindow == true || standaloneContext != nil ? "Close Clip Editor" : "Close Project"))) {
                if let closeSettings {
                    closeSettings()
                } else if let closeRecording {
                    closeRecording()
                } else if controller?.isCaptionEditorOpen == true {
                    controller?.closeCaptionEditor()
                } else {
                    if let standaloneContext { standaloneContext.close() }
                    else if let window = clipPlacement?.hostWindow, clipPlacement?.isKeyWindow == true { window.performClose(nil) }
                    else { controller?.closeProject() }
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(closeRecording == nil && closeSettings == nil && controller?.isCaptionEditorOpen != true && clipPlacement?.isKeyWindow != true && standaloneContext == nil && controller == nil)
            Divider()
            Button("Save") { controller?.saveProjectDocument() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(controller == nil)
            Button("Save As\u{2026}") { controller?.saveProjectDocumentAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Divider()
            Button("Close Project") { controller?.closeProject() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(controller == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Import Files\u{2026}") { controller?.importFiles() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(controller == nil || controller?.isImporting == true)
        }
    }
}

nonisolated enum ExportCommandDestination: Equatable {
    case project
    case standaloneClip
    case unavailable

    static func resolve(
        hasFocusedProject: Bool,
        hasProjectClipContext: Bool,
        hasStandaloneClip: Bool,
        hasActiveProject: Bool
    ) -> Self {
        if hasFocusedProject || hasProjectClipContext { return .project }
        if hasStandaloneClip { return .standaloneClip }
        if hasActiveProject { return .project }
        return .unavailable
    }
}

private struct ContextualExportCommands: Commands {
    @FocusedObject private var projectController: ProjectController?
    @ObservedObject private var clipCommands = ClipEditorCommandRouter.shared
    private var clipPlacement: ClipPlacementCommandContext? { clipCommands.activeContext }
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @FocusedObject private var projectCreation: StandaloneClipCommandContext?
    @ObservedObject private var activeProjects = ExternalMediaOpenCoordinator.shared

    private var destination: ExportCommandDestination {
        ExportCommandDestination.resolve(
            hasFocusedProject: projectController != nil,
            hasProjectClipContext: clipPlacement != nil,
            hasStandaloneClip: viewModel != nil,
            hasActiveProject: activeProjects.activeProjectController != nil
        )
    }

    private var project: ProjectController? {
        projectController ?? clipPlacement?.controller ?? activeProjects.activeProjectController
    }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            if destination == .standaloneClip {
                Button("Create Project from Clip") { projectCreation?.createProject() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(projectCreation?.canCreateProject != true)
            }
            if destination == .project {
                Button("Project Settings\u{2026}") { project?.showProjectSettings() }
                    .disabled(project == nil)
            }
        }
        CommandGroup(replacing: .importExport) {
            switch destination {
            case .project:
                Button("Export Project\u{2026}") { project?.exportProject() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(project?.canExportProject != true)
                if project?.isExporting == true {
                    Button("Cancel Project Export") { project?.cancelExport() }
                }
            case .standaloneClip:
                Button("Export Clip\u{2026}") { viewModel?.exportTrimmedClip() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(viewModel?.canExport != true)
                if viewModel?.isExporting == true {
                    Button("Cancel Clip Export") { viewModel?.cancelExport() }
                }
            case .unavailable:
                Button("Export\u{2026}") {}
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(true)
            }
        }
    }
}

nonisolated enum TrimatoFeedback {
    static let recipient = "marco@marconius.com"
    static let subject = "Trimato Feedback"

    static var emailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return components.url
    }
}

private struct FeedbackCommands: Commands {
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Send Trimato Feedback\u{2026}") {
                guard let url = TrimatoFeedback.emailURL else { return }
                openURL(url)
            }
        }
    }
}
