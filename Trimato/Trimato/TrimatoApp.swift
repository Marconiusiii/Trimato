import SwiftUI

@main
struct TrimatoApp: App {
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @FocusedObject private var projectController: ProjectController?
    @FocusedObject private var clipPlacement: ClipPlacementCommandContext?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            EditorWorkspaceView(document: file.document)
        }
        .commands {
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
                        : projectController?.project.primaryTimeline.isEmpty != false || projectController?.isExporting == true
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
                Button("Split Clip at Playhead") { projectController?.splitSelectedClip() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(projectController?.selectedTimelineClip == nil)
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
            CommandMenu("Clip") {
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

        Window("About Trimato", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("FFmpeg License", id: "ffmpeg-license") {
            FFmpegLicenseView()
        }
        .defaultSize(width: 720, height: 600)
    }
}
