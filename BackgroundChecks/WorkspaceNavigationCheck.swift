import AppKit
import Combine
import Foundation
import Darwin
@testable import Trimato

@MainActor private final class SimulatedWindowState {
    var keyProject: ObjectIdentifier?
    var attached = Set<ObjectIdentifier>()
    var sheetOpen = false
}

@main struct WorkspaceNavigationCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func main() async {
        verify(NSApp == nil, "Must not create an application")
        verify(WorkspacePane.allCases.map(\.title) == ["Project Source", "Editor", "Timeline", "Tool Pane"], "Window menu names")
        verify(WorkspacePane.allCases.map(\.shortcut) == ["1", "2", "3", "4"], "Pane shortcut mapping")
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

        // An isolated notification center simulates lifecycle events without
        // creating windows, posting input, changing focus, or starting playback.
        let notifications = NotificationCenter()
        let windowChanges = PassthroughSubject<Void, Never>()
        let windows = SimulatedWindowState()
        let state = WorkspaceCommandState(notifications: notifications) { candidate in
            let id = ObjectIdentifier(candidate)
            return windows.keyProject == id && windows.attached.contains(id) && !windows.sheetOpen && !candidate.isImporting
        }
        var publications = 0
        let observation = state.$controller.dropFirst().sink { _ in publications += 1 }
        state.register(controller, windowChanges: windowChanges.eraseToAnyPublisher())
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Unattached window enabled commands")
        windows.keyProject = ObjectIdentifier(controller)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Key event before attachment bypassed readiness")
        windows.attached.insert(ObjectIdentifier(controller))
        windowChanges.send()
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Attachment did not enable commands without control focus")
        controller.timelinePlayhead = ProjectTime(seconds: 1)
        verify(state.pendingRefresh == nil, "Playback position unnecessarily refreshed command availability")
        controller.timelinePlayhead = originalTime

        controller.isImporting = true
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Import did not disable commands")
        controller.isImporting = false
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Finished load required an extra interaction")
        windows.sheetOpen = true
        notifications.post(name: NSWindow.willBeginSheetNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Open sheet did not disable commands")
        windows.sheetOpen = false
        notifications.post(name: NSWindow.didEndSheetNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Sheet dismissal did not enable commands")

        let second = ProjectController(document: ProjectDocument(project: TrimatoProject(name: "Other project")))
        windows.attached.insert(ObjectIdentifier(second))
        state.register(second, windowChanges: windowChanges.eraseToAnyPublisher())
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Background registration stole routing")
        windows.keyProject = ObjectIdentifier(second)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller === second, "Window switch retained the old project")
        windows.keyProject = nil
        notifications.post(name: NSWindow.didResignKeyNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Another window retained project commands")
        windows.keyProject = ObjectIdentifier(controller)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Activation required control focus")
        state.unregister(controller)
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Closed project retained commands")
        verify(publications >= 8, "Availability did not publish changes to the menu")
        withExtendedLifetime(observation) {}
        verify(NSApp == nil, "Check created an application")
        print("PASS: menu names, initial attachment without control focus, load completion, sheet dismissal, window switching, activation, published availability, pane routing, and portrait fallback")
    }
}
