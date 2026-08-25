import SwiftUI

@main
struct TrimatoApp: App {
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
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    (projectController ?? clipPlacement?.controller)?.saveProjectDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(projectController == nil && clipPlacement == nil)
                Button("Save As\u{2026}") {
                    (projectController ?? clipPlacement?.controller)?.saveProjectDocumentAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(projectController == nil && clipPlacement == nil)
                Divider()
                Button("Close Project") {
                    (projectController ?? clipPlacement?.controller)?.closeProject()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(projectController == nil && clipPlacement == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Trimato") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .newItem) {
                Button("Import Media\u{2026}") { projectController?.importFiles() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(projectController == nil || projectController?.isImporting == true)
            }
            CommandGroup(after: .saveItem) {
                Button("Project Settings\u{2026}") {
                    (projectController ?? clipPlacement?.controller)?.showProjectSettings()
                }
                .disabled(projectController == nil && clipPlacement == nil)
                Divider()
                Button(viewModel?.hasVideo == true ? "Export Clip\u{2026}" : "Export Project\u{2026}") {
                    if viewModel?.hasVideo == true {
                        viewModel?.exportTrimmedClip()
                    } else {
                        projectController?.exportProject()
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(
                    viewModel?.hasVideo == true
                        ? viewModel?.canExport != true
                        : projectController?.canExportProject != true
                )
                if viewModel?.isExporting == true {
                    Button("Cancel Clip Export") { viewModel?.cancelExport() }
                } else if projectController?.isExporting == true {
                    Button("Cancel Project Export") { projectController?.cancelExport() }
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Delete Selection (Delete)") {
                    if projectController?.selectedTimelineClip != nil || projectController?.selectedCutaway != nil {
                        projectController?.deleteSelection()
                    } else {
                        viewModel?.deleteSelection()
                    }
                }
                .disabled(
                    viewModel?.canDeleteSelection != true &&
                    projectController?.selectedTimelineClip == nil &&
                    projectController?.selectedCutaway == nil
                )
                Button("Trim Start to Playhead") { viewModel?.trimStartToPlayhead() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(viewModel?.canTrimStart != true)
                Button("Trim End from Playhead") { viewModel?.trimEndFromPlayhead() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(viewModel?.canTrimEnd != true)
            }
            CommandMenu("Project Timeline") {
                Button("Blade at Playhead (Command-B)") { projectController?.splitClipAtPlayhead() }
                    .disabled(projectController?.project.primaryTimeline.isEmpty != false)
                Divider()
                Button("Move Clip to Beginning") { projectController?.moveSelectedClipToBeginning() }
                    .disabled(projectController?.selectedTimelineClip == nil)
                Button("Move Clip Earlier") { projectController?.moveSelectedClip(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(projectController?.selectedTimelineClip == nil)
                Button("Move Clip Later") { projectController?.moveSelectedClip(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(projectController?.selectedTimelineClip == nil)
                Button("Move Clip to End") { projectController?.moveSelectedClipToEnd() }
                    .disabled(projectController?.selectedTimelineClip == nil)
            }
            CommandMenu("Playback") {
                Button("Play or Pause (Space)") {
                    if let projectPlayer { projectPlayer.togglePlayback() }
                    else { viewModel?.togglePlayPause() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Play Backward (J)") {
                    if let projectPlayer { projectPlayer.pressJ() }
                    else { viewModel?.pressJ() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Play or Pause (K)") {
                    if let projectPlayer { projectPlayer.pressK() }
                    else { viewModel?.pressK() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Play Forward (L)") {
                    if let projectPlayer { projectPlayer.pressL() }
                    else { viewModel?.pressL() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
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
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Next Edit Point (Command-Right Arrow)") {
                    if let projectPlayer { projectPlayer.goToNextEdit() }
                    else { viewModel?.goToNextTimelinePoint() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Go to Beginning (Command-Up Arrow)") {
                    if let projectPlayer { projectPlayer.goToStart() }
                    else { viewModel?.goToStart() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
                Button("Go to End (Command-Down Arrow)") {
                    if let projectPlayer { projectPlayer.goToEnd() }
                    else { viewModel?.goToEnd() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && viewModel?.hasVideo != true)
            }
            CommandMenu("Clip") {
                Button("Update Clip") { clipPlacement?.performUpdate() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(clipPlacement?.canUpdate != true)
                Divider()
                Button(PlacementAction.append.title) { clipPlacement?.place(.append) }
                    .keyboardShortcut("e", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Button(PlacementAction.insert.title) { clipPlacement?.place(.insert) }
                    .keyboardShortcut("w", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Button(PlacementAction.replaceRemainder.title) { clipPlacement?.place(.replaceRemainder) }
                    .keyboardShortcut("d", modifiers: [])
                    .disabled(clipPlacement?.canPlace != true)
                Divider()
                Button(PlacementAction.cutawaySourceAudio.title) {
                    clipPlacement?.place(.cutawaySourceAudio)
                }
                .keyboardShortcut("q", modifiers: [])
                .disabled(clipPlacement?.canPlace != true)
                Button(PlacementAction.cutawayPrimaryAudio.title) {
                    clipPlacement?.place(.cutawayPrimaryAudio)
                }
                .keyboardShortcut("q", modifiers: [.option])
                .disabled(clipPlacement?.canPlace != true)
            }
            CommandMenu("Markers") {
                Button("Mark In (I)") {
                    if let projectPlayer { projectPlayer.markIn() }
                    else { viewModel?.markIn() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
                Button("Mark Out (O)") {
                    if let projectPlayer { projectPlayer.markOut() }
                    else { viewModel?.markOut() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
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
                Divider()
                Button("Previous Timeline Point (Command-Left Arrow)") {
                    if let projectPlayer { projectPlayer.goToPreviousEdit() }
                    else { viewModel?.goToPreviousTimelinePoint() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
                Button("Next Timeline Point (Command-Right Arrow)") {
                    if let projectPlayer { projectPlayer.goToNextEdit() }
                    else { viewModel?.goToNextTimelinePoint() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
                Button("Go to Start (Command-Up Arrow)") {
                    if let projectPlayer { projectPlayer.goToStart() }
                    else { viewModel?.goToStart() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
                Button("Go to End (Command-Down Arrow)") {
                    if let projectPlayer { projectPlayer.goToEnd() }
                    else { viewModel?.goToEnd() }
                }
                .disabled(projectPlayer?.canControlPlayback != true && (viewModel?.hasVideo != true || viewModel?.isExporting == true))
            }
        }

        WindowGroup("Clip Editor", for: URL.self) { $url in
            if let url {
                StandaloneClipEditorView(url: url)
                    .handlesTrimatoMediaOpening()
            }
        }
        .defaultSize(width: 940, height: 760)
        .commands {
            StandaloneClipCommands()
        }

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

private struct StandaloneClipCommands: Commands {
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @FocusedObject private var projectCreation: StandaloneClipCommandContext?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Trimato") { openWindow(id: "about") }
        }
        CommandGroup(after: .newItem) {
            Button("Create Project from Clip") { projectCreation?.createProject() }
                .disabled(projectCreation?.canCreateProject != true)
        }
        CommandGroup(after: .saveItem) {
            Button("Export Clip…") { viewModel?.exportTrimmedClip() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel?.canExport != true)
            if viewModel?.isExporting == true {
                Button("Cancel Clip Export") { viewModel?.cancelExport() }
            }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Selection (Delete)") { viewModel?.deleteSelection() }
                .disabled(viewModel?.canDeleteSelection != true)
            Button("Trim Start to Playhead") { viewModel?.trimStartToPlayhead() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(viewModel?.canTrimStart != true)
            Button("Trim End from Playhead") { viewModel?.trimEndFromPlayhead() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(viewModel?.canTrimEnd != true)
        }
        CommandMenu("Playback") {
            Button("Play or Pause (Space)") { viewModel?.togglePlayPause() }
                .disabled(viewModel?.hasVideo != true)
            Button("Play Backward (J)") { viewModel?.pressJ() }
                .disabled(viewModel?.hasVideo != true)
            Button("Play or Pause (K)") { viewModel?.pressK() }
                .disabled(viewModel?.hasVideo != true)
            Button("Play Forward (L)") { viewModel?.pressL() }
                .disabled(viewModel?.hasVideo != true)
            Divider()
            Button("Step Backward (Left Arrow)") { viewModel?.stepBackward() }
                .disabled(viewModel?.hasVideo != true)
            Button("Step Forward (Right Arrow)") { viewModel?.stepForward() }
                .disabled(viewModel?.hasVideo != true)
        }
        CommandMenu("Markers") {
            Button("Mark In (I)") { viewModel?.markIn() }
                .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
            Button("Mark Out (O)") { viewModel?.markOut() }
                .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
            Divider()
            Button("Clear In") { viewModel?.clearIn() }
                .disabled(viewModel?.inMarker == nil)
            Button("Clear Out") { viewModel?.clearOut() }
                .disabled(viewModel?.outMarker == nil)
            Divider()
            Button("Previous Timeline Point (Command-Left Arrow)") {
                viewModel?.goToPreviousTimelinePoint()
            }
            .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
            Button("Next Timeline Point (Command-Right Arrow)") {
                viewModel?.goToNextTimelinePoint()
            }
            .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
            Button("Go to Start (Command-Up Arrow)") { viewModel?.goToStart() }
                .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
            Button("Go to End (Command-Down Arrow)") { viewModel?.goToEnd() }
                .disabled(viewModel?.hasVideo != true || viewModel?.isExporting == true)
        }
    }
}
