import AppKit
import Foundation
import Darwin
@testable import Trimato

/// Model and key-routing verification only: no application, windows, views, or posted input.
@main struct TimelineFocusMovementCheck {
    static func verify(_ condition: Bool, _ message: String = "Timeline focus regression") {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
    static func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
    @MainActor static func main() {
        verify(NSApp == nil)
        for (kind, role) in [(TimelineTrackKind.video, TimelineTrackRole.primaryVideo),
                             (.audio, .primaryAudio), (.video, .additional), (.audio, .additional)] {
            var project = TrimatoProject(name: "Focus check")
            let asset = MediaAssetRecord(name: "Fixture", originalPath: "/tmp/unused-focus-fixture.mov",
                duration: ProjectTime(seconds: 10), naturalWidth: 320, naturalHeight: 180,
                frameRate: 25, hasAudio: true,
                sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 10)))])
            let clips = (0..<3).map { index in
                TimelineClip(assetID: asset.id, name: "Clip \(index)", segments: asset.sourceEdit,
                    timelineStart: ProjectTime(seconds: Double(index) * (role == .additional ? 20 : 10)))
            }
            let track = TimelineTrack(name: "Test track", kind: kind, role: role, clips: clips)
            var otherClips = clips
            for index in otherClips.indices { otherClips[index].id = UUID() }
            let otherTrack = TimelineTrack(name: "Other track", kind: kind, role: .additional, clips: otherClips)
            project.media = [asset]; project.tracks = [track, otherTrack]
            let controller = ProjectController(document: ProjectDocument(project: project))
            controller.activeTimelineTrackID = track.id
            let first = TimelineElementSelection.clip(clips[0].id)
            let middle = TimelineElementSelection.clip(clips[1].id)
            let last = TimelineElementSelection.clip(clips[2].id)
            controller.selection = .timelineClip(clips[2].id)
            // C uses the playhead, despite another selected/remembered clip.
            let playhead = clips[1].timelineStart + ProjectTime(seconds: 1)
            verify(controller.editorClipSelection(at: playhead) == .timelineClip(clips[1].id))
            verify(controller.currentTimelineClip(at: playhead)?.id == clips[1].id)
            controller.activeTimelineTrackID = otherTrack.id
            verify(controller.editorClipSelection(at: playhead) == .timelineClip(otherClips[1].id), "C used the previously selected track")
            controller.activeTimelineTrackID = track.id
            let nativeFocus = TimelineNativeFocus()
            let firstOwner = UUID(), middleOwner = UUID(), lastOwner = UUID()
            nativeFocus.record(first, owner: firstOwner, focused: true, voiceOver: false)
            nativeFocus.record(last, owner: lastOwner, focused: true, voiceOver: true)
            nativeFocus.record(middle, owner: middleOwner, focused: true, voiceOver: true)
            nativeFocus.record(last, owner: lastOwner, focused: false, voiceOver: true)
            verify(nativeFocus.voiceOverSelection == middle, "Late blur cleared the current VoiceOver clip")
            verify(nativeFocus.keyboardSelection == first)
            let coordinator = TimelineKeyboardBridge.Coordinator()
            func refresh() {
                coordinator.bridge = TimelineKeyboardBridge(accessibilitySelection: last,
                    keyboardSelection: first, movingClipID: controller.movingTimelineClipID,
                    nativeFocus: nativeFocus,
                    allowsNudging: { _ in role == .additional },
                    contains: { [first, middle, last].contains($0) }) { action, target in
                        verify(target == middle, "Wrong clip received keyboard action")
                        switch action {
                        case .toggleMovement: controller.toggleClipMovement(id: clips[1].id)
                        case .finishMovement: controller.finishClipMovement()
                        case .earlier: controller.moveFocusedTimelineClip(id: clips[1].id, by: -1)
                        case .later: controller.moveFocusedTimelineClip(id: clips[1].id, by: 1)
                        default: fail("Unexpected action")
                        }
                    }
            }
            func key(_ code: UInt16, _ type: NSEvent.EventType = .keyDown) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)!
            }
            refresh()
            coordinator.mouseSource = last
            verify(coordinator.handleKey(key(49), voiceOver: true, editingText: false, currentAccessibilityFocus: first) == nil)
            verify(controller.movingTimelineClipID == clips[1].id)
            verify(coordinator.mouseSource == nil)
            refresh()
            verify(coordinator.handleKey(key(49, .keyUp), voiceOver: true, editingText: false) == nil)
            verify(coordinator.handleKey(key(124), voiceOver: true, editingText: false, currentAccessibilityFocus: first) == nil)
            verify(coordinator.handleKey(key(49), voiceOver: true, editingText: false, currentAccessibilityFocus: first) == nil)
            verify(controller.movingTimelineClipID == nil)
            verify(controller.selection == .timelineClip(clips[1].id))
            if role == .additional {
                verify(controller.project.timelineClip(id: clips[1].id)!.timelineStart > clips[1].timelineStart, "Arrow did not nudge the lifted clip")
            } else {
                verify(controller.activeTimelineTrack!.sortedClips.last?.id == clips[1].id, "Arrow did not reorder the lifted clip")
            }
            refresh()
            let unchangedProject = controller.project
            let previousFocusRequest = controller.timelineFocusRestoreRequest
            _ = coordinator.handleKey(key(49), voiceOver: true, editingText: false, currentAccessibilityFocus: first)
            refresh()
            _ = coordinator.handleKey(key(53), voiceOver: true, editingText: false, currentAccessibilityFocus: first)
            verify(controller.movingTimelineClipID == nil)
            verify(controller.project == unchangedProject, "Unmoved drop changed the project")
            verify(controller.timelineFocusRestoreRequest == previousFocusRequest,
                   "Unmoved drop unnecessarily restored focus")
            refresh()
            nativeFocus.record(.clip(UUID()), owner: middleOwner, focused: true, voiceOver: true)
            verify(coordinator.handleKey(key(49), voiceOver: true, editingText: false,
                currentAccessibilityFocus: first) == nil, "Stale target leaked to a keyboard responder")
            verify(controller.movingTimelineClipID == nil)
            nativeFocus.remove(owner: middleOwner)
            verify(nativeFocus.voiceOverSelection == nil)
            verify(coordinator.handleKey(key(49), voiceOver: true, editingText: false,
                currentAccessibilityFocus: first) != nil, "Missing native focus fell back to a stale clip")
            verify(controller.movingTimelineClipID == nil)
            let focusReturn = TimelineItemFocusRequest()
            focusReturn.request()
            verify(focusReturn.consume())
            verify(!focusReturn.consume(), "Focus return replayed on reappearance")
            print("PASS: \(kind) \(role): middle-clip lift, arrow, Space drop, Escape, stale target rejection, Editor C")
        }
        verify(NSApp == nil)
    }
}
