import AppKit
import Combine
@testable import Trimato

@main struct MixerPresentationCheck {
    @MainActor static func main() async {
        precondition(NSApp == nil)
        let player = ProjectPlayerViewModel()
        let presentation = MixerPlaybackPresentation(player: player)
        // Let the initial AVPlayer rate observation settle before advancing time.
        try? await Task.sleep(for: .milliseconds(100))
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        let spoken = player.accessibilityTimecodeLabel
        var playerUpdates = 0
        let playerObservation = player.objectWillChange.sink { playerUpdates += 1 }
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject(name: "Clock check")))
        var workspaceUpdates = 0
        let workspaceObservation = controller.objectWillChange.sink { workspaceUpdates += 1 }
        for tick in 1...300 {
            let time = ProjectTime(seconds: Double(tick) / 10)
            player.playbackClock.update(time, frameRate: 30)
            controller.updatePlaybackPosition(time, isPlaying: true)
            await Task.yield()
        }
        precondition(player.currentTime.seconds == 30 && player.currentFrame == 900)
        precondition(controller.timelinePlayhead.seconds == 30)
        precondition(player.accessibilityTimecodeLabel == spoken)
        precondition(playerUpdates == 0 && workspaceUpdates == 0)
        player.refreshAccessibilityValueForFocus()
        controller.updatePlaybackPosition(ProjectTime(seconds: 30.1), isPlaying: false)
        precondition(player.accessibilityTimecodeLabel != spoken && workspaceUpdates == 1)
        withExtendedLifetime((playerObservation, workspaceObservation)) {}

        try? await Task.sleep(for: .milliseconds(100))
        precondition(updates == 1, "Only the explicit spoken value refresh should invalidate Mixer controls")
        let focusedValue = player.accessibilityTimecodeLabel
        player.playbackClock.update(ProjectTime(seconds: 35), frameRate: 30)
        precondition(player.accessibilityTimecodeLabel == focusedValue, "Continuous focus must stay quiet")
        let requestedValue = player.currentTimecodeForAnnouncement
        precondition(requestedValue != focusedValue, "T must read the advancing clock, not the saved accessible value")
        precondition(player.accessibilityTimecodeLabel == focusedValue, "Reading T's message must not change the slider value")
        player.refreshAccessibilityValueForFocus()
        precondition(player.accessibilityTimecodeLabel == requestedValue, "Returning focus must refresh the value")
        player.playbackClock.update(ProjectTime(seconds: 36), frameRate: 30)
        precondition(player.accessibilityTimecodeLabel == requestedValue, "Ticks after focus returns must stay quiet")
        precondition(ProjectPlayerViewModel.recognizesEditorKeyboardCommand(type: .keyDown, keyCode: 17, character: "t", modifiers: []))
        precondition(!ProjectPlayerViewModel.recognizesEditorKeyboardCommand(type: .keyDown, keyCode: 17, character: "t", modifiers: [.control, .option]))
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 5)))
        let first = TimelineClip(assetID: UUID(), name: "First", segments: [segment])
        var second = TimelineClip(assetID: UUID(), name: "Second", segments: [segment])
        second.timelineStart = ProjectTime(seconds: 5)
        var project = TrimatoProject(name: "Boundary check")
        let track = TimelineTrack(name: "Audio", kind: .audio, clips: [first, second])
        project.tracks = [track]
        let boundaries = ProjectController(document: ProjectDocument(project: project))
        boundaries.activeTimelineTrackID = track.id
        var boundaryUpdates = 0
        let boundaryObservation = boundaries.objectWillChange.sink { boundaryUpdates += 1 }
        for tick in 1...49 { boundaries.updatePlaybackPosition(ProjectTime(seconds: Double(tick) / 10), isPlaying: true) }
        precondition(boundaryUpdates == 0)
        boundaries.updatePlaybackPosition(ProjectTime(seconds: 5), isPlaying: true)
        precondition(boundaryUpdates == 1 && boundaries.currentTimelineClip(at: boundaries.timelinePlayhead)?.id == second.id)
        boundaries.updatePlaybackPosition(ProjectTime(seconds: 5.1), isPlaying: true)
        precondition(boundaryUpdates == 1)
        precondition(NSApp == nil)
        withExtendedLifetime((observation, boundaryObservation)) {}
        print("PASS: 300 advancing clock ticks preserved workspace and Mixer controls, explicit focus and current-time requests use fresh values without tick announcements, no application created")
    }
}
