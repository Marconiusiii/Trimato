import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

enum EditorSelection: Hashable {
    case project
    case asset(UUID)
    case timelineClip(UUID)
    case cutaway(UUID)
    case transition(UUID)
    case track(UUID)
}

struct ProjectPresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class ProjectController: ObservableObject {
    let document: ProjectDocument

    @Published var selection: EditorSelection = .project
    @Published var timelinePlayhead = ProjectTime.zero
    @Published var activeTimelineTrackID: UUID?
    @Published var timelineHasKeyboardFocus = false
    @Published var transitionRequest: TransitionRequest?
    @Published private(set) var transitionRequestReturnsToEditor = false
    @Published private(set) var editorFocusRestoreRequest = 0
    @Published private(set) var timelineFocusRestoreRequest = 0
    @Published private(set) var timelineTrackPickerFocusRestoreRequest = 0
    @Published private(set) var timelineListFocusRestoreRequest = 0
    @Published private(set) var timelineContentRevision = 0
    @Published private(set) var applyingTransitionName: String?
    @Published private(set) var applyingTransitionProgress: Double?
    @Published var isImporting = false
    @Published var isShowingProjectSettings = false
    @Published var presentedError: ProjectPresentedError?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double?
    @Published private(set) var isPresentingExportPanel = false
    @Published private(set) var copiedTimelineClipID: UUID?
    @Published private(set) var movingTimelineClipID: UUID?
    private(set) var timelineFocusRestoreTarget: TimelineElementSelection?

    private var cancellables: Set<AnyCancellable> = []
    private var accessedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?
    private weak var projectSaveCoordinator: ProjectWindowSaveCoordinator?
    private weak var projectUndoManager: UndoManager?
    private weak var projectPlayer: ProjectPlayerViewModel?
    private var projectWithPreparedTransitionPreview: TrimatoProject?
    private var closeProjectAction: (() -> Void)?
    private var editorDirectClipIDs: [UUID: UUID] = [:]
    private let cacheOwnerID = UUID()

    init(document: ProjectDocument) {
        self.document = document
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateCacheProtection(for: document.project)
        activeTimelineTrackID = Self.preferredTimelineTrackID(in: document.project)
    }

    deinit {
        exportTask?.cancel()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        let cacheOwnerID = cacheOwnerID
        Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: cacheOwnerID) }
    }

    func resolvedMediaURLs() -> [UUID: URL] {
        var result: [UUID: URL] = [:]
        let trackIDs = project.tracks.flatMap(\.clips).map(\.assetID)
        let usedIDs = Set(trackIDs + project.primaryTimeline.map(\.assetID) + project.cutaways.map(\.assetID))
        for id in usedIDs {
            guard let asset = project.asset(id: id), let url = resolveURL(for: asset) else { continue }
            result[id] = url
        }
        return result
    }

    func installSaveCoordinator(_ coordinator: ProjectWindowSaveCoordinator) {
        projectSaveCoordinator = coordinator
    }

    func installUndoManager(_ undoManager: UndoManager) {
        projectUndoManager = undoManager
    }

    func installProjectPlayer(_ player: ProjectPlayerViewModel) {
        projectPlayer = player
    }

    func installCloseProjectAction(_ action: @escaping () -> Void) {
        closeProjectAction = action
    }

    func closeProject() {
        closeProjectAction?()
    }

    var canExportProject: Bool {
        !isExporting &&
            !isPresentingExportPanel &&
            project.tracks.contains(where: { !$0.clips.isEmpty }) &&
            (projectPlayer?.hasValidExportSelection ?? true)
    }

    func saveProjectDocument() {
        projectSaveCoordinator?.save { [weak self] succeeded in
            if succeeded { self?.announce("Project saved") }
        }
    }

    func saveProjectDocumentAs() {
        projectSaveCoordinator?.saveAs { [weak self] succeeded in
            if succeeded { self?.announce("Project saved") }
        }
    }

    func relinkSelectedAsset() {
        guard let asset = selectedAsset, NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink \(asset.name)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            do {
                var replacement = try await ProjectImportCoordinator.importAsset(at: url)
                let previousProxyCacheKey = asset.proxyCacheKey
                replacement.id = asset.id
                mutateProject(actionName: "Relink Media") { project in
                    guard let index = project.media.firstIndex(where: { $0.id == asset.id }) else { return }
                    replacement.name = project.media[index].name
                    replacement.sourceEdit = project.media[index].sourceEdit
                    project.media[index] = replacement
                }
                if previousProxyCacheKey != replacement.proxyCacheKey {
                    try? await MediaCacheManager.shared.removeProxy(cacheKey: previousProxyCacheKey)
                }
                announce("Media relinked")
            } catch {
                presentedError = ProjectPresentedError(
                    title: "Relink Failed",
                    message: error.localizedDescription
                )
                announce("Relink failed")
            }
        }
    }

    func exportProject() {
        guard canExportProject, NSApp.modalWindow == nil else { return }
        let exportRange = projectPlayer?.exportRange
        let urls = resolvedMediaURLs()
        let requiredIDs = Set(project.tracks.flatMap(\.clips).map(\.assetID) + project.primaryTimeline.map(\.assetID) + project.cutaways.map(\.assetID))
        guard requiredIDs.allSatisfy({ urls[$0] != nil }) else {
            presentedError = ProjectPresentedError(
                title: "Media Is Offline",
                message: "Relink offline media before exporting the project."
            )
            announce("Relink offline media before exporting")
            return
        }

        let formats = ExportFormat.projectFormats.filter { format in
            (format.isAudioOnly && project.hasTimelineAudio) ||
                (!format.isAudioOnly && project.hasTimelineVideo)
        }
        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let savePanel = ExportSavePanel(
            title: "Export Project",
            baseName: project.name,
            formats: formats
        )
        isPresentingExportPanel = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await savePanel.selection(parentWindow: parentWindow)
            self.isPresentingExportPanel = false
            guard let selection else { return }
            self.startProjectExport(
                format: selection.format,
                outputURL: selection.url,
                exportRange: exportRange,
                mediaURLs: urls
            )
        }
    }

    private func startProjectExport(
        format: ExportFormat,
        outputURL: URL,
        exportRange: ProjectTimeRange?,
        mediaURLs: [UUID: URL]
    ) {
        isExporting = true
        exportProgress = 0
        announce("Export started")
        let projectSnapshot = project
        exportTask = Task { @MainActor in
            do {
                try await ProjectExporter.export(
                    project: projectSnapshot,
                    mediaURLs: mediaURLs,
                    timeRange: exportRange,
                    format: format,
                    to: outputURL
                ) { [weak self] progress in
                    self?.exportProgress = progress
                }
                isExporting = false
                exportProgress = nil
                ExportNotificationCenter.postExportCompleted(filename: outputURL.lastPathComponent)
                announce("Export complete")
            } catch is CancellationError {
                isExporting = false
                exportProgress = nil
                announce("Export canceled")
            } catch {
                isExporting = false
                exportProgress = nil
                presentedError = ProjectPresentedError(
                    title: "Export Failed",
                    message: error.localizedDescription
                )
                announce("Export failed")
            }
            exportTask = nil
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportTask?.cancel()
        announce("Canceling export")
    }

    var project: TrimatoProject { document.project }

    var selectedAsset: MediaAssetRecord? {
        switch selection {
        case .asset(let id): return project.asset(id: id)
        case .timelineClip(let id):
            return project.timelineClip(id: id).flatMap { project.asset(id: $0.assetID) }
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id }).flatMap { project.asset(id: $0.assetID) }
        case .transition, .track, .project: return nil
        }
    }

    var selectedTimelineClip: TimelineClip? {
        guard case .timelineClip(let id) = selection else { return nil }
        return project.timelineClip(id: id)
    }

    var selectedCutaway: TimelineCutaway? {
        guard case .cutaway(let id) = selection else { return nil }
        return project.cutaways.first { $0.id == id }
    }

    var selectedTransition: TimelineTransition? {
        guard case .transition(let id) = selection else { return nil }
        return project.transition(id: id)
    }

    var activeTimelineTrack: TimelineTrack? {
        guard let activeTimelineTrackID else { return project.tracks.first }
        return project.track(id: activeTimelineTrackID)
    }

    static func preferredTimelineTrackID(in project: TrimatoProject) -> UUID? {
        if let primaryVideo = project.tracks.first(where: { $0.role == .primaryVideo }) {
            return primaryVideo.id
        }
        if let primaryAudio = project.tracks.first(where: { $0.role == .primaryAudio }) {
            return primaryAudio.id
        }
        if let transitionTrack = project.transitions.compactMap({ project.track(id: $0.trackID) }).first {
            return transitionTrack.id
        }
        return project.tracks.first?.id
    }

    func focusTimelineElement(_ element: TimelineElementSelection) {
        switch element {
        case .clip(let id):
            selection = .timelineClip(id)
            if let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
                editorDirectClipIDs[track.id] = id
            }
        case .transition(let id): selection = .transition(id)
        }
    }

    func trimTimelineClipEnd(id: UUID) throws {
        try mutateProjectThrowing(actionName: "Trim Timeline Clip End") {
            try $0.trimTrackClipEnd(id: id, at: timelinePlayhead)
        }
        selection = .timelineClip(id)
        announce("Clip end trimmed to project playhead")
    }

    func selectAdjacentTrack(_ offset: Int, restoreTimelineFocus: Bool = true) {
        guard !project.tracks.isEmpty else { return }
        let current = activeTimelineTrackID.flatMap { id in project.tracks.firstIndex { $0.id == id } } ?? 0
        let destination = min(max(current + offset, 0), project.tracks.count - 1)
        activeTimelineTrackID = project.tracks[destination].id
        let track = project.tracks[destination]
        let clip = editorDirectClip(on: track, at: timelinePlayhead)
        announce(Self.activeTrackAnnouncement(trackName: track.name, clipName: clip?.displayName))
        guard restoreTimelineFocus else { return }
        if let clip {
            requestTimelineFocusRestore(to: .clip(clip.id))
        } else {
            requestTimelineListFocusRestore()
        }
    }

    func positionActiveAdditionalTrackClip(edge: TimelineClipPositionEdge, at playhead: ProjectTime) {
        guard let track = activeTimelineTrack,
              let clip = editorDirectClip(on: track, at: playhead) else {
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Moved",
                message: "The active track does not contain a clip to move."
            )
            return
        }
        do {
            try mutateProjectThrowing(actionName: edge == .head ? "Move Clip Head" : "Move Clip Tail") {
                try $0.positionAdditionalTrackClip(id: clip.id, edge: edge, at: playhead)
            }
            editorDirectClipIDs[track.id] = clip.id
            let edgeName = edge == .head ? "head" : "tail"
            let time = ProjectPlayerViewModel.accessibilityTimeLabel(
                time: playhead,
                showingFrames: false,
                frameRate: project.format.frameRate ?? 30
            )
            announce("\(clip.displayName), \(track.name) track, \(edgeName) moved to \(time)")
        } catch {
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Moved",
                message: error.localizedDescription
            )
        }
    }

    func trimActiveTrackClip(edge: TimelineClipPositionEdge, at playhead: ProjectTime) {
        guard let track = activeTimelineTrack,
              let clip = editorDirectClip(on: track, at: playhead) else {
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Trimmed",
                message: "The active track does not contain a clip to trim."
            )
            return
        }
        do {
            try mutateProjectThrowing(actionName: edge == .head ? "Trim Clip Start" : "Trim Clip End") {
                if edge == .head {
                    try Self.trimTrackClipStart(in: &$0, id: clip.id, at: playhead)
                } else {
                    try $0.trimTrackClipEnd(id: clip.id, at: playhead)
                }
            }
            editorDirectClipIDs[track.id] = clip.id
            let edgeName = edge == .head ? "start" : "end"
            let time = ProjectPlayerViewModel.accessibilityTimeLabel(
                time: playhead,
                showingFrames: false,
                frameRate: project.format.frameRate ?? 30
            )
            announce("\(clip.displayName), \(track.name) track, \(edgeName) trimmed to \(time)")
        } catch {
            let message: String
            if let timelineError = error as? ProjectTimelineError,
               timelineError == .cannotTrimAtPlayhead {
                let edgeName = edge == .head ? "start" : "end"
                message = "Move the project playhead inside the selected clip before trimming its \(edgeName)."
            } else {
                message = error.localizedDescription
            }
            presentedError = ProjectPresentedError(
                title: "Clip Could Not Be Trimmed",
                message: message
            )
        }
    }

    private static func trimTrackClipStart(
        in project: inout TrimatoProject,
        id: UUID,
        at playhead: ProjectTime
    ) throws {
        project.ensureTrackModel()
        guard let trackIndex = project.tracks.firstIndex(where: { track in
            track.clips.contains { $0.id == id }
        }), let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let clip = project.tracks[trackIndex].clips[clipIndex]
        guard playhead > clip.timelineStart, playhead < clip.timelineEnd else {
            throw ProjectTimelineError.cannotTrimAtPlayhead
        }

        var amountToRemove = playhead - clip.timelineStart
        var retainedSegments: [SourceSegment] = []
        for segment in clip.segments {
            if amountToRemove >= segment.duration {
                amountToRemove = amountToRemove - segment.duration
                continue
            }
            if amountToRemove.isPositive {
                retainedSegments.append(SourceSegment(sourceRange: ProjectTimeRange(
                    start: segment.sourceRange.start + amountToRemove,
                    duration: segment.duration - amountToRemove
                )))
                amountToRemove = .zero
            } else {
                retainedSegments.append(segment)
            }
        }
        guard !retainedSegments.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        project.tracks[trackIndex].clips[clipIndex].segments = retainedSegments
        project.tracks[trackIndex].clips[clipIndex].timelineStart = playhead
    }

    func addTrack(kind: TimelineTrackKind, name: String?) {
        var createdID: UUID?
        mutateProject(actionName: "Add \(kind.title) Track") {
            createdID = $0.createTrack(kind: kind, name: name)
        }
        activeTimelineTrackID = createdID
    }

    func renameActiveTrack(to name: String) throws {
        guard let activeTimelineTrackID else { throw ProjectTimelineError.trackNotFound }
        try mutateProjectThrowing(actionName: "Rename Track") {
            try $0.renameTrack(id: activeTimelineTrackID, to: name)
        }
    }

    func moveActiveTrack(by offset: Int) {
        guard let activeTimelineTrackID else { return }
        do {
            try mutateProjectThrowing(actionName: "Move Track") { try $0.moveTrack(id: activeTimelineTrackID, by: offset) }
        } catch { announce(error.localizedDescription) }
    }

    func deleteActiveTrack() {
        guard let activeTimelineTrackID else { return }
        do {
            try mutateProjectThrowing(actionName: "Delete Track") { try $0.removeTrack(id: activeTimelineTrackID) }
            self.activeTimelineTrackID = Self.preferredTimelineTrackID(in: project)
            selection = .project
        } catch { announce(error.localizedDescription) }
    }

    func addTransition(_ transition: TimelineTransition) throws {
        try mutateProjectThrowing(actionName: "Add Transition") { try $0.addTransition(transition) }
        selection = .transition(transition.id)
    }

    func addTransitions(_ additions: [TimelineTransition], selectAddedTransition: Bool = true) throws {
        guard !additions.isEmpty else { return }
        var added: [TimelineTransition] = []
        try mutateProjectThrowing(actionName: additions.count == 1 ? "Add Transition" : "Add Transitions") { project in
            added = try project.addTransitionBatch(additions)
        }
        if selectAddedTransition, let transition = primaryTransition(in: added) {
            selection = .transition(transition.id)
        }
    }

    func requestTransitionForSelection(mode: TransitionRequest.Mode = .standard) {
        guard let clip = selectedTimelineClip,
              let track = project.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else {
            announce("Focus a timeline clip first")
            return
        }
        activeTimelineTrackID = track.id
        transitionRequestReturnsToEditor = false
        transitionRequest = TransitionRequest(trackID: track.id, clipID: clip.id, mode: mode)
    }

    func requestTransition(at time: ProjectTime, mode: TransitionRequest.Mode = .standard) {
        guard let track = activeTimelineTrack,
              let clip = track.sortedClips.first(where: { time >= $0.timelineStart && time <= $0.timelineEnd }) else {
            announce("Move the playhead to a clip first")
            return
        }
        transitionRequestReturnsToEditor = true
        transitionRequest = TransitionRequest(trackID: track.id, clipID: clip.id, mode: mode)
    }

    func requestQuickTransition(at time: ProjectTime, mode: TransitionRequest.Mode) {
        requestTransition(at: time, mode: mode)
    }

    func requestEditorFocusRestore() {
        editorFocusRestoreRequest += 1
    }

    func requestTimelineFocusRestore(to element: TimelineElementSelection) {
        timelineFocusRestoreTarget = element
        timelineFocusRestoreRequest += 1
    }

    func requestTimelineTrackPickerFocusRestore() {
        timelineTrackPickerFocusRestoreRequest += 1
    }

    func requestTimelineListFocusRestore() {
        timelineListFocusRestoreRequest += 1
    }

    func beginApplyingTransitions(_ transitions: [TimelineTransition]) {
        let primary = transitions.first { transition in
            if case .video = transition.kind { return true }
            return false
        } ?? transitions.first
        applyingTransitionName = primary?.displayName ?? "Transition"
        applyingTransitionProgress = 0
    }

    func finishApplyingTransition() {
        applyingTransitionName = nil
        applyingTransitionProgress = nil
    }

    func applyTransitions(
        _ additions: [TimelineTransition],
        selectAddedTransition: Bool
    ) async throws {
        guard !additions.isEmpty else { return }
        let previous = project
        var candidate = previous
        let added = try candidate.addTransitionBatch(additions)
        guard let projectPlayer else {
            throw ProjectTimelineError.transitionNotAvailable("The project preview is not ready.")
        }

        beginApplyingTransitions(added)
        do {
            try await projectPlayer.prepareTransitionPreview(
                project: candidate,
                mediaURLs: resolvedMediaURLs(),
                initialTime: timelinePlayhead,
                progress: { [weak self] progress in
                    self?.applyingTransitionProgress = max(
                        self?.applyingTransitionProgress ?? 0,
                        min(max(progress, 0), 1)
                    )
                }
            )
            projectWithPreparedTransitionPreview = candidate
            apply(
                candidate,
                undoingTo: previous,
                actionName: added.count == 1 ? "Add Transition" : "Add Transitions"
            )
            if selectAddedTransition, let transition = primaryTransition(in: added) {
                selection = .transition(transition.id)
            }
            try? await Task.sleep(for: .milliseconds(150))
            finishApplyingTransition()
        } catch {
            finishApplyingTransition()
            throw error
        }
    }

    func applyTransitionsFromEditor(_ additions: [TimelineTransition]) async throws {
        try await applyTransitions(additions, selectAddedTransition: false)
    }

    private func primaryTransition(in transitions: [TimelineTransition]) -> TimelineTransition? {
        transitions.first { transition in
            if case .video = transition.kind { return true }
            return false
        } ?? transitions.first
    }

    func consumePreparedTransitionPreview(for project: TrimatoProject) -> Bool {
        guard projectWithPreparedTransitionPreview == project else {
            projectWithPreparedTransitionPreview = nil
            return false
        }
        projectWithPreparedTransitionPreview = nil
        return true
    }

    func updateTransition(_ transition: TimelineTransition) throws {
        try mutateProjectThrowing(actionName: "Update Transition") { try $0.updateTransition(transition) }
        selection = .transition(transition.id)
    }

    func updateAudioSettings(clipID: UUID, settings: AudioClipSettings) throws {
        try mutateProjectThrowing(actionName: "Adjust Clip Audio") {
            try $0.updateAudioSettings(clipID: clipID, settings: settings)
        }
    }

    func deleteTransition(id: UUID) {
        mutateProject(actionName: "Delete Transition") { $0.removeTransition(id: id) }
        selection = .project
    }

    func primaryTimelineClip(at time: ProjectTime) -> TimelineClip? {
        var cursor = ProjectTime.zero
        for clip in project.primaryTimeline {
            let end = cursor + clip.duration
            if time > cursor, time < end { return clip }
            cursor = end
        }
        return nil
    }

    func editorClip(at time: ProjectTime) -> TimelineClip? {
        guard let track = activeTimelineTrack else { return nil }
        let clips = track.sortedClips
        if let incoming = clips.first(where: { $0.timelineStart == time }) { return incoming }
        if let containing = clips.first(where: { time >= $0.timelineStart && time < $0.timelineEnd }) {
            return containing
        }
        if let following = clips.first(where: { $0.timelineStart > time }) { return following }
        return clips.last(where: { $0.timelineEnd == time })
    }

    private func editorDirectClip(on track: TimelineTrack, at time: ProjectTime) -> TimelineClip? {
        if let selected = selectedTimelineClip,
           track.clips.contains(where: { $0.id == selected.id }) {
            editorDirectClipIDs[track.id] = selected.id
            return selected
        }
        if let rememberedID = editorDirectClipIDs[track.id],
           let remembered = track.clips.first(where: { $0.id == rememberedID }) {
            return remembered
        }
        let clips = track.sortedClips
        let resolved = clips.first(where: { $0.timelineStart == time })
            ?? clips.first(where: { time >= $0.visibleTimelineStart && time < $0.visibleTimelineEnd })
            ?? clips.first(where: { $0.visibleTimelineStart > time })
            ?? clips.last(where: { $0.visibleTimelineEnd <= time })
        if let resolved {
            editorDirectClipIDs[track.id] = resolved.id
        }
        return resolved
    }

    nonisolated static func activeTrackAnnouncement(trackName: String, clipName: String?) -> String {
        clipName.map { "\(trackName) track, \($0) selected" }
            ?? "\(trackName) track, no clip selected"
    }

    func editorClipSelection(at time: ProjectTime) -> EditorSelection? {
        guard let clip = editorClip(at: time) else {
            announce("There is no clip at or after the playhead on the active track")
            return nil
        }
        selection = .timelineClip(clip.id)
        return .timelineClip(clip.id)
    }

    func toggleClipMovement(id: UUID) {
        guard let clip = project.timelineClip(id: id) else { return }
        if movingTimelineClipID == id {
            finishClipMovement()
        } else {
            movingTimelineClipID = id
            selection = .timelineClip(id)
            announce("\(clip.displayName) selected for moving. Use arrows to move, or focus a destination and choose Move To.")
        }
    }

    func finishClipMovement() {
        guard movingTimelineClipID != nil else { return }
        movingTimelineClipID = nil
        announce("Clip movement finished")
    }

    var clipMovementSourceID: UUID? { movingTimelineClipID ?? copiedTimelineClipID }

    func canMoveClip(to destination: TimelineMoveDestination, targetID: UUID) -> Bool {
        guard let sourceID = clipMovementSourceID,
              let source = project.tracks.first(where: { $0.clips.contains { $0.id == sourceID } }),
              let target = (destination == .start || destination == .end) ? activeTimelineTrack : project.tracks.first(where: { $0.clips.contains { $0.id == targetID } }),
              source.kind == target.kind else { return false }
        return destination == .start || destination == .end || sourceID != targetID
    }

    func moveClip(to destination: TimelineMoveDestination, targetID: UUID) {
        guard let sourceID = clipMovementSourceID else {
            announce("Select a clip for moving with Space, or copy a clip first")
            return
        }
        moveTimelineClip(id: sourceID, to: destination, targetID: targetID,
                         destinationTrackID: (destination == .start || destination == .end) ? activeTimelineTrackID : nil)
    }

    func moveTimelineClip(id: UUID, to destination: TimelineMoveDestination, targetID: UUID, destinationTrackID: UUID? = nil) {
        do {
            let wasLinked = project.timelineClip(id: id)?.linkedClipID != nil
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveTrackClip(id: id, to: destination, targetID: targetID, destinationTrackID: destinationTrackID)
            }
            didMoveClip(id, becameIndependent: wasLinked && project.timelineClip(id: id)?.linkedClipID == nil)
        } catch {
            presentedError = ProjectPresentedError(title: "Clip Could Not Be Moved", message: error.localizedDescription)
        }
    }

    func moveMarkedClip(by offset: Int) {
        guard let id = movingTimelineClipID else { return }
        moveTimelineClip(id: id, by: offset)
    }

    private func moveTimelineClip(id: UUID, by offset: Int) {
        guard let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }),
              let index = track.sortedClips.firstIndex(where: { $0.id == id }) else { return }
        guard track.sortedClips.indices.contains(index + offset) else {
            announce(offset < 0 ? "Clip is already at the start of the track" : "Clip is already at the end of the track")
            return
        }
        moveTimelineClip(id: id, to: offset < 0 ? .before : .after, targetID: track.sortedClips[index + offset].id)
    }

    private func didMoveClip(_ id: UUID, becameIndependent: Bool = false) {
        guard let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }),
              let index = track.sortedClips.firstIndex(where: { $0.id == id }) else { return }
        activeTimelineTrackID = track.id
        selection = .timelineClip(id)
        requestTimelineFocusRestore(to: .clip(id))
        let independence = becameIndependent ? ". Audio now moves independently of its video" : ""
        announce("\(track.sortedClips[index].displayName), position \(index + 1) of \(track.clips.count), \(track.name) track\(independence)")
    }

    func setActiveTrackMuted(_ muted: Bool) {
        guard let track = activeTimelineTrack, track.kind == .audio else { return }
        mutateProject(actionName: muted ? "Mute Track" : "Unmute Track") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            project.tracks[index].isMuted = muted
        }
        announce("\(track.name) track \(muted ? "muted" : "unmuted")")
    }

    private func advanceAfterInsertion(_ placement: PlacementAction, clipID: UUID) {
        guard placement == .insert, let clip = project.timelineClip(id: clipID) else { return }
        timelinePlayhead = clip.timelineEnd
        projectPlayer?.stageInsertionPlayhead(clip.timelineEnd, duration: project.duration)
    }

    func copyTimelineClip(id: UUID) {
        guard project.timelineClip(id: id) != nil else {
            announce(ProjectTimelineError.clipNotFound.localizedDescription)
            return
        }
        copiedTimelineClipID = id
        announce("Clip copied")
    }

    func pasteCopiedTimelineClip(after targetID: UUID) {
        guard let copiedTimelineClipID else {
            announce("Copy a Timeline clip first")
            return
        }
        do {
            try mutateProjectThrowing(actionName: "Paste Clip") {
                _ = try $0.duplicateTrackClip(id: copiedTimelineClipID, after: targetID)
            }
            announce("Clip pasted")
        } catch {
            announce(error.localizedDescription)
        }
    }

    func moveCopiedTimelineClip(after targetID: UUID) {
        moveClip(to: .after, targetID: targetID)
    }

    func resolveURL(for asset: MediaAssetRecord) -> URL? {
        guard let url = ProjectImportCoordinator.resolveURL(for: asset) else { return nil }
        if !accessedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
        return url
    }

    func preparedMediaSource(for requestedAsset: MediaAssetRecord) async throws -> MediaSource? {
        guard var asset = project.asset(id: requestedAsset.id),
              let originalURL = resolveURL(for: asset) else { return nil }
        let currentFingerprint = try MediaCacheManager.sourceFingerprint(for: originalURL)
        if asset.playbackMode == nil || asset.sourceFingerprint != currentFingerprint {
            let previousCacheKey = asset.proxyCacheKey
            let preparation = try await ProjectImportCoordinator.preparePlayback(
                at: originalURL,
                preferredCacheKey: asset.sourceFingerprint == nil ? asset.proxyCacheKey : nil
            )
            asset.playbackMode = preparation.mode
            asset.proxyCacheKey = preparation.cacheKey
            asset.sourceFingerprint = preparation.fingerprint
            updatePlaybackPreparation(for: asset)
            if previousCacheKey != preparation.cacheKey {
                try? await MediaCacheManager.shared.removeProxy(cacheKey: previousCacheKey)
            }
        }
        guard let playbackMode = asset.playbackMode else { return nil }
        let originalAsset = AVURLAsset(url: originalURL)
        let contentType = (try? originalURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: originalURL.pathExtension)
        switch playbackMode {
        case .nativePassthrough:
            return .native(
                url: originalURL,
                asset: originalAsset,
                contentType: contentType,
                mode: .nativePassthrough,
                hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio
            )
        case .nativeMP4Export:
            return .native(
                url: originalURL,
                asset: originalAsset,
                contentType: contentType,
                mode: .nativePlaybackMP4Export,
                hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio
            )
        case .cachedProxy:
            guard let cacheKey = asset.proxyCacheKey,
                  let fingerprint = asset.sourceFingerprint else { return nil }
            let proxyURL = try await MediaCacheManager.shared.ensureProxy(
                sourceURL: originalURL,
                duration: asset.duration.seconds,
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                hasVideo: asset.hasVideo
            )
            return MediaSource(
                originalURL: originalURL,
                playbackURL: proxyURL,
                originalAsset: originalAsset,
                playbackAsset: AVURLAsset(url: proxyURL),
                contentType: contentType,
                mode: .proxyPlaybackMP4Export,
                frameTimestamps: [],
                hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio
            )
        }
    }

    func importFiles(into folderID: UUID? = nil) {
        guard !isImporting, NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio, .data]
        guard panel.runModal() == .OK else { return }

        importFiles(at: panel.urls, into: folderID)
    }

    func importFiles(at urls: [URL], into folderID: UUID? = nil) {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true
        Task { @MainActor in
            struct ImportGroup {
                var folderName: String?
                var assets: [MediaAssetRecord]
            }
            var groups: [ImportGroup] = []
            var failures: [(name: String, message: String)] = []
            var importPaths = Set(project.media.map {
                URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path
            })
            for selectedURL in urls {
                let scoped = selectedURL.startAccessingSecurityScopedResource()
                defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
                do {
                    let isDirectory = try selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    let candidates = try ProjectImportCoordinator.importableMediaURLs(in: selectedURL)
                    guard !candidates.isEmpty else {
                        failures.append((selectedURL.lastPathComponent, "No supported audio or video files were found."))
                        continue
                    }
                    var assets: [MediaAssetRecord] = []
                    for candidate in candidates {
                        let standardizedPath = candidate.standardizedFileURL.path
                        guard importPaths.insert(standardizedPath).inserted else { continue }
                        do {
                            assets.append(try await ProjectImportCoordinator.importAsset(at: candidate))
                        } catch {
                            failures.append((candidate.lastPathComponent, error.localizedDescription))
                        }
                    }
                    if !assets.isEmpty {
                        groups.append(ImportGroup(
                            folderName: isDirectory && folderID == nil
                                ? selectedURL.lastPathComponent
                                : nil,
                            assets: assets
                        ))
                    }
                } catch {
                    failures.append((selectedURL.lastPathComponent, error.localizedDescription))
                }
            }
            let additions = groups.flatMap(\.assets)
            if !additions.isEmpty {
                mutateProject(actionName: "Import Media") { project in
                    var existingNames = Set(project.folders.map { $0.name.lowercased() })
                    for group in groups {
                        project.media.append(contentsOf: group.assets)
                        if let folderID,
                           let folderIndex = project.folders.firstIndex(where: { $0.id == folderID }) {
                            project.folders[folderIndex].assetIDs.append(contentsOf: group.assets.map(\.id))
                        } else if let requestedName = group.folderName {
                            var folderName = requestedName
                            var suffix = 2
                            while existingNames.contains(folderName.lowercased()) {
                                folderName = "\(requestedName) \(suffix)"
                                suffix += 1
                            }
                            existingNames.insert(folderName.lowercased())
                            project.folders.append(ProjectFolder(
                                name: folderName,
                                assetIDs: group.assets.map(\.id)
                            ))
                        }
                    }
                }
            }
            isImporting = false
            if !additions.isEmpty {
                announce("Imported \(additions.count) clip\(additions.count == 1 ? "" : "s")")
            }
            if !failures.isEmpty {
                let details = failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
                presentedError = ProjectPresentedError(
                    title: additions.isEmpty ? "Import Failed" : "Some Clips Could Not Be Imported",
                    message: details
                )
                announce(additions.isEmpty ? "Import failed" : "Some clips could not be imported")
            }
        }
    }

    func importExternalFile(at url: URL, completion: @escaping (UUID) -> Void) {
        guard !isImporting else {
            presentedError = ProjectPresentedError(
                title: "Import Already in Progress",
                message: "Wait for the current import to finish, then open the video again."
            )
            return
        }
        let standardizedPath = url.standardizedFileURL.path
        if let existing = project.media.first(where: {
            URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path == standardizedPath
        }) {
            selection = .asset(existing.id)
            completion(existing.id)
            return
        }

        isImporting = true
        Task { @MainActor in
            do {
                let asset = try await ProjectImportCoordinator.importAsset(at: url)
                mutateProject(actionName: "Import Media") { project in
                    project.media.append(asset)
                }
                isImporting = false
                selection = .asset(asset.id)
                announce("Clip imported")
                completion(asset.id)
            } catch {
                isImporting = false
                presentedError = ProjectPresentedError(
                    title: "Import Failed",
                    message: error.localizedDescription
                )
                announce("Import failed")
            }
        }
    }

    func createFolder(named name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        mutateProject(actionName: "Create Project Folder") { project in
            project.folders.append(ProjectFolder(name: cleanName))
        }
    }

    func renameFolder(_ id: UUID, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        mutateProject(actionName: "Rename Project Folder") { project in
            guard let index = project.folders.firstIndex(where: { $0.id == id }) else { return }
            project.folders[index].name = cleanName
        }
    }

    func removeFolder(_ id: UUID) {
        mutateProject(actionName: "Remove Project Folder") { project in
            project.folders.removeAll { $0.id == id }
        }
    }

    func moveAsset(_ assetID: UUID, toFolder folderID: UUID?) {
        mutateProject(actionName: "Move Media") { project in
            for index in project.folders.indices {
                project.folders[index].assetIDs.removeAll { $0 == assetID }
            }
            if let folderID, let index = project.folders.firstIndex(where: { $0.id == folderID }) {
                project.folders[index].assetIDs.append(assetID)
            }
        }
    }

    func deleteSourceAsset(_ assetID: UUID) {
        guard let asset = project.asset(id: assetID) else { return }
        mutateProject(actionName: "Delete Source Clip") { project in
            project.removeSourceAsset(assetID)
        }
        if selection == .asset(assetID) { selection = .project }
        if activeTimelineTrackID.flatMap({ project.track(id: $0) }) == nil {
            activeTimelineTrackID = Self.preferredTimelineTrackID(in: project)
        }
        announce("\(asset.name) deleted from Project Source")
    }

    func updateProjectSettings(name: String, format: ProjectFormat, targetDuration: ProjectTime?) {
        mutateProject(actionName: "Change Project Settings") { project in
            project.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Project" : name
            project.applyProjectFormat(format)
            project.targetDuration = targetDuration
        }
    }

    func showProjectSettings() {
        isShowingProjectSettings = true
    }

    func dismissProjectSettings() {
        isShowingProjectSettings = false
    }

    func updateSourceEdit(assetID: UUID, segments: [SourceSegment]) {
        guard project.asset(id: assetID)?.sourceEdit.map(\.sourceRange) != segments.map(\.sourceRange) else { return }
        mutateProject(actionName: "Edit Source Clip") { project in
            guard let index = project.media.firstIndex(where: { $0.id == assetID }) else { return }
            project.media[index].sourceEdit = segments
        }
    }

    func updateTimelineEntry(_ selection: EditorSelection, segments: [SourceSegment]) throws {
        switch selection {
        case .timelineClip(let id):
            try mutateProjectThrowing(actionName: "Update Timeline Clip") {
                try $0.updateTrackClip(id: id, segments: segments)
            }
            announce("Timeline clip updated")
        case .cutaway(let id):
            try mutateProjectThrowing(actionName: "Update Cutaway") {
                try $0.updateCutaway(id: id, segments: segments)
            }
            announce("Cutaway updated")
        case .asset, .transition, .track, .project:
            return
        }
    }

    func renameTimelineEntry(_ selection: EditorSelection, to name: String) throws {
        switch selection {
        case .timelineClip(let id):
            try mutateProjectThrowing(actionName: "Rename Timeline Clip") {
                try $0.renameTrackClip(id: id, to: name)
            }
        case .cutaway(let id):
            try mutateProjectThrowing(actionName: "Rename Cutaway") {
                try $0.renameCutaway(id: id, to: name)
            }
        case .asset, .transition, .track, .project:
            return
        }
        announce("Timeline clip renamed")
    }

    @discardableResult
    func place(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]? = nil
    ) -> UUID? {
        do {
            return try placeThrowing(placement, editing: editSelection, segments: segments)
        } catch {
            announce(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func place(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]?,
        onTrack trackID: UUID
    ) -> UUID? {
        do {
            return try placeThrowing(
                placement,
                editing: editSelection,
                segments: segments,
                onTrack: trackID
            )
        } catch {
            announce(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func placeThrowing(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]? = nil
    ) throws -> UUID {
        guard let asset = asset(for: editSelection) else {
            throw ProjectTimelineError.sourceAssetNotFound
        }
        var selectedID: UUID?
        try mutateProjectThrowing(actionName: placement.undoName) { project in
            switch placement {
            case .append:
                selectedID = try project.append(asset: asset, segments: segments)
            case .insert:
                selectedID = try project.insert(asset: asset, segments: segments, at: timelinePlayhead)
            case .replaceRemainder:
                selectedID = try project.replaceClipRemainder(with: asset, segments: segments, at: timelinePlayhead)
            case .cutawaySourceAudio:
                selectedID = try project.addCutaway(asset: asset, segments: segments, at: timelinePlayhead, audioMode: .sourceAudio)
            case .cutawayPrimaryAudio:
                selectedID = try project.addCutaway(asset: asset, segments: segments, at: timelinePlayhead, audioMode: .primaryAudio)
            }
        }
        guard let selectedID else { throw ProjectTimelineError.unsupportedPlacement }
        selection = placement.isCutaway ? .cutaway(selectedID) : .timelineClip(selectedID)
        advanceAfterInsertion(placement, clipID: selectedID)
        announce(placement.confirmation)
        return selectedID
    }

    @discardableResult
    func placeThrowing(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]?,
        onTrack trackID: UUID
    ) throws -> UUID {
        guard let asset = asset(for: editSelection) else {
            throw ProjectTimelineError.sourceAssetNotFound
        }
        var selectedID: UUID?
        try mutateProjectThrowing(actionName: placement.undoName) { project in
            switch placement {
            case .append:
                selectedID = try project.append(asset: asset, segments: segments, toTrack: trackID)
            case .insert:
                selectedID = try project.insert(asset: asset, segments: segments, at: timelinePlayhead, onTrack: trackID)
            case .replaceRemainder:
                selectedID = try project.replaceRemainder(with: asset, segments: segments, at: timelinePlayhead, onTrack: trackID)
            case .cutawaySourceAudio, .cutawayPrimaryAudio:
                throw ProjectTimelineError.unsupportedPlacement
            }
        }
        guard let selectedID else { throw ProjectTimelineError.unsupportedPlacement }
        activeTimelineTrackID = trackID
        selection = .timelineClip(selectedID)
        advanceAfterInsertion(placement, clipID: selectedID)
        announce(placement.confirmation)
        return selectedID
    }

    @discardableResult
    func createTrackAndPlaceThrowing(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment],
        trackKind: TimelineTrackKind,
        trackName requestedTrackName: String,
        audioSettings: AudioClipSettings?
    ) throws -> (trackID: UUID, clipID: UUID) {
        guard let asset = asset(for: editSelection) else {
            throw ProjectTimelineError.sourceAssetNotFound
        }
        guard !segments.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard (trackKind == .video && asset.hasVideo) ||
                (trackKind == .audio && asset.hasAudio) else {
            throw ProjectTimelineError.incompatibleTrackKind
        }

        let trackName = requestedTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackName.isEmpty else { throw ProjectTimelineError.invalidName }

        var createdTrackID: UUID?
        var placedClipID: UUID?
        try mutateProjectThrowing(actionName: "Create \(trackKind.title) Track and \(placement.undoName)") { project in
            let trackID = project.createTrack(kind: trackKind)
            try project.renameTrack(id: trackID, to: trackName)

            let clipID: UUID
            switch placement {
            case .append:
                clipID = try project.append(asset: asset, segments: segments, toTrack: trackID)
            case .insert:
                clipID = try project.insert(
                    asset: asset,
                    segments: segments,
                    at: timelinePlayhead,
                    onTrack: trackID
                )
            case .replaceRemainder:
                clipID = try project.replaceRemainder(
                    with: asset,
                    segments: segments,
                    at: timelinePlayhead,
                    onTrack: trackID
                )
            case .cutawaySourceAudio, .cutawayPrimaryAudio:
                throw ProjectTimelineError.unsupportedPlacement
            }

            if trackKind == .audio, let audioSettings, !audioSettings.isNeutral {
                try project.updateAudioSettings(clipID: clipID, settings: audioSettings)
            }
            createdTrackID = trackID
            placedClipID = clipID
        }

        guard let trackID = createdTrackID, let clipID = placedClipID else {
            throw ProjectTimelineError.unsupportedPlacement
        }
        activeTimelineTrackID = trackID
        selection = .timelineClip(clipID)
        advanceAfterInsertion(placement, clipID: clipID)
        announce("\(placement.confirmation) to \(trackName)")
        return (trackID, clipID)
    }

    func asset(for editSelection: EditorSelection) -> MediaAssetRecord? {
        switch editSelection {
        case .asset(let id):
            return project.asset(id: id)
        case .timelineClip(let id):
            return project.timelineClip(id: id)
                .flatMap { project.asset(id: $0.assetID) }
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id })
                .flatMap { project.asset(id: $0.assetID) }
        case .transition, .track, .project:
            return nil
        }
    }

    func segments(for editSelection: EditorSelection) -> [SourceSegment]? {
        switch editSelection {
        case .asset(let id):
            return project.asset(id: id)?.sourceEdit
        case .timelineClip(let id):
            return project.timelineClip(id: id)?.segments
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id })?.segments
        case .transition, .track, .project:
            return nil
        }
    }

    func splitClipAtPlayhead() {
        guard let clip = primaryTimelineClip(at: timelinePlayhead) else {
            announce("Move the playhead inside a clip before splitting it")
            return
        }
        do {
            try mutateProjectThrowing(actionName: "Split Clip") { project in
                _ = try project.splitClip(id: clip.id, atTimelineTime: timelinePlayhead)
            }
            if selection == .timelineClip(clip.id) { selection = .project }
            announce("Clip split")
        } catch {
            announce(error.localizedDescription)
        }
    }

    func deleteSelection() {
        switch selection {
        case .timelineClip(let id):
            do {
                try mutateProjectThrowing(actionName: "Delete Timeline Clip") { try $0.removeTrackClip(id: id) }
                selection = .project
                announce("Timeline clip deleted")
            } catch { announce(error.localizedDescription) }
        case .cutaway(let id):
            mutateProject(actionName: "Delete Cutaway") { $0.cutaways.removeAll { $0.id == id } }
            selection = .project
            announce("Cutaway removed")
        case .transition(let id):
            deleteTransition(id: id)
        default:
            break
        }
    }

    func moveSelectedClip(by offset: Int) {
        guard let clip = selectedTimelineClip else { return }
        moveTimelineClip(id: clip.id, by: offset)
    }

    func moveSelectedClipToBeginning() {
        guard let clip = selectedTimelineClip else { return }
        moveTimelineClip(id: clip.id, to: .start, targetID: clip.id)
    }

    func moveSelectedClipToEnd() {
        guard let clip = selectedTimelineClip else { return }
        moveTimelineClip(id: clip.id, to: .end, targetID: clip.id)
    }

    private func mutateProject(actionName: String, _ mutation: (inout TrimatoProject) -> Void) {
        let before = document.project
        var after = before
        mutation(&after)
        apply(after, undoingTo: before, actionName: actionName)
    }

    private func mutateProjectThrowing(
        actionName: String,
        _ mutation: (inout TrimatoProject) throws -> Void
    ) throws {
        let before = document.project
        var after = before
        try mutation(&after)
        apply(after, undoingTo: before, actionName: actionName)
    }

    private func apply(_ project: TrimatoProject, undoingTo previous: TrimatoProject, actionName: String) {
        guard project != previous else { return }
        document.project = project
        if let id = movingTimelineClipID, project.timelineClip(id: id) == nil { movingTimelineClipID = nil }
        timelineContentRevision += 1
        updateCacheProtection(for: project)
        if let undoManager = projectUndoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.apply(previous, undoingTo: project, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }

    private func updatePlaybackPreparation(for asset: MediaAssetRecord) {
        document.updatePlaybackPreparation(
            assetID: asset.id,
            playbackMode: asset.playbackMode,
            proxyCacheKey: asset.proxyCacheKey,
            sourceFingerprint: asset.sourceFingerprint
        )
        updateCacheProtection(for: document.project)
    }

    private func updateCacheProtection(for project: TrimatoProject) {
        let keys = Set(project.media.compactMap(\.proxyCacheKey))
        let owner = cacheOwnerID
        Task { await MediaCacheManager.shared.updateProtectedKeys(owner: owner, keys: keys) }
    }

    private func announce(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}

enum PlacementAction: CaseIterable, Identifiable {
    case append
    case insert
    case replaceRemainder
    case cutawaySourceAudio
    case cutawayPrimaryAudio

    var id: String { undoName }
    var isCutaway: Bool { self == .cutawaySourceAudio || self == .cutawayPrimaryAudio }

    var title: String {
        switch self {
        case .append: "Append to Timeline"
        case .insert: "Insert and Split"
        case .replaceRemainder: "Insert and Overwrite"
        case .cutawaySourceAudio: "Insert on Top with Source Audio"
        case .cutawayPrimaryAudio: "Insert on Top over Primary Audio"
        }
    }

    var undoName: String {
        switch self {
        case .append: "Append Clip"
        case .insert: "Insert and Split"
        case .replaceRemainder: "Insert and Overwrite"
        case .cutawaySourceAudio: "Insert on Top with Source Audio"
        case .cutawayPrimaryAudio: "Insert on Top over Primary Audio"
        }
    }

    var confirmation: String {
        switch self {
        case .append: "Clip appended"
        case .insert: "Clip inserted"
        case .replaceRemainder: "Clip inserted and overwritten"
        case .cutawaySourceAudio: "Clip inserted on top with source audio"
        case .cutawayPrimaryAudio: "Clip inserted on top over primary audio"
        }
    }
}
