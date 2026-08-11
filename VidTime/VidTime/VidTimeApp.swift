import SwiftUI

@main
struct VidTimeApp: App {
    @FocusedObject private var viewModel: VideoPlayerViewModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About vidTime") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    viewModel?.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Export Trimmed Clip\u{2026}") {
                    viewModel?.exportTrimmedClip()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel?.canExport != true)
                if viewModel?.isExporting == true {
                    Button("Cancel Export") { viewModel?.cancelExport() }
                }
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

        Window("About vidTime", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("FFmpeg License", id: "ffmpeg-license") {
            FFmpegLicenseView()
        }
        .defaultSize(width: 720, height: 600)
    }
}
