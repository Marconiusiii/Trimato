import SwiftUI

@main
struct TrimatoApp: App {
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Trimato") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    viewModel?.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel?.isLoadingMedia == true)
            }
            CommandGroup(after: .saveItem) {
                Button("Export Clip\u{2026}") {
                    viewModel?.exportTrimmedClip()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel?.canExport != true)
                if viewModel?.isExporting == true {
                    Button("Cancel Export") { viewModel?.cancelExport() }
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
