import AppKit
import Combine
import SwiftUI

nonisolated enum ClipEditorMediaKind {
    static func name(hasVideo: Bool) -> String {
        hasVideo ? "Video Clip Editor" : "Audio Clip Editor"
    }
}

@MainActor
final class ClipPlacementCommandContext: ObservableObject {
    let controller: ProjectController
    let editSelection: EditorSelection
    @Published private(set) var segments: [SourceSegment]
    @Published private(set) var isKeyWindow = false
    @Published var presentedError: ProjectPresentedError?
    @Published var trackPlacementAction: PlacementAction?
    private var draft: ClipEditorDraft
    private let baselineAudioSettings: AudioClipSettings?
    @Published var audioSettings: AudioClipSettings?

    init(
        controller: ProjectController,
        editSelection: EditorSelection,
        segments: [SourceSegment]
    ) {
        self.controller = controller
        self.editSelection = editSelection
        self.segments = segments
        draft = ClipEditorDraft(segments: segments)
        if case .timelineClip(let id) = editSelection,
           controller.project.tracks.contains(where: { $0.kind == .audio && $0.clips.contains { $0.id == id } }) {
            let settings = controller.project.timelineClip(id: id)?.audioSettings ?? .neutral
            baselineAudioSettings = settings
            audioSettings = settings
        } else if let asset = controller.asset(for: editSelection), asset.hasAudio, !asset.hasVideo {
            baselineAudioSettings = .neutral
            audioSettings = .neutral
        } else {
            baselineAudioSettings = nil
            audioSettings = nil
        }
    }

    var canPlace: Bool {
        isKeyWindow && !segments.isEmpty && NSApp.modalWindow == nil
    }

    var isTimelineEntry: Bool {
        switch editSelection {
        case .timelineClip, .cutaway: true
        case .asset, .transition, .track, .project: false
        }
    }

    var hasUncommittedChanges: Bool {
        isTimelineEntry && (draft.hasChanges || audioSettings != baselineAudioSettings)
    }

    var canUpdate: Bool {
        isKeyWindow && hasUncommittedChanges && !segments.isEmpty && NSApp.modalWindow == nil
    }

    func setSegments(_ segments: [SourceSegment]) {
        guard !segments.isEmpty else {
            self.segments = []
            draft.replace(with: [])
            return
        }
        self.segments = segments
        draft.replace(with: segments)
        if case .asset(let id) = editSelection {
            controller.updateSourceEdit(assetID: id, segments: segments)
        }
    }

    func place(_ placement: PlacementAction) {
        guard canPlace else { return }
        _ = place(placement, onTrack: nil)
    }

    @discardableResult
    func place(_ placement: PlacementAction, onTrack trackID: UUID?) -> UUID? {
        guard !segments.isEmpty else {
            presentPlacementError(
                placement,
                trackID: trackID,
                message: ProjectTimelineError.emptyIncomingClip.localizedDescription
            )
            return nil
        }
        do {
            let placedID: UUID
            if let trackID {
                placedID = try controller.placeThrowing(
                    placement,
                    editing: editSelection,
                    segments: segments,
                    onTrack: trackID
                )
            } else {
                placedID = try controller.placeThrowing(
                    placement,
                    editing: editSelection,
                    segments: segments
                )
            }
            if let audioSettings, !audioSettings.isNeutral {
                try controller.updateAudioSettings(clipID: placedID, settings: audioSettings)
            }
            return placedID
        } catch {
            presentPlacementError(placement, trackID: trackID, message: error.localizedDescription)
            return nil
        }
    }

    func requestTrackPlacement(_ placement: PlacementAction) {
        guard canPlace else { return }
        trackPlacementAction = placement
    }

    @discardableResult
    func createTrackAndPlace(
        _ placement: PlacementAction,
        kind: TimelineTrackKind,
        name: String
    ) -> UUID? {
        guard !segments.isEmpty else {
            presentPlacementError(
                placement,
                trackID: nil,
                message: ProjectTimelineError.emptyIncomingClip.localizedDescription
            )
            return nil
        }
        do {
            return try controller.createTrackAndPlaceThrowing(
                placement,
                editing: editSelection,
                segments: segments,
                trackKind: kind,
                trackName: name,
                audioSettings: audioSettings
            ).clipID
        } catch {
            presentPlacementError(placement, trackID: nil, message: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func performUpdate() -> Bool {
        guard isTimelineEntry else { return false }
        guard !segments.isEmpty else {
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Updated",
                message: "Set a valid In and Out selection before updating the timeline clip."
            )
            return false
        }
        do {
            try controller.updateTimelineEntry(editSelection, segments: segments)
            if case .timelineClip(let id) = editSelection, let audioSettings {
                try controller.updateAudioSettings(clipID: id, settings: audioSettings)
            }
            objectWillChange.send()
            draft.commit()
            return true
        } catch {
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Updated",
                message: error.localizedDescription
            )
            return false
        }
    }

    func resetAudioSettings() {
        audioSettings = .neutral
    }

    func setKeyWindow(_ isKeyWindow: Bool) {
        self.isKeyWindow = isKeyWindow
    }

    private func presentPlacementError(
        _ placement: PlacementAction,
        trackID: UUID?,
        message: String
    ) {
        let trackName = trackID.flatMap { controller.project.track(id: $0)?.name }
        let destination = trackName.map { " Destination track: \($0)." } ?? ""
        presentedError = ProjectPresentedError(
            title: placement.failureTitle,
            message: message + destination
        )
    }
}

@MainActor
final class ClipEditorWindowCoordinator: ObservableObject {
    private let controller: ProjectController
    private var windows: [EditorSelection: ClipEditorWindowController] = [:]

    init(controller: ProjectController) {
        self.controller = controller
    }

    func open(_ editSelection: EditorSelection) {
        guard editSelection != .project,
              let asset = controller.asset(for: editSelection),
              let segments = controller.segments(for: editSelection) else { return }

        if let existing = windows[editSelection] {
            existing.showAndFocus()
            return
        }

        let commandContext = ClipPlacementCommandContext(
            controller: controller,
            editSelection: editSelection,
            segments: segments
        )
        let rootView = ClipEditorWindowView(
            controller: controller,
            asset: asset,
            editSelection: editSelection,
            initialSegments: segments,
            commandContext: commandContext
        )
        let editorName = ClipEditorMediaKind.name(hasVideo: asset.hasVideo)
        let windowController = ClipEditorWindowController(
            title: "\(asset.name) — \(editorName)",
            rootView: rootView,
            commandContext: commandContext
        )
        windowController.onClose = { [weak self] in
            self?.windows[editSelection] = nil
        }
        windows[editSelection] = windowController
        windowController.showAndFocus()
    }

    func requestCloseAll(completion: @escaping (Bool) -> Void) {
        close(Array(windows.values), at: 0, completion: completion)
    }

    private func close(
        _ windowControllers: [ClipEditorWindowController],
        at index: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < windowControllers.count else {
            completion(true)
            return
        }
        windowControllers[index].requestClose { [weak self] didClose in
            guard let self else {
                completion(false)
                return
            }
            guard didClose else {
                completion(false)
                return
            }
            self.close(windowControllers, at: index + 1, completion: completion)
        }
    }
}

@MainActor
private final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {
    let commandContext: ClipPlacementCommandContext
    var onClose: (() -> Void)?
    private var closeWasConfirmed = false
    private var pendingCloseCompletion: ((Bool) -> Void)?

    init<Content: View>(
        title: String,
        rootView: Content,
        commandContext: ClipPlacementCommandContext
    ) {
        self.commandContext = commandContext
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.collectionBehavior.insert(.participatesInCycle)
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 760)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func requestClose(completion: @escaping (Bool) -> Void) {
        guard pendingCloseCompletion == nil, let window else {
            completion(false)
            return
        }
        pendingCloseCompletion = completion
        window.performClose(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        commandContext.setKeyWindow(true)
        ExternalMediaOpenCoordinator.shared.activate(controller: commandContext.controller)
    }

    func windowDidResignKey(_ notification: Notification) {
        commandContext.setKeyWindow(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeWasConfirmed, commandContext.hasUncommittedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Update Clip Before Closing?"
        alert.informativeText = "This timeline clip has changes that have not been applied to the project."
        alert.addButton(withTitle: "Update Clip")
        alert.addButton(withTitle: "Close without Updating")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.commandContext.performUpdate() else {
                    let completion = self.pendingCloseCompletion
                    self.pendingCloseCompletion = nil
                    completion?(false)
                    return
                }
                self.closeWasConfirmed = true
                sender.performClose(nil)
            case .alertSecondButtonReturn:
                self.closeWasConfirmed = true
                sender.performClose(nil)
            default:
                let completion = self.pendingCloseCompletion
                self.pendingCloseCompletion = nil
                completion?(false)
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        commandContext.setKeyWindow(false)
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        onClose?()
        onClose = nil
        completion?(true)
    }
}

private struct ClipEditorWindowView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    var body: some View {
        SourceClipEditorView(
            controller: controller,
            asset: asset,
            editSelection: editSelection,
            initialSegments: initialSegments,
            commandContext: commandContext
        )
        .focusedObject(controller)
        .focusedObject(commandContext)
        .alert(item: Binding(
            get: {
                commandContext.trackPlacementAction == nil ? commandContext.presentedError : nil
            },
            set: { value in
                if value == nil { commandContext.presentedError = nil }
            }
        )) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .frame(minWidth: 900, minHeight: 760)
    }
}

private extension PlacementAction {
    var failureTitle: String {
        switch self {
        case .append: "Clip Could Not Be Appended to Track"
        case .insert: "Clip Could Not Be Inserted on Track"
        case .replaceRemainder: "Clip Could Not Be Added to Track"
        case .cutawaySourceAudio, .cutawayPrimaryAudio: "Clip Could Not Be Added to Timeline"
        }
    }
}
