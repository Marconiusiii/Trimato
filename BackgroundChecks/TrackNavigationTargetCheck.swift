import AppKit
import Foundation
import Darwin
@testable import Trimato

/// Exercises real track commands without an application, windows, or announcements.
@main struct TrackNavigationTargetCheck {
    static func verify(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func main() {
        verify(NSApp == nil, "Check must not create an application")
        var tracks: [TimelineTrack] = []
        var expected: [UUID: ProjectController.TrackNavigationTarget] = [:]
        for (name, kind, role, purpose) in [
            ("Primary Video", TimelineTrackKind.video, TimelineTrackRole.primaryVideo, Optional<RecordingPurpose>.none),
            ("Primary Audio", .audio, .primaryAudio, nil),
            ("Additional Video", .video, .additional, nil),
            ("Additional Audio", .audio, .additional, nil),
            ("Voicer", .audio, .additional, .voiceOver),
            ("Audio Description", .audio, .additional, .audioDescription),
            ("Captions", .captions, .additional, nil),
            ("Description Transcript", .captions, .additional, .descriptionTranscript),
            ("Markers", .markers, .additional, nil)
        ] {
            var track = TimelineTrack(name: name, kind: kind, role: role)
            track.recordingPurpose = purpose
            if kind == .captions {
                var first = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "First")
                var second = CaptionCue(start: ProjectTime(seconds: 4), end: ProjectTime(seconds: 6), text: "Second")
                first.isDescription = purpose == .descriptionTranscript
                second.isDescription = first.isDescription
                track.captionCues = [second, first]
                expected[track.id] = .init(selection: .caption(second.id), name: second.displayName)
                for seconds in [3.0, 4, 5, 6, 99] {
                    verify(ProjectController.timelineNavigationTarget(on: track, at: ProjectTime(seconds: seconds)) == expected[track.id], "\(name): gap, exact start, interior, end, or final fallback")
                }
                verify(ProjectController.timelineNavigationTarget(on: track, at: .zero)?.selection == .caption(first.id), "\(name): first cue")
            } else if kind == .markers {
                let first = TimelineMarker(index: 1, time: .zero, title: "Marker 1")
                let second = TimelineMarker(index: 2, time: ProjectTime(seconds: 4), title: "Marker 2")
                track.markers = [second, first]
                expected[track.id] = .init(selection: .marker(second.id), name: second.title)
                for seconds in [3.0, 4, 5, 99] {
                    verify(ProjectController.timelineNavigationTarget(on: track, at: ProjectTime(seconds: seconds)) == expected[track.id], "Marker destination")
                }
                verify(ProjectController.timelineNavigationTarget(on: track, at: .zero)?.selection == .marker(first.id), "Marker exact start")
            } else {
                let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))]
                let first = TimelineClip(assetID: UUID(), name: "First", segments: segments, timelineStart: .zero)
                let second = TimelineClip(assetID: UUID(), name: "Second", segments: segments, timelineStart: ProjectTime(seconds: 4))
                track.clips = [second, first]
                expected[track.id] = .init(selection: .clip(second.id), name: second.displayName)
                for seconds in [3.0, 4, 5, 6, 99] {
                    verify(ProjectController.timelineNavigationTarget(on: track, at: ProjectTime(seconds: seconds)) == expected[track.id], "\(name): media destination")
                }
            }
            tracks.append(track)
        }
        tracks += TimelineTrackKind.allCases.map { TimelineTrack(name: "Empty \($0.title)", kind: $0) }
        var project = TrimatoProject()
        project.tracks = tracks
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 5)
        let ordered = controller.project.orderedTimelineTracks
        for (index, track) in ordered.enumerated() {
            controller.activeTimelineTrackID = ordered[index == 0 ? 1 : index - 1].id
            let itemRevision = controller.timelineFocusRestoreRequest
            let listRevision = controller.timelineListFocusRestoreRequest
            controller.selectAdjacentTrack(index == 0 ? -1 : 1)
            verify(controller.activeTimelineTrackID == track.id, "Adjacent destination track")
            verify(controller.timelinePlayhead == ProjectTime(seconds: 5), "Track change moved playhead")
            if let target = expected[track.id] {
                verify(controller.timelineFocusRestoreTarget == target.selection, "\(track.name): wrong focus target")
                verify(controller.timelineFocusRestoreRequest == itemRevision + 1, "\(track.name): missing item request")
                verify(controller.timelineListFocusRestoreRequest == listRevision, "\(track.name): incorrect empty-track request")
                verify(ProjectController.activeTrackAnnouncement(trackName: track.name, clipName: target.name) == "\(track.name) track, \(target.name) selected", "\(track.name): wrong announcement text")
                switch target.selection {
                case .clip(let id): verify(controller.selection == .timelineClip(id), "Clip selection mismatch")
                case .caption(let id): verify(controller.selectedCaptionCueID == id && controller.selection == .project, "Caption selection mismatch")
                case .marker(let id): verify(controller.selectedMarkerID == id && controller.selection == .project, "Marker selection mismatch")
                case .transition: break
                }
            } else {
                verify(controller.timelineListFocusRestoreRequest == listRevision + 1, "\(track.name): missing empty-track request")
                verify(controller.timelineFocusRestoreRequest == itemRevision, "\(track.name): unexpected item request")
                verify(controller.selectedCaptionCueID == nil && controller.selectedMarkerID == nil && controller.selection == .project, "Empty track retained selection")
            }
            let itemRequest = controller.timelineFocusRestoreRequest
            let listRequest = controller.timelineListFocusRestoreRequest
            let target = expected[track.id]
            verify(controller.takePendingTrackAnnouncement(.clip(UUID()), itemRevision: itemRequest, listRevision: listRequest) == nil, "Unrelated focus consumed announcement")
            verify(controller.takePendingTrackAnnouncement(target?.selection, itemRevision: itemRequest - 1, listRevision: listRequest) == nil, "Stale request consumed announcement")
            let expectedMessage = ProjectController.activeTrackAnnouncement(trackName: track.name, clipName: target?.name)
            if let target {
                let focus = TimelineNativeFocus()
                var messages: [String] = []
                focus.didObserveKeyboardFocus = { selection in
                    if let message = controller.takePendingTrackAnnouncement(selection, itemRevision: itemRequest, listRevision: listRequest) {
                        messages.append(message)
                    }
                }
                let owner = UUID()
                focus.record(target.selection, owner: owner, focused: true, voiceOver: false)
                verify(focus.voiceOverSelection == nil, "Check unexpectedly supplied VoiceOver focus")
                verify(messages == [expectedMessage], "Keyboard completion without VoiceOver callback lost track announcement")
                focus.record(target.selection, owner: owner, focused: true, voiceOver: true)
                focus.record(target.selection, owner: owner, focused: true, voiceOver: false)
                verify(messages == [expectedMessage], "Late or repeated focus replayed track announcement")
            } else {
                verify(controller.takePendingTrackAnnouncement(nil, itemRevision: itemRequest, listRevision: listRequest) == expectedMessage, "Empty collection completion lost announcement")
            }
            verify(controller.takePendingTrackAnnouncement(target?.selection, itemRevision: itemRequest, listRevision: listRequest) == nil, "Announcement replayed")
            print("PASS: \(track.name)")
        }
        let selection = EditorSelection.asset(UUID())
        controller.selection = selection
        let itemRevision = controller.timelineFocusRestoreRequest
        let listRevision = controller.timelineListFocusRestoreRequest
        controller.selectAdjacentTrack(-1, restoreTimelineFocus: false)
        verify(controller.selection == selection, "Editor shortcut changed source selection")
        verify(controller.timelineFocusRestoreRequest == itemRevision && controller.timelineListFocusRestoreRequest == listRevision, "Editor shortcut moved focus")
        // Rapid navigation replaces the pending announcement, including revisiting a track.
        controller.activeTimelineTrackID = ordered[0].id
        controller.selectAdjacentTrack(1)
        let oldTarget = controller.timelineFocusRestoreTarget
        let oldItemRequest = controller.timelineFocusRestoreRequest
        let oldListRequest = controller.timelineListFocusRestoreRequest
        controller.selectAdjacentTrack(1)
        verify(controller.takePendingTrackAnnouncement(oldTarget, itemRevision: oldItemRequest, listRevision: oldListRequest) == nil, "Superseded track announced")
        controller.requestEditorFocusRestore()
        verify(controller.takePendingTrackAnnouncement(controller.timelineFocusRestoreTarget, itemRevision: controller.timelineFocusRestoreRequest, listRevision: controller.timelineListFocusRestoreRequest) == nil, "Editor return retained track announcement")
        controller.selectAdjacentTrack(-1)
        let pendingTarget = controller.timelineFocusRestoreTarget
        controller.selectAdjacentTrack(1, restoreTimelineFocus: false)
        verify(controller.takePendingTrackAnnouncement(pendingTarget, itemRevision: controller.timelineFocusRestoreRequest, listRevision: controller.timelineListFocusRestoreRequest) == nil, "Editor track change retained Timeline speech")
        let focus = TimelineNativeFocus()
        var observations: [TimelineElementSelection] = []
        focus.didObserveKeyboardFocus = { observations.append($0) }
        let item = TimelineElementSelection.clip(UUID())
        let owner = UUID()
        focus.record(item, owner: owner, focused: true, voiceOver: false)
        focus.record(item, owner: owner, focused: true, voiceOver: true)
        focus.record(item, owner: owner, focused: false, voiceOver: true)
        focus.record(item, owner: owner, focused: false, voiceOver: false)
        verify(observations == [item], "VoiceOver or focus departure triggered keyboard completion")
        verify(NSApp == nil, "Check created an application")
        print("PASS: Editor-only track command preserves source selection and focus")
    }
}
