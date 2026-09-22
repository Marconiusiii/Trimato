import AppKit
import Combine
@testable import Trimato

@main struct MixerPresentationCheck {
    @MainActor static func main() async {
        precondition(NSApp == nil)
        checkFocusRouting()
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
        precondition(player.accessibilityTimecodeLabel == focusedValue, "Clock ticks must not change the saved accessible value")
        let requestedValue = player.currentTimecodeForAnnouncement
        precondition(requestedValue != focusedValue, "T must read the advancing clock, not the saved accessible value")
        precondition(player.accessibilityTimecodeLabel == focusedValue, "Reading T's message must not change the slider value")
        player.refreshAccessibilityValueForFocus()
        precondition(player.accessibilityTimecodeLabel == requestedValue, "A paused refresh must update the saved value")
        player.playbackClock.update(ProjectTime(seconds: 36), frameRate: 30)
        precondition(player.accessibilityTimecodeLabel == requestedValue, "Clock ticks must leave the refreshed value unchanged")
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
        print("PASS: 300 advancing clock ticks preserved workspace and Mixer controls, saved accessible values stay stable across clock ticks and T reads current time, no application created")
    }

    @MainActor static func checkFocusRouting() {
        let focused = TimelineElementSelection.clip(UUID())
        let stale = TimelineElementSelection.clip(UUID())
        let trackID = UUID()
        precondition(MixerFocusOrigin.resolve(voiceOver: true, observedItem: focused,
            keyboardItem: stale, collectionResponder: false, trackID: trackID)
            == .timeline(trackID: trackID, item: focused))
        precondition(MixerFocusOrigin.resolve(voiceOver: true, observedItem: nil,
            keyboardItem: stale, collectionResponder: true, trackID: trackID)
            == .timeline(trackID: trackID, item: nil))
        precondition(MixerFocusOrigin.resolve(voiceOver: true, observedItem: nil,
            keyboardItem: stale, collectionResponder: false, trackID: trackID) == .editor)
        precondition(MixerFocusOrigin.resolve(voiceOver: false, observedItem: stale,
            keyboardItem: focused, collectionResponder: false, trackID: trackID)
            == .timeline(trackID: trackID, item: focused))
        precondition(TimelineKeyboardFocus.mixerOrigin(in: nil, trackID: trackID) == .editor)

        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))
        let first = TimelineClip(assetID: UUID(), name: "At playhead", segments: [segment])
        let second = TimelineClip(assetID: UUID(), name: "Opened from here", segments: [segment], timelineStart: ProjectTime(seconds: 4))
        let caption = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "Caption")
        var description = caption
        description.id = UUID()
        description.isDescription = true
        let marker = TimelineMarker(index: 1, time: .zero, title: "Marker 1")
        let video = TimelineTrack(name: "Primary Video", kind: .video, clips: [first, second])
        let captions = TimelineTrack(name: "Captions", kind: .captions, captionCues: [caption])
        let descriptions = TimelineTrack(name: "Descriptions", kind: .captions, captionCues: [description])
        let markers = TimelineTrack(name: "Markers", kind: .markers, markers: [marker])
        var project = TrimatoProject(name: "Mixer return")
        project.tracks = [video, captions, descriptions, markers]
        let transition = TimelineTransition(trackID: video.id, edge: .between, kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1), leadingClipID: first.id, trailingClipID: second.id)
        project.transitions = [transition]
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.selection = .timelineClip(first.id)
        for (track, target) in [(video, TimelineElementSelection.clip(second.id)),
                                (captions, .caption(caption.id)),
                                (descriptions, .caption(description.id)), (markers, .marker(marker.id)),
                                (video, .transition(transition.id))] {
            controller.activeTimelineTrackID = video.id
            let revision = controller.timelineFocusRestoreRequest
            MixerFocusOrigin.timeline(trackID: track.id, item: target).restore(in: controller)
            precondition(controller.activeTimelineTrackID == track.id)
            precondition(controller.timelineFocusRestoreTarget == target)
            precondition(controller.timelineFocusRestoreRequest == revision + 1)
            precondition(controller.timelinePlayhead == .zero)
        }
        var revision = controller.timelineListFocusRestoreRequest
        let itemRevision = controller.timelineFocusRestoreRequest
        MixerFocusOrigin.timeline(trackID: video.id, item: nil).restore(in: controller)
        precondition(controller.timelineListFocusRestoreRequest == revision + 1)
        precondition(controller.timelineFocusRestoreRequest == itemRevision)
        revision = controller.timelineListFocusRestoreRequest
        MixerFocusOrigin.timeline(trackID: video.id, item: .clip(UUID())).restore(in: controller)
        precondition(controller.timelineListFocusRestoreRequest == revision + 1)
        revision = controller.timelineListFocusRestoreRequest
        MixerFocusOrigin.timeline(trackID: UUID(), item: .clip(second.id)).restore(in: controller)
        precondition(controller.timelineListFocusRestoreRequest == revision + 1)
        let editorRevision = controller.editorFocusRestoreRequest
        MixerFocusOrigin.editor.restore(in: controller)
        precondition(controller.editorFocusRestoreRequest == editorRevision + 1)

        let request = MixerReturnRequest(controller)
        precondition(request.isCurrent(in: controller))
        controller.toolPane = .mixer
        precondition(!request.isCurrent(in: controller))
        controller.toolPane = nil
        // No active project window exists in this background check; rejected
        // workspace commands must not invalidate an otherwise current return.
        controller.requestWorkspaceFocus(.timeline)
        precondition(request.isCurrent(in: controller))
        controller.toolFocusRevision += 1
        precondition(!request.isCurrent(in: controller))
        let later = MixerReturnRequest(controller)
        controller.requestTimelineListFocusRestore()
        precondition(!later.isCurrent(in: controller))
        let editorReturn = MixerReturnRequest(controller)
        controller.requestEditorFocusRestore()
        precondition(!editorReturn.isCurrent(in: controller))

        var entry = MixerEntryRequest()
        precondition(entry.issue(1, keyboardFocused: false, voiceOverFocused: false))
        precondition(!entry.keyboardConfirmed && !entry.voiceOverObserved)
        entry.observeKeyboard(true)
        precondition(entry.keyboardConfirmed && !entry.voiceOverObserved)
        precondition(!entry.issue(1, keyboardFocused: false, voiceOverFocused: false))
        precondition(entry.issue(2, keyboardFocused: true, voiceOverFocused: false))
        precondition(entry.keyboardConfirmed && !entry.voiceOverObserved)
        entry.observeVoiceOver(true)
        precondition(entry.keyboardConfirmed && entry.voiceOverObserved)
        entry.observeKeyboard(false)
        precondition(!entry.keyboardConfirmed && entry.voiceOverObserved)
        entry.observeVoiceOver(false)
        precondition(!entry.keyboardConfirmed && !entry.voiceOverObserved)
        precondition(NSApp == nil)
        print("PASS: Mixer return routing preserves collection, exact clip, caption, description, marker and transition origins; missing destinations fall back to collection; later navigation supersedes returns; keyboard and VoiceOver entry are independent")
    }

}
