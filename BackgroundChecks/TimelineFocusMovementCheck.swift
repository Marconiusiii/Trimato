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
    @MainActor static func verifyTextEditingPrecedence() {
        for description in [false, true] {
            for voiceOver in [false, true] {
                var cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "Editable text")
                cue.isDescription = description
                var track = TimelineTrack(name: description ? "Descriptions" : "Captions", kind: .captions)
                track.captionCues = [cue]
                var project = TrimatoProject()
                project.tracks = [track]
                let controller = ProjectController(document: ProjectDocument(project: project))
                let target = TimelineElementSelection.caption(cue.id)
                let nativeFocus = TimelineNativeFocus()
                let owner = UUID()
                nativeFocus.record(target, owner: owner, focused: true, voiceOver: true)
                nativeFocus.record(target, owner: owner, focused: true, voiceOver: false)
                let coordinator = TimelineKeyboardBridge.Coordinator()
                var actions: [TimelineKeyAction] = []
                coordinator.bridge = TimelineKeyboardBridge(accessibilitySelection: target,
                    keyboardSelection: target, movingClipID: UUID(), nativeFocus: nativeFocus,
                    allowsNudging: { _ in true }) { action, selection in
                        actions.append(action)
                        if action == .delete, case .caption(let id) = selection {
                            do { try controller.deleteCaptionCue(id: id) }
                            catch { fail("Unexpected caption deletion error") }
                        }
                    }
                let original = controller.project
                let keys: [(UInt16, NSEvent.ModifierFlags)] = [
                    (51, []), (117, []), (49, []), (36, []), (76, []), (53, []),
                    (123, []), (124, []), (125, []), (126, []), (8, .command), (9, .command),
                    (9, [.command, .option])
                ]
                for (code, modifiers) in keys {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        coordinator.mouseSource = target
                        // A key consumed before text editing began must not steal its new event.
                        coordinator.consumedKeys.insert(code)
                        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                            timestamp: 0, windowNumber: 0, context: nil, characters: "",
                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                        verify(coordinator.handleKey(event, voiceOver: voiceOver, editingText: true,
                            currentAccessibilityFocus: target, currentKeyboardFocus: target,
                            useLiveKeyboardFocus: true) === event, "Text editing lost key \(code) with VoiceOver=\(voiceOver)")
                        verify(actions.isEmpty && controller.project == original, "Text editing changed the Timeline")
                        verify(!coordinator.consumedKeys.contains(code), "Text editing retained an intercepted key")
                    }
                }
                // The alternate Delete-command path uses this same target policy.
                verify(TimelineKeyAction.target(voiceOver: voiceOver, accessibilityFocus: target,
                    keyboardFocus: target, editingText: true, mouseFocus: target) == nil,
                    "Delete-command target ignored active text editing")
                let deletion = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!
                verify(coordinator.handleKey(deletion, voiceOver: voiceOver, editingText: false,
                    currentAccessibilityFocus: target, currentKeyboardFocus: target,
                    useLiveKeyboardFocus: true) == nil, "Timeline Delete failed after text editing ended")
                verify(actions == [.delete] && controller.project.tracks[0].captionCues.isEmpty,
                    "Timeline Delete did not remove only its intended caption")
                print("PASS: \(description ? "description" : "caption") text editing, VoiceOver=\(voiceOver): keys pass through, model unchanged, Timeline Delete resumes afterward")
            }
        }
    }
    @MainActor static func main() {
        verify(NSApp == nil)
        verifyTextEditingPrecedence()
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
            let commands = WorkspaceVoiceOverCommandFocus()
            nativeFocus.commandFocusProvider = { commands }
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
            // Video Frame can take VoiceOver focus while keyboard focus and
            // the Timeline's last observed clip remain unchanged.
            let editorOwner = UUID()
            commands.claim(.editor(editorOwner))
            verify(nativeFocus.voiceOverSelection == nil, "Timeline retained commands after Editor entry")
            verify(nativeFocus.keyboardSelection == first, "Handoff moved keyboard focus")
            for code: UInt16 in [49, 123, 124, 53, 36] {
                verify(coordinator.handleKey(key(code), voiceOver: true, editingText: false,
                    currentAccessibilityFocus: first) != nil, "Timeline consumed an Editor key")
            }
            verify(controller.project == unchangedProject)
            verify(controller.movingTimelineClipID == nil)
            nativeFocus.record(middle, owner: middleOwner, focused: false, voiceOver: true)
            verify(commands.owner == .editor(editorOwner), "Late Timeline blur cleared Editor ownership")
            commands.release(.editor(editorOwner))
            verify(nativeFocus.voiceOverSelection == nil, "Leaving Editor revived stale Timeline focus")
            nativeFocus.record(middle, owner: middleOwner, focused: true, voiceOver: true)
            commands.release(.editor(editorOwner))
            verify(nativeFocus.voiceOverSelection == middle, "Late Editor blur cleared Timeline ownership")
            let anotherWindow = WorkspaceVoiceOverCommandFocus()
            anotherWindow.claim(.editor(UUID()))
            verify(nativeFocus.voiceOverSelection == middle, "Another window changed Timeline ownership")
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
            print("PASS: \(kind) \(role): lift, move, drop, Escape, Editor handoff, delayed blur, window isolation, Editor C")
        }
        verify(NSApp == nil)
    }
}
