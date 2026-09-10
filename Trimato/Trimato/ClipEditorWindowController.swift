import AppKit
import AVFoundation
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

enum ClipEditorCloseDecision {
    case update
    case discard
    case cancel
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
        guard let context = activeContext, context.isKeyWindow, context.hostWindow?.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
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
    @Published var closeConfirmationRequested = false
    @Published private(set) var trackPlacementIsAudioOnly = false
    private var draft: ClipEditorDraft
    private var baselineAudioSettings: AudioClipSettings?
    @Published var audioSettings: AudioClipSettings?
    @Published var filters: [ClipFilter] = []
    @Published var effectsReady = true
    @Published var voiceWorkBusy = false
    private var baselineFilters: [ClipFilter] = []
    var closeDecisionHandler: ((ClipEditorCloseDecision) -> Void)?
    private var pendingCloseDecision: ClipEditorCloseDecision?
    private var closeReviewActive = false
    private var isOpening = false
    private var pendingPlacements: [PlacementAction] = []
    var placementFeedback: ((String) -> Void)?

    func beginOpening() { isOpening = true }

    func finishOpening() {
        guard isOpening else { return }
        isOpening = false
        let pending = pendingPlacements
        pendingPlacements = []
        for placement in pending { place(placement) }
    }

    func cancelPendingPlacements() {
        pendingPlacements = []
        isOpening = false
    }

    private func confirmPlacement(_ placement: PlacementAction) {
        // Menu dispatch and the model update must finish before the result is spoken.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            if let placementFeedback { placementFeedback(placement.confirmation); return }
            guard let window = hostWindow, window.isKeyWindow else { return }
            NSAccessibility.post(element: window, notification: .announcementRequested,
                userInfo: [.announcement: placement.confirmation,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

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
        if let audioSettings {
            let normalized = Self.mainEqualizer(audio: audioSettings, filters: filters)
            self.audioSettings = normalized.0
            baselineAudioSettings = normalized.0
            filters = normalized.1
        }
        baselineFilters = filters
    }

    // Move the former Tone filter into the main EQ only when no existing EQ would be overwritten.
    static func mainEqualizer(audio: AudioClipSettings, filters: [ClipFilter]) -> (AudioClipSettings, [ClipFilter]) {
        guard ClipFilter.legacyTone(audio) == nil,
              let tone = filters.first(where: { $0.kind == .tone && $0.enabled }) else { return (audio, filters) }
        var settings = tone.toneSettings
        settings.gainDecibels = audio.gainDecibels
        settings.voice = audio.voice
        return (settings, filters.filter { $0.id != tone.id })
    }

    var canPlace: Bool {
        !segments.isEmpty
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
        hasUncommittedChanges && !segments.isEmpty
    }

    var hasPendingQuitChanges: Bool {
        hasUncommittedChanges || audioSettings != baselineAudioSettings || filters != baselineFilters
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
            let normalized = Self.mainEqualizer(audio: clip.audioSettings, filters: refreshed)
            if audioSettings != normalized.0 { audioSettings = normalized.0 }
            baselineAudioSettings = normalized.0
            refreshed = normalized.1
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
    }

    func place(_ placement: PlacementAction) {
        guard canPlace else { return }
        if isOpening {
            pendingPlacements.append(placement)
            return
        }
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
                    onTrack: trackID, audioSettings: audioSettings, filters: filters, announcesConfirmation: false
                )
            } else {
                placedID = try controller.placeThrowing(
                    placement,
                    editing: editSelection,
                    segments: segments, audioSettings: audioSettings, filters: filters, announcesConfirmation: false
                )
            }

            confirmPlacement(placement)
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

    var narrationTrack: TimelineTrack? {
        guard case .timelineClip(let id) = editSelection,
              controller.asset(for: editSelection)?.recordingPurpose.isNarration == true else { return nil }
        return controller.project.tracks.first { $0.kind == .audio && $0.clips.contains { $0.id == id } }
    }

    func validateVoice(_ voice: VoiceAdjustment) async throws {
        guard let asset = controller.asset(for: editSelection), let url = controller.resolveURL(for: asset) else {
            throw AudioCaptureError.message("Relink this recording before adjusting its voice.")
        }
        var audio = audioSettings ?? .neutral
        audio.voice = voice
        let output = try await ClipFilterRenderer.render(source: url, filters: filters, audio: true,
            duration: asset.duration.seconds, segments: segments, audioSettings: audio)
        try? FileManager.default.removeItem(at: output)
        try Task.checkCancellation()
    }

    func applyVoiceToTrack(_ voice: VoiceAdjustment) async throws {
        guard let track = narrationTrack else { throw ProjectTimelineError.clipNotFound }
        try await controller.applyVoiceToTrack(track.id, settings: voice)
        baselineAudioSettings?.voice = voice
        audioSettings?.voice = voice
    }

    func voiceMixedPreview(filters proposedFilters: [ClipFilter]? = nil, audio proposedAudio: AudioClipSettings? = nil) async throws -> URL {
        guard case .timelineClip(let id) = editSelection else { throw ProjectTimelineError.clipNotFound }
        var project = controller.project
        try project.updateTrackClip(id: id, segments: segments)
        try project.setClipEffects(id: id, audio: proposedAudio ?? audioSettings, filters: proposedFilters ?? filters)
        guard let clip = project.timelineClip(id: id) else { throw ProjectTimelineError.clipNotFound }
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: controller.resolvedMediaURLs())
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        guard result.spatialAudio == nil else {
            throw SpatialAudioError.unsupported("Voice processing previews are not supported for Spatial Audio yet.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-voice-mix-\(UUID()).wav")
        do {
            try await AudioOnlyExporter.export(asset: result.composition, audioMix: result.audioMix,
                timeRange: CMTimeRange(start: clip.visibleTimelineStart.cmTime, duration: clip.visibleDuration.cmTime),
                format: .wav24, to: url, progress: { _ in })
            try Task.checkCancellation()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func resetAudioSettings() {
        audioSettings = .neutral
    }

    func setKeyWindow(_ isKeyWindow: Bool) {
        self.isKeyWindow = isKeyWindow
    }

    func requestCloseConfirmation() {
        guard !closeReviewActive else { return }
        closeReviewActive = true
        closeConfirmationRequested = true
    }

    func chooseCloseDecision(_ decision: ClipEditorCloseDecision) {
        pendingCloseDecision = decision
        closeConfirmationRequested = false
    }

    func completeCloseConfirmation() {
        guard closeReviewActive else { return }
        closeReviewActive = false
        let decision = pendingCloseDecision ?? .cancel
        pendingCloseDecision = nil
        closeDecisionHandler?(decision)
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
final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {
    let commandContext: ClipPlacementCommandContext
    var onClose: (() -> Void)?
    private var closeWasConfirmed = false
    private var pendingCloseCompletion: ((Bool) -> Void)?
    private var confirmedDecision: ClipEditorCloseDecision?
    private let quitDraftID = UUID()

    init<Content: View>(
        title: String,
        rootView: Content,
        commandContext: ClipPlacementCommandContext
    ) {
        self.commandContext = commandContext
        commandContext.beginOpening()
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
        commandContext.closeDecisionHandler = { [weak self] decision in
            self?.handleCloseDecision(decision)
        }
        commandContext.controller.quitEdits.register(quitDraftID, entry: .init(priority: 100,
            hasChanges: { [weak commandContext] in commandContext?.hasPendingQuitChanges == true },
            validate: { [weak commandContext] in
                guard let commandContext, !commandContext.segments.isEmpty else {
                    throw QuitDraftError(message: "Set a valid In and Out range in the clip editor before saving.")
                }
                guard commandContext.isTimelineEntry else {
                    throw QuitDraftError(message: "Add the source clip to a track before saving its audio settings.")
                }
            }, apply: { [weak commandContext] in
                guard let commandContext, commandContext.performUpdate() else {
                    throw QuitDraftError(message: commandContext?.presentedError?.message ?? "The clip could not be updated.")
                }
            }))
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
        // An editing sheet must resolve its own draft before a normal editor close.
        guard window.attachedSheet == nil else { completion(false); return }
        pendingCloseCompletion = completion
        // This is a coordinated close request, not a synthetic close-button action.
        // performClose can be ignored while AppKit is transitioning modal windows.
        if windowShouldClose(window) { window.close() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        commandContext.setKeyWindow(true)
        ClipEditorCommandRouter.shared.activate(commandContext)
        ExternalMediaOpenCoordinator.shared.activate(controller: commandContext.controller)
    }

    func windowDidEndSheet(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.finishConfirmedClose() }
        // Refresh menu ownership after the native sheet has actually detached.
        guard window?.isKeyWindow == true else { return }
        commandContext.setKeyWindow(true)
        ClipEditorCommandRouter.shared.activate(commandContext)
    }

    func windowDidResignKey(_ notification: Notification) {
        commandContext.setKeyWindow(false)
        ClipEditorCommandRouter.shared.deactivate(commandContext)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeWasConfirmed, commandContext.hasUncommittedChanges else { return true }
        commandContext.requestCloseConfirmation()
        return false
    }

    private func handleCloseDecision(_ decision: ClipEditorCloseDecision) {
        confirmedDecision = decision
        Task { @MainActor [weak self] in self?.finishConfirmedClose() }
    }

    private func finishConfirmedClose() {
        guard let window, window.attachedSheet == nil, let decision = confirmedDecision else { return }
        confirmedDecision = nil
        switch decision {
        case .update:
            guard commandContext.performUpdate() else { finishCancelledClose(); return }
            closeWasConfirmed = true
            window.close()
        case .discard:
            closeWasConfirmed = true
            window.close()
        case .cancel:
            finishCancelledClose()
        }
    }

    private func finishCancelledClose() {
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        completion?(false)
    }

    func windowWillClose(_ notification: Notification) {
        commandContext.cancelPendingPlacements()
        commandContext.controller.quitEdits.remove(quitDraftID)
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
        .onExitCommand {
            guard commandContext.hostWindow?.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return }
            commandContext.hostWindow?.performClose(nil)
        }
        .sheet(isPresented: $commandContext.closeConfirmationRequested,
               onDismiss: commandContext.completeCloseConfirmation) {
            ClipEditorCloseConfirmationView(commandContext: commandContext)
        }
        .applicationMessage(
            commandContext.trackPlacementAction == nil
                ? commandContext.presentedError.map {
                    ApplicationMessageDescriptor(title: $0.title, message: $0.message)
                }
                : nil
        ) {
            commandContext.presentedError = nil
        }
        .frame(minWidth: 740, minHeight: 580)
    }
}

private struct ClipEditorCloseConfirmationView: View {
    @ObservedObject var commandContext: ClipPlacementCommandContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update Clip Before Closing?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("This timeline clip has changes that have not been applied to the project.")
            HStack {
                Button("Cancel") { commandContext.chooseCloseDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Close without Updating", role: .destructive) {
                    commandContext.chooseCloseDecision(.discard)
                }
                NativeDefaultButton(title: "Update Clip") {
                    commandContext.chooseCloseDecision(.update)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
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
