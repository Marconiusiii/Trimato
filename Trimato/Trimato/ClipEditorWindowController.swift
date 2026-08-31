import AppKit
import Combine
import SwiftUI

nonisolated enum ClipEditorMediaKind {
    static func name(hasVideo: Bool) -> String {
        hasVideo ? "Video Clip Editor" : "Audio Clip Editor"
    }
}

nonisolated enum ClipEditorLayout {
    static func fitting(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return CGRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
                      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
                      width: width, height: height)
    }
}

enum ClipEditorPlacementCommand: CaseIterable, Identifiable {
    case update, append, appendToTrack, insert, insertToTrack, overwrite, overwriteOnTrack
    case insertOnTopWithAudio, insertOnTopOverAudio

    var id: Self { self }
    var title: String {
        switch self {
        case .update: "Update Clip"
        case .append: PlacementAction.append.title
        case .appendToTrack: "Append to Track…"
        case .insert: PlacementAction.insert.title
        case .insertToTrack: "Insert on Track…"
        case .overwrite: PlacementAction.replaceRemainder.title
        case .overwriteOnTrack: "Insert and Overwrite on Track…"
        case .insertOnTopWithAudio: PlacementAction.cutawaySourceAudio.title
        case .insertOnTopOverAudio: PlacementAction.cutawayPrimaryAudio.title
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .update: "u"
        case .append, .appendToTrack: "e"
        case .insert, .insertToTrack: "w"
        case .overwrite, .overwriteOnTrack: "d"
        case .insertOnTopWithAudio, .insertOnTopOverAudio: "q"
        }
    }
    var modifiers: EventModifiers {
        switch self {
        case .update: .command
        case .appendToTrack, .insertToTrack, .overwriteOnTrack, .insertOnTopOverAudio: .option
        default: []
        }
    }
}

/// AppKit Clip Editor windows live outside a SwiftUI document scene. Publish their
/// native key-window owner explicitly so the app menu does not depend on a child
/// popup or a SwiftUI focused value crossing that scene boundary.
@MainActor
final class ClipEditorCommandRouter: ObservableObject {
    static let shared = ClipEditorCommandRouter()
    @Published private(set) var activeContext: ClipPlacementCommandContext?
    private var changes: AnyCancellable?

    func isAvailable(_ command: ClipEditorPlacementCommand) -> Bool {
        guard let context = activeContext else { return false }
        if command == .update { return context.canUpdate }
        guard context.canPlace else { return false }
        if command == .insertOnTopWithAudio || command == .insertOnTopOverAudio {
            return context.controller.asset(for: context.editSelection)?.hasVideo == true
        }
        return true
    }

    func perform(_ command: ClipEditorPlacementCommand) {
        guard isAvailable(command), let context = activeContext else { return }
        switch command {
        case .update: context.performUpdate()
        case .append: context.place(.append)
        case .appendToTrack: context.requestTrackPlacement(.append)
        case .insert: context.place(.insert)
        case .insertToTrack: context.requestTrackPlacement(.insert)
        case .overwrite: context.place(.replaceRemainder)
        case .overwriteOnTrack: context.requestTrackPlacement(.replaceRemainder)
        case .insertOnTopWithAudio: context.place(.cutawaySourceAudio)
        case .insertOnTopOverAudio: context.place(.cutawayPrimaryAudio)
        }
    }

    func activate(_ context: ClipPlacementCommandContext) {
        guard activeContext !== context else { return }
        activeContext = context
        changes = context.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func deactivate(_ context: ClipPlacementCommandContext) {
        guard activeContext === context else { return }
        changes = nil
        activeContext = nil
    }
}

@MainActor
final class ClipPlacementCommandContext: ObservableObject {
    let controller: ProjectController
    let editSelection: EditorSelection
    @Published private(set) var segments: [SourceSegment]
    @Published private(set) var isKeyWindow = false
    weak var hostWindow: NSWindow?
    @Published var presentedError: ProjectPresentedError?
    @Published var trackPlacementAction: PlacementAction?
    @Published private(set) var trackPlacementIsAudioOnly = false
    private var draft: ClipEditorDraft
    private var baselineAudioSettings: AudioClipSettings?
    @Published var audioSettings: AudioClipSettings?
    @Published var filters: [ClipFilter] = []
    @Published var effectsReady = true
    private var baselineFilters: [ClipFilter] = []

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
        let clipID: UUID?
        switch editSelection {
        case .timelineClip(let id), .cutaway(let id): clipID = id
        default: clipID = nil
        }
        filters = clipID.flatMap { controller.project.timelineClip(id: $0)?.filters } ?? []
        if let settings = audioSettings, let tone = ClipFilter.legacyTone(settings) {
            if !filters.contains(where: { $0.kind == .tone }) { filters.append(tone) }
            var gainOnly = AudioClipSettings()
            gainOnly.gainDecibels = settings.gainDecibels
            audioSettings = gainOnly
            baselineAudioSettings = gainOnly
        }
        baselineFilters = filters
    }

    var canPlace: Bool {
        isKeyWindow && effectsReady && !segments.isEmpty && hostWindow?.attachedSheet == nil && NSApp.modalWindow == nil
    }

    var isTimelineEntry: Bool {
        switch editSelection {
        case .timelineClip, .cutaway: true
        case .asset, .transition, .track, .project: false
        }
    }

    var hasUncommittedChanges: Bool {
        isTimelineEntry && (draft.hasChanges || audioSettings != baselineAudioSettings || filters != baselineFilters)
    }

    var canUpdate: Bool {
        isKeyWindow && effectsReady && hasUncommittedChanges && !segments.isEmpty && hostWindow?.attachedSheet == nil && NSApp.modalWindow == nil
    }

    func refreshCommittedEffects() {
        guard isTimelineEntry, !hasUncommittedChanges else { return }
        let id: UUID
        switch editSelection {
        case .timelineClip(let clipID), .cutaway(let clipID): id = clipID
        default: return
        }
        guard let clip = controller.project.timelineClip(id: id) else { return }
        var refreshed = clip.filters
        if audioSettings != nil {
            if let tone = ClipFilter.legacyTone(clip.audioSettings), !refreshed.contains(where: { $0.kind == .tone }) {
                // Keep identity when refreshing an unchanged legacy Tone setting.
                var migrated = tone
                migrated.id = filters.first(where: { $0.kind == .tone })?.id ?? tone.id
                refreshed.append(migrated)
            }
            var gain = AudioClipSettings()
            gain.gainDecibels = clip.audioSettings.gainDecibels
            if audioSettings != gain { audioSettings = gain }
            baselineAudioSettings = gain
        }
        if filters != refreshed { filters = refreshed }
        baselineFilters = refreshed
    }

    func acceptExternalGeneratorUpdate() {
        guard let segments = controller.segments(for: editSelection) else { return }
        self.segments = segments
        draft = ClipEditorDraft(segments: segments)
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
                    onTrack: trackID, audioSettings: audioSettings, filters: filters
                )
            } else {
                placedID = try controller.placeThrowing(
                    placement,
                    editing: editSelection,
                    segments: segments, audioSettings: audioSettings, filters: filters
                )
            }

            return placedID
        } catch {
            presentPlacementError(placement, trackID: trackID, message: error.localizedDescription)
            return nil
        }
    }

    func requestTrackPlacement(_ placement: PlacementAction) {
        guard canPlace else { return }
        trackPlacementIsAudioOnly = false
        trackPlacementAction = placement
    }

    func requestAudioOnlyTrackPlacement(_ placement: PlacementAction) {
        guard canPlace else { return }
        trackPlacementIsAudioOnly = true
        trackPlacementAction = placement
    }

    func dismissTrackPlacement() {
        trackPlacementAction = nil
        trackPlacementIsAudioOnly = false
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
                audioSettings: audioSettings, filters: filters
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
            try controller.updateClipDraft(editSelection, segments: segments, audio: audioSettings, filters: filters)
            baselineAudioSettings = audioSettings
            baselineFilters = filters
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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.collectionBehavior.insert(.participatesInCycle)
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 620)
        window.center()
        super.init(window: window)
        window.delegate = self
        commandContext.hostWindow = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        if let window, let screen = window.screen ?? NSScreen.main {
            window.setFrame(ClipEditorLayout.fitting(window.frame, in: screen.visibleFrame), display: false)
        }
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
        ClipEditorCommandRouter.shared.activate(commandContext)
        ExternalMediaOpenCoordinator.shared.activate(controller: commandContext.controller)
    }

    func windowDidResignKey(_ notification: Notification) {
        commandContext.setKeyWindow(false)
        ClipEditorCommandRouter.shared.deactivate(commandContext)
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
        ClipEditorCommandRouter.shared.deactivate(commandContext)
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
        .frame(minWidth: 740, minHeight: 580)
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
