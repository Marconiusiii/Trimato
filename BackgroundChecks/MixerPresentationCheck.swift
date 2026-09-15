import AppKit
import Combine
@testable import Trimato

@main struct MixerPresentationCheck {
    @MainActor static func main() async {
        precondition(NSApp == nil)
        let player = ProjectPlayerViewModel()
        let presentation = MixerPlaybackPresentation(player: player)
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        // Simulate repeated clock notifications without opening a window,
        // loading media, starting playback, or posting accessibility speech.
        for _ in 0..<300 {
            player.objectWillChange.send()
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(100))
        precondition(updates == 0, "Unchanged control state invalidated Mixer controls")
        precondition(NSApp == nil)
        withExtendedLifetime(observation) {}
        print("PASS: 300 clock-only notifications did not invalidate Mixer controls; no application created")
    }
}
