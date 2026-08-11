import SwiftUI

@main
struct VidTimeApp: App {
    @FocusedObject private var viewModel: VideoPlayerViewModel?

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    viewModel?.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
