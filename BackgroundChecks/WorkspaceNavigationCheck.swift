import AppKit
import Foundation
import Darwin
@testable import Trimato

@main struct WorkspaceNavigationCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() {
        verify(NSApp == nil, "Must not create an application")
        verify(WorkspacePane.allCases.map(\.shortcut) == ["1", "2", "3"], "Pane shortcut mapping")
        for active in [false, true] {
            for key in [false, true] {
                for sheet in [false, true] {
                    for modal in [false, true] {
                        for closing in [false, true] {
                            let allowed = WorkspaceCommandAvailability.allows(isActive: active,
                                isProjectWindowKey: key, hasSheet: sheet, hasModalWindow: modal, isClosing: closing)
                            verify(allowed == (active && key && !sheet && !modal && !closing), "Window isolation")
                        }
                    }
                }
            }
        }
        for width: CGFloat in [0, 460, 699, 700, 900, .infinity, .nan] {
            verify(!PortraitEditorLayout.placesControlsBesideVideo(enabled: false, width: width), "Off must stay stacked")
            verify(PortraitEditorLayout.placesControlsBesideVideo(enabled: true, width: width)
                == (width.isFinite && width >= 700), "Narrow window fallback")
        }
        let first = TimelineElementSelection.clip(UUID())
        let middle = TimelineElementSelection.clip(UUID())
        let otherTrack = TimelineElementSelection.clip(UUID())
        verify(WorkspacePaneNavigation.timelineTarget(remembered: middle, keyboard: first,
            available: [first, middle]) == middle, "Remembered focus lost to stale keyboard focus")
        verify(WorkspacePaneNavigation.timelineTarget(remembered: otherTrack, keyboard: middle,
            available: [first, middle]) == middle, "Wrong-track focus was retained")
        verify(WorkspacePaneNavigation.timelineTarget(remembered: otherTrack, keyboard: nil,
            available: [first, middle]) == nil, "No target must focus the collection, not select the first clip")
        verify(WorkspacePaneNavigation.timelineTarget(remembered: middle, keyboard: first,
            available: []) == nil, "Empty timeline target")
        let project = TrimatoProject(name: "Workspace check")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let originalSelection = controller.selection
        let originalTime = controller.timelinePlayhead
        for pane in WorkspacePane.allCases { controller.requestWorkspaceFocus(pane) }
        verify(controller.workspaceFocusRequest.revision == 0, "Unattached window accepted a command")
        verify(controller.project == project && controller.selection == originalSelection &&
            controller.timelinePlayhead == originalTime, "Unavailable command changed project state")
        verify(NSApp == nil, "Check created an application")
        print("PASS: pane mapping, active-window and modal guards, portrait width fallback, remembered Timeline focus, empty tracks, and unchanged project state")
    }
}
