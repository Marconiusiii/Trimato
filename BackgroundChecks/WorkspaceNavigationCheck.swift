import AppKit
import Combine
import Foundation
import Darwin
@testable import Trimato

@MainActor private final class SimulatedWindowState {
    var keyProject: ObjectIdentifier?
    var attached = Set<ObjectIdentifier>()
    var sheetOpen = false
    var appActive = true
}

@main struct WorkspaceNavigationCheck {
    static func verify(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func verifyEntryLifecycle() {
        for target in [ProjectOpeningEntry.Target.projectSource, .importFiles] {
            var entry = ProjectOpeningEntry(required: true)
            verify(!entry.confirm(target, windowReady: true, isKeyboardDestination: true),
                   "Entry completed before workspace installation")
            entry.install(target: target, hasFailure: false)
            verify(entry.pendingTarget == target, "Installation lost the entry destination")
            // A successful API return is not evidence that the destination is
            // first responder. Model the window fallback as a negative identity.
            verify(!entry.confirm(target, windowReady: true, isKeyboardDestination: false),
                   "Window-level responder was mistaken for control entry")
            verify(entry.pendingTarget == target, "Delayed target attachment consumed entry")
            verify(!entry.confirm(target, windowReady: false, isKeyboardDestination: true),
                   "Background, closing, or sheet-covered window completed entry")
            let wrong: ProjectOpeningEntry.Target = target == .projectSource ? .importFiles : .projectSource
            verify(!entry.confirm(wrong, windowReady: true, isKeyboardDestination: true), "Wrong control completed entry")
            verify(entry.confirm(target, windowReady: true, isKeyboardDestination: true), "Valid destination did not complete entry")
            verify(!entry.confirm(target, windowReady: true, isKeyboardDestination: true), "Duplicate callback repeated entry")
            entry.install(target: target, hasFailure: false)
            verify(entry.pendingTarget == nil, "Repeated appearance rearmed initial entry")

            var failure = ProjectOpeningEntry(required: true)
            failure.install(target: target, hasFailure: true)
            verify(!failure.confirm(target, windowReady: true, isKeyboardDestination: true), "Entry competed with loading failure review")
            failure.finishFailureReview()
            verify(failure.confirm(target, windowReady: true, isKeyboardDestination: true), "Failure dismissal lost entry")

            for beforeInstallation in [true, false] {
                var cancelled = ProjectOpeningEntry(required: true)
                if !beforeInstallation { cancelled.install(target: target, hasFailure: false) }
                cancelled.cancel()
                cancelled.install(target: target, hasFailure: false)
                cancelled.finishFailureReview()
                verify(!cancelled.confirm(target, windowReady: true, isKeyboardDestination: true),
                       "Closing or superseding navigation allowed a late initial entry")
            }
        }
        print("PASS: entry policy requires installation and confirmed destination; inactive window, delayed attachment, wrong target, duplicate callbacks, failure review, close and superseding navigation")
    }

    @MainActor static func verifyPopulatedPreparation() async throws {
        // A real, silent PCM source exercises successful composition and seeking,
        // not just the empty-project and error branches. The player is never run.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-opening-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + 96000)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(48000)); number(UInt32(96000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(96000))
        wav.append(Data(count: 96000))
        try wav.write(to: url)
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
        let asset = MediaAssetRecord(name: "Opening fixture", originalPath: url.path,
            duration: ProjectTime(seconds: 1), naturalWidth: nil, naturalHeight: nil,
            frameRate: nil, hasAudio: true, sourceEdit: [segment])
        let clip = TimelineClip(assetID: asset.id, name: "Opening fixture", segments: [segment])
        var project = TrimatoProject()
        project.media = [asset]
        project.tracks = [TimelineTrack(name: "Audio", kind: .audio, role: .primaryAudio, clips: [clip])]
        let player = ProjectPlayerViewModel(awaitingInitialPreparation: true)
        let controller = ProjectController(document: ProjectDocument(project: project), awaitingWorkspacePreparation: true)
        controller.installProjectPlayer(player)
        player.requestPreparation(project: project, mediaURLs: [asset.id: url])
        verify(!controller.canPresentWorkspace, "Populated project exposed workspace before loading")
        for _ in 0..<1500 where player.isInitialPreparationPending || player.isPreparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        verify(player.errorMessage == nil && player.hasPreparedPlayerItem && player.canControlPlayback,
               "Successful media preparation did not produce a usable player: \(player.errorMessage ?? "timeout")")
        verify(controller.finishWorkspacePreparation(), "Prepared populated workspace could not install")
        verify(controller.openingEntry.pendingTarget == .projectSource,
               "Successfully loaded populated project omitted its initial entry")
        verify(!player.isPlaying, "Background check started playback")
        print("PASS: real populated audio-project preparation and seek; player usable but paused; Project Source entry remains pending confirmation")
    }

    @MainActor static func verifyProjectOpening() async {
        let player = ProjectPlayerViewModel(awaitingInitialPreparation: true)
        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject()),
                                           awaitingWorkspacePreparation: true)
        verify(!controller.canPresentWorkspace, "Uninstalled player exposed workspace")
        controller.installProjectPlayer(player)
        let state = WorkspaceCommandState(notifications: NotificationCenter()) { !$0.isPreparingProject }
        state.register(controller, windowChanges: player.$isInitialPreparationPending
            .map { _ in () }.eraseToAnyPublisher())
        await state.pendingRefresh?.value
        verify(!controller.canPresentWorkspace && state.controller == nil, "Loading exposed workspace or commands")
        verify(!controller.finishWorkspacePreparation(), "Appearance bypassed media preparation")

        // Preparation starts without constructing an Editor view. Even an empty
        // project must finish this pass before the workspace can be installed.
        player.requestPreparation(project: controller.project, mediaURLs: [:])
        verify(!controller.canPresentWorkspace, "Deferred preparation exposed workspace immediately")
        for _ in 0..<500 where player.isInitialPreparationPending {
            try? await Task.sleep(for: .milliseconds(10))
        }
        verify(controller.canPresentWorkspace, "Empty project never completed preparation")
        await state.pendingRefresh?.value
        verify(controller.isPreparingProject && state.controller == nil,
               "Media completion enabled commands before workspace installation")
        verify(controller.finishWorkspacePreparation(), "Workspace installation did not finish media preparation")
        verify(controller.openingEntry.pendingTarget == .importFiles,
               "Empty project installation did not request Import Files entry")
        verify(controller.openingEntry.phase != .entered(.importFiles),
               "Workspace installation falsely completed keyboard entry")
        state.refreshForWorkspacePresentation()
        verify(!controller.isPreparingProject && state.controller === controller,
               "Command refresh did not publish the prepared controller synchronously")
        verify(!controller.finishWorkspacePreparation(), "Repeated installation changed preparation state")
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Deferred refresh undid the handoff")

        // Offline media exercises the actual asynchronous failure and cancellation
        // paths. No windows, media playback, or accessibility announcements.
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
        let clip = TimelineClip(assetID: UUID(), name: "Offline fixture", segments: [segment])
        var offline = TrimatoProject()
        offline.tracks = [TimelineTrack(name: "Video", kind: .video, role: .primaryVideo, clips: [clip])]
        for cancel in [false, true] {
            let pendingPlayer = ProjectPlayerViewModel(awaitingInitialPreparation: true)
            let pending = ProjectController(document: ProjectDocument(project: offline), awaitingWorkspacePreparation: true)
            pending.installProjectPlayer(pendingPlayer)
            pendingPlayer.prepare(project: offline, mediaURLs: [:])
            verify(!pending.canPresentWorkspace && !pending.finishWorkspacePreparation(),
                   "In-flight preparation exposed workspace")
            if cancel { pendingPlayer.cancelPreparation() }
            for _ in 0..<500 where pendingPlayer.isInitialPreparationPending || pendingPlayer.isPreparing {
                try? await Task.sleep(for: .milliseconds(10))
            }
            verify(pending.canPresentWorkspace, "Failure or cancellation left project stuck loading")
            if cancel {
                verify(pendingPlayer.preparationWasCancelled && pendingPlayer.errorMessage == nil,
                       "Cancelled preparation surfaced a racing worker error")
            }
            if !cancel { verify(pendingPlayer.errorMessage != nil, "Offline failure was lost") }
            verify(pending.finishWorkspacePreparation(), "Failed preview prevented recovery workspace")
            if !cancel {
                verify(pending.openingEntry.phase == .reviewingFailure(.projectSource), "Loading error did not defer entry until review")
                pending.finishInitialPreviewFailureReview()
            }
            verify(pending.openingEntry.pendingTarget == .projectSource,
                   "Populated project has no initial entry destination")
            pending.cancelInitialWorkspaceEntry()
            verify(pending.openingEntry.pendingTarget == nil, "Closing retained initial entry")
        }
        player.prepare(project: offline, mediaURLs: [:])
        verify(player.isPreparing && controller.canPresentWorkspace && !controller.isPreparingProject,
               "Later preview rebuild removed the prepared workspace")
        player.cancelPreparation()
        state.unregister(controller)
        await state.pendingRefresh?.value
        print("PASS: opening without an Editor view, deferred preparation, empty project, command handoff, repeat appearance, offline failure, cancellation, and later rebuilds")
    }

    @MainActor static func main() async throws {
        verify(NSApp == nil, "Must not create an application")
        verifyEntryLifecycle()
        try await verifyPopulatedPreparation()
        await verifyProjectOpening()
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
            return windows.appActive && windows.keyProject == id && windows.attached.contains(id) && !windows.sheetOpen && !candidate.isImporting
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

        windows.appActive = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller == nil, "Background application retained commands")
        windows.appActive = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await state.pendingRefresh?.value
        verify(state.controller === controller, "Returning to the application required a control interaction")

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
