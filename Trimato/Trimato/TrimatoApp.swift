import AppKit
import SwiftUI

@main
struct TrimatoApp: App {
    @NSApplicationDelegateAdaptor(TrimatoApplicationDelegate.self) private var appDelegate
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @FocusedObject private var projectPlayer: ProjectPlayerViewModel?
    @FocusedObject private var projectController: ProjectController?
    @FocusedObject private var clipPlacement: ClipPlacementCommandContext?
    @Environment(\.openWindow) private var openWindow

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
            FeedbackCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Trimato") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Delete Selection (Delete)") {
                    if projectController?.selectedTimelineClip != nil || projectController?.selectedCutaway != nil || projectController?.selectedTransition != nil {
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
                )
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
                .disabled(projectPlayer?.inMarker == nil && viewModel?.inMarker == nil)
                Button("Clear Out") {
                    if let projectPlayer { projectPlayer.clearOut() }
                    else { viewModel?.clearOut() }
                }
                .disabled(projectPlayer?.outMarker == nil && viewModel?.outMarker == nil)
            }
            CommandMenu("Clip") {
                Button("Update Clip") { clipPlacement?.performUpdate() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(clipPlacement?.canUpdate != true)
                Divider()
                Button(PlacementAction.append.title) { clipPlacement?.place(.append) }
                    .keyboardShortcut("e", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Button("Append to Track…") { clipPlacement?.requestTrackPlacement(.append) }
                    .keyboardShortcut("e", modifiers: [.option])
                    .disabled(clipPlacement?.canPlace != true)
                Button(PlacementAction.insert.title) { clipPlacement?.place(.insert) }
                    .keyboardShortcut("w", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Button("Insert on Track…") { clipPlacement?.requestTrackPlacement(.insert) }
                    .keyboardShortcut("w", modifiers: [.option])
                    .disabled(clipPlacement?.canPlace != true)
                Button(PlacementAction.replaceRemainder.title) { clipPlacement?.place(.replaceRemainder) }
                    .keyboardShortcut("d", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Button("Insert and Overwrite on Track…") { clipPlacement?.requestTrackPlacement(.replaceRemainder) }
                    .keyboardShortcut("d", modifiers: [.option])
                    .disabled(clipPlacement?.canPlace != true)
                Divider()
                Button(PlacementAction.cutawaySourceAudio.title) {
                    clipPlacement?.place(.cutawaySourceAudio)
                }
                .keyboardShortcut("q", modifiers: [])
                .disabled(
                    clipPlacement?.canPlace != true ||
                        clipPlacement.flatMap { $0.controller.asset(for: $0.editSelection) }?.hasVideo != true
                )
                Button(PlacementAction.cutawayPrimaryAudio.title) {
                    clipPlacement?.place(.cutawayPrimaryAudio)
                }
                .keyboardShortcut("q", modifiers: [.option])
                .disabled(
                    clipPlacement?.canPlace != true ||
                        clipPlacement.flatMap { $0.controller.asset(for: $0.editSelection) }?.hasVideo != true
                )
            }
            CommandMenu("Timeline") {
                Button("Blade at Playhead (Command-B)") { projectController?.splitClipAtPlayhead() }
                    .disabled(projectController?.project.primaryTimeline.isEmpty != false)
                Button("Add Transition…") { projectController?.requestTransitionForSelection() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(projectController?.project.tracks.contains(where: { !$0.clips.isEmpty }) != true)
                Divider()
                Button("Previous Track") { projectController?.selectAdjacentTrack(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(projectController?.project.tracks.isEmpty != false)
                Button("Next Track") { projectController?.selectAdjacentTrack(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(projectController?.project.tracks.isEmpty != false)
                Divider()
                Menu("Move To…") {
                    ForEach(TimelineMoveDestination.allCases, id: \.self) { destination in
                        Button(destination.title) {
                            guard let controller = projectController, let target = controller.selectedTimelineClip else { return }
                            controller.moveClip(to: destination, targetID: target.id)
                        }
                        .disabled(projectController?.selectedTimelineClip.map { clip in
                            projectController?.canMoveClip(to: destination, targetID: clip.id) != true
                        } ?? true)
                    }
                }
                Button("Move Clip Earlier") { projectController?.moveSelectedClip(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(projectController?.selectedTimelineClip == nil)
                Button("Move Clip Later") { projectController?.moveSelectedClip(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(projectController?.selectedTimelineClip == nil)
                Toggle("Mute Track", isOn: Binding(
                    get: { projectController?.activeTimelineTrack?.isMuted ?? false },
                    set: { projectController?.setActiveTrackMuted($0) }
                ))
                .disabled(projectController?.activeTimelineTrack?.kind != .audio)
            }
        }

        WindowGroup("Clip Editor", for: URL.self) { $url in
            if let url {
                StandaloneClipEditorView(url: url)
            }
        }
        .handlesExternalEvents(matching: ExternalMediaOpenCoordinator.mediaExternalEventConditions)
        .defaultSize(width: 940, height: 760)

        Window("About Trimato", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            MediaCacheSettingsView()
        }

        Window("FFmpeg License", id: "ffmpeg-license") {
            FFmpegLicenseView()
        }
        .defaultSize(width: 720, height: 600)
    }
}

private final class TrimatoApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Task { @MainActor in
            await ExportNotificationCenter.requestAuthorizationIfNeeded()
        }
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private struct ProjectFileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var projectController: ProjectController?
    @FocusedObject private var clipPlacement: ClipPlacementCommandContext?
    @ObservedObject private var activeProjects = ExternalMediaOpenCoordinator.shared

    private var controller: ProjectController? {
        projectController ?? clipPlacement?.controller ?? activeProjects.activeProjectController
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                ProjectLauncherNavigation.shared.showProjectCreation()
                openWindow(id: "project-launcher")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
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
            Button("Import Media\u{2026}") { controller?.importFiles() }
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
    @FocusedObject private var clipPlacement: ClipPlacementCommandContext?
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
            Divider()
            Button("Send Trimato Feedback\u{2026}") {
                guard let url = TrimatoFeedback.emailURL else { return }
                openURL(url)
            }
        }
    }
}
