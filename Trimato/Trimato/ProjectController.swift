import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

enum EditorSelection: Hashable, Sendable {
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

struct CaptionFinalizationReport: Identifiable, Equatable {
    let id = UUID()
    let finalizedPassages: Int
    let createdCues: Int
    let issues: [CaptionFinalizationIssue]
    let fatalError: String?
}

@MainActor
final class ProjectController: ObservableObject {
    let document: ProjectDocument
    let mediaFiles = ProjectMediaFiles()
    private var mediaLocationOverrides: [UUID: MediaAssetRecord] = [:]

    @Published var selection: EditorSelection = .project
    private var playbackPosition = ProjectTime.zero
    var timelinePlayhead: ProjectTime {
        get { playbackPosition }
        set {
            guard playbackPosition != newValue else { return }
            objectWillChange.send()
            playbackPosition = newValue
        }
    }

    func updatePlaybackPosition(_ time: ProjectTime, isPlaying: Bool) {
        guard playbackPosition != time else { return }
        // Current-clip badges change at clip boundaries, not every clock tick.
        if !isPlaying || currentTimelineClip(at: playbackPosition)?.id != currentTimelineClip(at: time)?.id {
            objectWillChange.send()
        }
        playbackPosition = time
    }
    @Published var activeTimelineTrackID: UUID?
    @Published var selectedCaptionCueID: UUID?
    @Published var editingMarker: TimelineMarker?
    @Published var pictureExportRequest: PictureExportRequest?
    private var pendingPictureExport: (PictureExportRequest, Bool, String)?
    @Published var selectedMarkerID: UUID?
    @Published private(set) var isCaptionEditorOpen = false
    @Published var timelineHasKeyboardFocus = false
    @Published var recordingSession: ProjectRecordingSession?
    @Published var toolPane: WorkspaceTool?
    @Published var toolFocusRevision = 0
    @Published var isConfirmingToolClose = false
    var pendingToolAction: (() -> Void)?
    var captionHasPendingEdits: (() -> Bool)?
    private var recordingOriginCueID: UUID?
    @Published var generatorRequestID: UUID?
    @Published var transitionRequest: TransitionRequest?
    @Published private(set) var transitionRequestReturnsToEditor = false
    @Published private(set) var editorFocusRestoreRequest = 0
    @Published private(set) var workspaceFocusRequest = WorkspaceFocusRequest()
    @Published private(set) var workspaceNavigation = WorkspaceFocusRequest()
    @Published private(set) var projectSourceFocusRequest = ProjectSourceFocusRequest()
    @Published private(set) var timelineFocusRestoreRequest = 0
    @Published private(set) var timelineListFocusRestoreRequest = 0
    @Published private(set) var timelineContentRevision = 0
    @Published private(set) var applyingTransitionName: String?
    @Published private(set) var applyingTransitionProgress: Double?
    @Published var isImporting = false
    @Published private(set) var isRelinkingMedia = false
    @Published private(set) var canCancelImport = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importDetail: String?
    @Published private(set) var importOutcome = OperationProgressOutcome.completed
    private var sourceImportFocus: (existingIDs: Set<UUID>, fallback: ProjectSourceItemID)?
    private var importTask: Task<Void, Never>?
    private var projectFilePanel: NSOpenPanel?

    func cancelImport() {
        guard canCancelImport else { return }
        mediaFiles.chooseImport(nil)
        importTask?.cancel()
    }
    @Published var isShowingProjectSettings = false
    @Published var presentedError: ProjectPresentedError?
    @Published var captionFinalizationReport: CaptionFinalizationReport?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double?
    @Published private(set) var isPresentingExportPanel = false
    @Published private(set) var copiedTimelineClipID: UUID?
    @Published private(set) var movingTimelineClipID: UUID?
    @Published private(set) var movementPreview: TrimatoProject?
    private var movementBaseline: TrimatoProject?
    private var mixerAdjustmentOrigin: TrimatoProject?
    private var mixerAdjustmentTask: Task<Void, Never>?
    private var mixerAdjustmentRevision = 0
    private var mixerAdjustmentIsDragging = false
    private var mixerAdjustmentName = "Adjust Mix"
    var hasPendingMixerAdjustment: Bool { mixerAdjustmentOrigin != nil }
    private var movementNudgeOrigin: TrimatoProject?
    private var movementNudgeFrames = 0
    private(set) var timelineFocusRestoreTarget: TimelineElementSelection?
    private struct PendingTrackAnnouncement {
        let trackID: UUID
        let target: TimelineElementSelection?
        let itemRevision: Int
        let listRevision: Int
        let message: String
    }
    private var pendingTrackAnnouncement: PendingTrackAnnouncement?

    private var cancellables: Set<AnyCancellable> = []
    private var accessedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?
    private(set) weak var projectSaveCoordinator: ProjectWindowSaveCoordinator?
    private weak var projectUndoManager: UndoManager?
    private(set) weak var projectPlayer: ProjectPlayerViewModel?
    private var projectWithPreparedTransitionPreview: TrimatoProject?
    private var closeProjectAction: ((@escaping (Bool) -> Void) -> Void)?
    private var projectInfoTarget: ProjectInfoTarget = .selection(.project)
    private var editorAccessibilityFocusProvider: (() -> Bool)?
    private var editorDirectClipIDs: [UUID: UUID] = [:]
    private var openCaptionEditorAction: (() -> Void)?
    private var closeCaptionEditorAction: (() -> Void)?
    private let cacheOwnerID = UUID()

    @Published private(set) var openingEntry: ProjectOpeningEntry
    @Published private(set) var isWorkspacePreparationPending: Bool

    init(document: ProjectDocument, awaitingWorkspacePreparation: Bool = false) {
        openingEntry = ProjectOpeningEntry(required: awaitingWorkspacePreparation)
        isWorkspacePreparationPending = awaitingWorkspacePreparation
        var normalized = document.project
        GeneratorSourceNaming.normalize(in: &normalized)
        if normalized != document.project { document.project = normalized }
        self.document = document
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        mediaFiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        mediaFiles.connect(self)
        updateCacheProtection(for: document.project)
        activeTimelineTrackID = Self.preferredTimelineTrackID(in: document.project)
    }

    deinit {
        exportTask?.cancel()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        let cacheOwnerID = cacheOwnerID
        Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: cacheOwnerID) }
    }

    func requestGenerator(editing: EditorSelection? = nil) {
        projectPlayer?.player.pause()
        let session = GeneratorSession(controller: self, editing: editing)
        GeneratorWindowRegistry.shared.sessions[session.id] = session
        generatorRequestID = session.id
    }

    func requestRecording(_ purpose: RecordingPurpose, cue: CaptionCue? = nil) {
        guard !isExporting, !isImporting else { return }
        let tool: WorkspaceTool = purpose == .audioDescription ? .describer : .voicer
        openToolPane(tool) { [weak self] in
            guard let self else { return }
            projectPlayer?.player.pause()
            recordingOriginCueID = cue?.id
            recordingSession = ProjectRecordingSession(controller: self, purpose: purpose, cue: cue)
        }
    }

    func dismissRecording() {
        let session = recordingSession
        session?.close()
        recordingSession = nil
        if toolPane == .describer || toolPane == .voicer { toolPane = nil }
        if session != nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.toolPane == nil else { return }
                self?.recordingWindowDidDismiss()
            }
        }
    }

    func recordingWindowDidDismiss() {
        guard projectSaveCoordinator?.attachedWindow?.isVisible != false else { return }
        projectSaveCoordinator?.attachedWindow?.makeKeyAndOrderFront(nil)
        if let id = recordingOriginCueID, project.captionCue(id: id) != nil {
            activeTimelineTrackID = project.descriptionTranscriptTrack?.id
            selectedCaptionCueID = id
            selection = .project
            requestTimelineFocusRestore(to: .caption(id))
        } else { requestEditorFocusRestore() }
        recordingOriginCueID = nil
    }

    func updateDescriptionDucking(_ settings: DescriptionDucking) {
        guard settings.decibels.isFinite, (-60...0).contains(settings.decibels),
              settings.fadeSeconds.isFinite, (0.01...5).contains(settings.fadeSeconds) else { return }
        mutateProject(actionName: "Adjust Audio Ducking") { $0.descriptionDucking = settings }
    }

    func addProjectRecording(asset: MediaAssetRecord?, at time: ProjectTime, cue: CaptionCue?, ducking: DescriptionDucking, voice: VoiceAdjustment? = nil) throws {
        var addedID: UUID?
        try mutateProjectThrowing(actionName: asset?.recordingPurpose == .voiceOver ? "Add Voice Over" : "Save Description") { project in
            if let asset {
                addedID = project.putRecording(asset, at: time)
                if let addedID, let voice {
                    var audio = AudioClipSettings.neutral
                    audio.voice = voice
                    try project.setClipEffects(id: addedID, audio: audio, filters: nil)
                }
            }
            if let cue { try project.putDescription(cue) }
            if asset?.recordingPurpose != .voiceOver { project.descriptionDucking = ducking }
        }
        if let addedID, let track = project.tracks.first(where: { $0.clips.contains { $0.id == addedID } }) {
            activeTimelineTrackID = track.id
            selection = .timelineClip(addedID)
        } else if let cue {
            activeTimelineTrackID = project.descriptionTranscriptTrack?.id
            selectedCaptionCueID = cue.id
        }
    }

    func recordingsDirectory() async throws -> URL {
        try await projectMediaDirectory(named: "Recordings")
    }

    private var choosingMediaFolder = false

    func projectMediaDirectory(named name: String) async throws -> URL {
        guard let projectURL = projectSaveCoordinator?.projectURL else {
            throw AudioCaptureError.message("Save the project before adding project media.")
        }
        guard !choosingMediaFolder else {
            throw AudioCaptureError.message("Finish choosing the project media folder first.")
        }
        choosingMediaFolder = true
        defer { choosingMediaFolder = false }
        let parent = projectURL.deletingLastPathComponent()
        // Capture the initiating window before any suspension or panel presentation.
        let origin = NSApp.keyWindow ?? projectSaveCoordinator?.attachedWindow
        var grantedFolder: URL?
        if let bookmark = project.recordingsFolderBookmark {
            var stale = false
            if let granted = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale, granted.standardizedFileURL == parent.standardizedFileURL {
                if accessedURLs.contains(granted) {
                    grantedFolder = granted
                } else if granted.startAccessingSecurityScopedResource() {
                    accessedURLs.append(granted)
                    grantedFolder = granted
                }
            }
        }
        return try await ProjectMediaStorage.prepare(projectURL: projectURL, name: name,
            grantedFolder: grantedFolder, requestAccess: { [self] in
                guard let origin, origin.attachedSheet == nil else {
                    throw AudioCaptureError.message("Close the open sheet before choosing the project media folder.")
                }
                InterfaceSounds.shared.silenceForPlayback()
                let panel = NSOpenPanel()
                panel.title = "Choose Project Media Folder"
                panel.message = "Choose “\(parent.lastPathComponent)”, the folder containing “\(projectURL.lastPathComponent)”. Trimato will store project media in subfolders here."
                panel.prompt = "Choose Folder"
                panel.directoryURL = parent
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                let response = await withTaskCancellationHandler {
                    if Task.isCancelled { return NSApplication.ModalResponse.cancel }
                    return await panel.beginSheetModal(for: origin)
                } onCancel: {
                    Task { @MainActor in panel.cancel(nil) }
                }
                try Task.checkCancellation()
                guard response == .OK, let selected = panel.url else { throw CancellationError() }
                guard projectSaveCoordinator?.projectURL == projectURL else {
                    throw AudioCaptureError.message("The project location changed. Try adding the media again.")
                }
                guard selected.standardizedFileURL == parent.standardizedFileURL else {
                    throw AudioCaptureError.message("Choose “\(parent.lastPathComponent)”, the folder containing this Trimato project.")
                }
                guard selected.startAccessingSecurityScopedResource() else {
                    throw AudioCaptureError.message("Trimato could not access the selected folder. Choose the folder again to grant access.")
                }
                accessedURLs.append(selected)
                let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                document.project.recordingsFolderBookmark = bookmark
                return selected
            }, prepareDirectory: { try await RecordingFileStorage.prepareDirectory($0) })
    }

    func exportDescriptions() {
        guard let cues = project.descriptionTranscriptTrack?.captionCues, !cues.isEmpty,
              let window = projectSaveCoordinator?.attachedWindow else { return }
        let panel = CaptionExportSavePanel(baseName: "\(project.name) descriptions", title: "Export Description Transcript")
        Task { @MainActor [weak self] in
            guard let self, let (url, format) = await panel.selection(parentWindow: window) else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let cues = CaptionFileCodec.cues(cues, within: projectPlayer?.exportRange)
                let data = try format.captionFileFormat.map { try CaptionFileCodec.encode(cues, format: $0) }
                    ?? CaptionFileCodec.encodePlainText(cues, projectTitle: project.name)
                try data.write(to: url, options: .atomic)
            } catch { presentedError = ProjectPresentedError(title: "Description Export", message: error.localizedDescription) }
        }
    }

    var captionDraftRange: ProjectTimeRange? {
        projectPlayer?.exportRange
    }

    var canCreateCaption: Bool {
        captionDraftRange != nil && canRequestCaption
    }

    var canRequestCaption: Bool { !isExporting && !isImporting }

    var canFinalizeCaptions: Bool {
        project.captionTrack?.captionCues.contains(where: \.isDraft) == true && !isExporting && !isImporting
    }

    func installCaptionEditorActions(open: @escaping () -> Void, close: @escaping () -> Void) {
        openCaptionEditorAction = open
        closeCaptionEditorAction = close
    }

    func setCaptionEditorOpen(_ isOpen: Bool) {
        isCaptionEditorOpen = isOpen
    }

    func closeCaptionEditor() {
        closeCaptionEditorAction?()
    }

    func requestCaptionEditor() {
        guard canRequestCaption else { return }
        if toolPane == .caption { toolFocusRevision += 1; return }
        guard canCreateCaption else {
            presentedError = ProjectPresentedError(
                title: "Caption Needs In and Out Points",
                message: "In the Editor, press I at the caption’s start and O at its end, then press Command-Shift-C again. The Out point must be after the In point."
            )
            return
        }
        openCaptionEditorAction?()
    }

    func playCaptionRange(_ range: ProjectTimeRange) {
        projectPlayer?.playCaptionRange(range)
    }

    func stopCaptionPlayback() {
        projectPlayer?.stopCaptionRangePlayback()
    }

    func movePlayheadToCaption(id: UUID) {
        guard let cue = project.captionCue(id: id) else { return }
        let destination = min(max(cue.start, .zero), project.duration)
        projectPlayer?.seek(to: destination)
        if timelinePlayhead != destination { timelinePlayhead = destination }
    }

    func clearCaptionMarkers() {
        projectPlayer?.clearCaptionMarkers()
    }

    func updateGenerator(_ definition: GeneratorDefinition, editing: EditorSelection, expectedProject: TrimatoProject) throws {
        try definition.validate()
        guard project == expectedProject else { throw MediaSourceError.unreadable("The project changed while preparing the generator. Try updating again.") }
        guard let source = asset(for: editing), source.generator != nil,
              source.hasVideo == (definition.kind != .silence) else { throw ProjectTimelineError.incompatibleTrackKind }
        let id: UUID
        switch editing {
        case .timelineClip(let clipID), .cutaway(let clipID): id = clipID
        default: throw ProjectTimelineError.clipNotFound
        }
        let usedElsewhere = project.tracks.flatMap(\.clips).contains { $0.id != id && $0.assetID == source.id }
            || project.primaryTimeline.contains { $0.id != id && $0.assetID == source.id }
            || project.cutaways.contains { $0.id != id && $0.assetID == source.id }
        var asset = definition.assetRecord()
        asset.name = usedElsewhere
            ? GeneratorSourceNaming.nextName(base: definition.kind.title,
                                             usedNames: GeneratorSourceNaming.usedNames(in: project))
            : source.name
        try mutateProjectThrowing(actionName: "Update Generator") { project in
            if !usedElsewhere, let index = project.media.firstIndex(where: { $0.id == source.id }) {
                project.media[index] = asset
                for folder in project.folders.indices {
                    project.folders[folder].assetIDs.removeAll { $0 == source.id }
                }
            } else {
                project.media.append(asset)
            }
            try project.updateTrackClip(id: id, segments: asset.sourceEdit)
            for track in project.tracks.indices {
                for clip in project.tracks[track].clips.indices where project.tracks[track].clips[clip].id == id {
                    project.tracks[track].clips[clip].assetID = asset.id
                    if project.tracks[track].clips[clip].customName == nil {
                        project.tracks[track].clips[clip].name = asset.name
                        project.tracks[track].clips[clip].labelOrdinal = nil
                    }
                }
            }
            if let index = project.cutaways.firstIndex(where: { $0.id == id }) {
                project.cutaways[index].assetID = asset.id
                if project.cutaways[index].customName == nil {
                    project.cutaways[index].name = asset.name
                    project.cutaways[index].labelOrdinal = nil
                }
                project.cutaways[index].segments = asset.sourceEdit
            }
            project.synchronizeTracksToLegacyTimeline()
            for transition in project.transitions where transition.leadingClipID == id || transition.trailingClipID == id {
                guard transition.edge != .between else { throw ProjectTimelineError.transitionNotAvailable("Remove the generator’s cross transition before changing its source settings.") }
                guard transition.duration < definition.duration else { throw ProjectTimelineError.transitionNotAvailable("The generator must be longer than its transition. Shorten or remove the transition first.") }
            }
        }
        announce("Generator updated")
    }

    func placeGenerator(_ definition: GeneratorDefinition, placement: PlacementAction,
                        at playhead: ProjectTime, trackID: UUID?, newTrackName: String,
                        expectedProject: TrimatoProject) throws {
        guard project == expectedProject else {
            throw MediaSourceError.unreadable("The project changed while the generator was being prepared. Try adding it again.")
        }
        try definition.validate()
        var asset = definition.assetRecord()
        asset.name = GeneratorSourceNaming.nextName(base: definition.kind.title,
                                                   usedNames: GeneratorSourceNaming.usedNames(in: project))
        var placedID: UUID?
        var destinationID: UUID?
        try mutateProjectThrowing(actionName: "Add Generator") { project in
            project.ensureTrackModel()
            project.media.append(asset)
            let target: UUID
            if let trackID { target = trackID }
            else {
                guard !newTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectTimelineError.invalidName }
                target = project.createTrack(kind: definition.kind.trackKind)
                try project.renameTrack(id: target, to: newTrackName)
            }
            switch placement {
            case .append: placedID = try project.append(asset: asset, segments: nil, toTrack: target)
            case .insert: placedID = try project.insert(asset: asset, segments: nil, at: playhead, onTrack: target)
            case .replaceRemainder: placedID = try project.replaceRemainder(with: asset, segments: nil, at: playhead, onTrack: target)
            case .cutawayPrimaryAudio, .cutawaySourceAudio:
                throw ProjectTimelineError.unsupportedPlacement
            }
            destinationID = target
        }
        if let placedID {
            activeTimelineTrackID = destinationID
            selection = .timelineClip(placedID)
            advanceAfterInsertion(placement, clipID: placedID)
            announce("Generator added")
        }
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
        coordinator.autoSaveAllowed = { [weak self] in
            guard let self else { return false }
            return !self.mediaFiles.isBusy && !self.isImporting && !self.isRelinkingMedia
        }
        mediaFiles.refresh()
    }

    func installUndoManager(_ undoManager: UndoManager) {
        projectUndoManager = undoManager
    }

    func installProjectPlayer(_ player: ProjectPlayerViewModel) {
        projectPlayer = player
        player.createMarker = { [weak self] in self?.createMarker(at: $0) }
        player.editMarkerAtPlayhead = { [weak self] in self?.editMarkerAtPlayhead() ?? false }
        player.deleteMarkerAtPlayhead = { [weak self] in self?.deleteMarkerAtPlayhead() ?? false }
        player.updateMix(project: project)
        player.onPlayheadChange { [weak self, weak player] time in
            self?.updatePlaybackPosition(time, isPlaying: player?.isPlaying == true)
        }
    }

    func installCloseProjectAction(_ action: @escaping (@escaping (Bool) -> Void) -> Void) {
        closeProjectAction = action
    }

    func closeProject(completion: @escaping (Bool) -> Void = { _ in }) {
        mixerAdjustmentEditing(false)
        guard !mediaFiles.isBusy, !isImporting, !isRelinkingMedia else {
            presentedError = .init(title: "Media Operation in Progress", message: "Finish or cancel the media operation before closing the project.")
            completion(false); return
        }
        guard QuitReviewState.shared.coordinator == nil else { completion(false); return }
        guard let closeProjectAction else { completion(false); return }
        closeProjectAction(completion)
    }

    let quitEdits = ProjectQuitEdits()

    func closeProjectForQuit(completion: @escaping (Bool) -> Void) {
        mixerAdjustmentEditing(false)
        guard !mediaFiles.isBusy, !isImporting, !isRelinkingMedia else {
            presentedError = .init(title: "Media Operation in Progress", message: "Finish or cancel the media operation before quitting.")
            completion(false); return
        }
        guard let coordinator = projectSaveCoordinator else {
            closeProject(completion: completion)
            return
        }
        coordinator.requestQuit(edits: quitEdits, completion: completion)
    }

    var canExportFrame: Bool {
        !isExporting && !isPresentingExportPanel && pictureExportRequest == nil && project.hasTimelineVideo
    }

    var canExportProject: Bool {
        !isExporting &&
            !isPresentingExportPanel &&
            project.tracks.contains(where: { !$0.clips.isEmpty }) &&
            (projectPlayer?.hasValidExportSelection ?? true)
    }

    func saveProjectDocument() {
        mixerAdjustmentEditing(false)
        projectSaveCoordinator?.save { [weak self] succeeded in
            if succeeded { self?.announce("Project saved", priority: .high) }
        }
    }

    func saveProjectDocumentAs() {
        mixerAdjustmentEditing(false)
        projectSaveCoordinator?.saveAs { [weak self] succeeded in
            if succeeded { self?.announce("Project saved", priority: .high) }
        }
    }

    func relinkSelectedAsset() {
        guard let asset = selectedAsset, !mediaFiles.isBusy, !isImporting, !isExporting, !isRelinkingMedia,
              projectFilePanel == nil,
              NSApp.modalWindow == nil,
              let parentWindow = projectSaveCoordinator?.attachedWindow,
              parentWindow.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink \(asset.name)"
        MediaSelection.configure(panel)
        projectFilePanel = panel
        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self else { return }
            let url = response == .OK ? panel.url : nil
            self.projectFilePanel = nil
            panel.orderOut(nil)
            guard let url else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard MediaSelection.isSupportedMedia(url) else {
                    self?.presentedError = .init(title: "Media Could Not Be Relinked", message: "Select a supported audio or video file.")
                    return
                }
                self?.relink(asset, to: url)
            }
        }
    }

    private func relink(_ asset: MediaAssetRecord, to url: URL) {
        isRelinkingMedia = true
        Task { @MainActor in
            defer { isRelinkingMedia = false }
            do {
                var replacement = try await ProjectImportCoordinator.importAsset(at: url)
                guard (!asset.hasVideo || replacement.hasVideo), (!asset.hasAudio || replacement.hasAudio),
                      replacement.duration >= MediaFileAccess.requiredEnd(for: asset.id, in: project) else {
                    throw QuitDraftError(message: "Choose media with the audio and video required by this source and enough duration for its existing edits.")
                }
                let previousProxyCacheKey = asset.proxyCacheKey
                replacement.id = asset.id
                replacement.recordingPurpose = asset.recordingPurpose
                mediaLocationOverrides[asset.id] = nil
                mutateProject(actionName: "Relink Media") { project in
                    guard let index = project.media.firstIndex(where: { $0.id == asset.id }) else { return }
                    replacement.name = project.media[index].name
                    replacement.sourceEdit = project.media[index].sourceEdit
                    project.media[index] = replacement
                }
                if previousProxyCacheKey != replacement.proxyCacheKey {
                    try? await MediaCacheManager.shared.removeProxy(cacheKey: previousProxyCacheKey)
                }
                mediaFiles.refresh()
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

    func exportPicture(web: Bool) {
        guard (web ? canExportProject : canExportFrame), project.hasTimelineVideo, NSApp.modalWindow == nil,
              let player = projectPlayer else { return }
        let time = player.precisePlayhead
        let range = player.exportRange
        guard time >= .zero, time < project.duration,
              !web || range.map({ time >= $0.start && time < $0.end }) ?? true else {
            presentedError = ProjectPresentedError(title: "Choose a Frame", message: "Move the playhead inside the export range, then export again.")
            return
        }
        pictureExportRequest = PictureExportRequest(time: time, range: range, web: web, project: project)
    }

    func confirmPictureExport(_ request: PictureExportRequest, captions: Bool, language: String) {
        pendingPictureExport = (request, captions, language)
        pictureExportRequest = nil
    }

    func pictureExportSheetDismissed() {
        guard let (request, captions, language) = pendingPictureExport else { return }
        pendingPictureExport = nil
        guard let window = NSApp.keyWindow else { return }
        if captions && request.project.captionTrack?.captionCues.contains(where: \.isDraft) == true {
            presentedError = ProjectPresentedError(title: "Finalize Captions Before Exporting", message: "Choose Timeline > Finalize Captions, then export again.")
            return
        }
        isPresentingExportPanel = true
        Task { @MainActor in
            defer { isPresentingExportPanel = false }
            let destination: URL
            if request.web {
                let panel = NSOpenPanel()
                panel.title = "Export Web Video"
                panel.prompt = "Export"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                destination = url
            } else {
                let panel = NSSavePanel()
                panel.title = "Export Frame"
                panel.prompt = "Export"
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = request.project.name + ".png"
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                destination = url
            }
            startPictureExport(request, destination: destination, captions: captions, language: language)
        }
    }

    private func startPictureExport(_ request: PictureExportRequest, destination: URL, captions: Bool, language: String) {
        let urls = resolvedMediaURLs()
        isExporting = true
        exportProgress = nil
        exportTask = Task { @MainActor in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer {
                if scoped { destination.stopAccessingSecurityScopedResource() }
                isExporting = false
                exportProgress = nil
                exportTask = nil
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let png = try await ProjectFrameExporter.png(project: request.project, mediaURLs: urls, at: request.time, captions: captions && !request.web)
                if request.web {
                    let package = temporary.appendingPathComponent("Web Video")
                    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                    try png.write(to: package.appendingPathComponent("poster.png"))
                    var movie = request.project
                    for index in movie.tracks.indices where movie.tracks[index].kind == .captions { movie.tracks[index].captionCues = [] }
                    try await ProjectExporter.export(project: movie, mediaURLs: urls, timeRange: request.range,
                        format: .h264MP4, to: package.appendingPathComponent("video.mp4"), audioMode: .highQualityStereo,
                        progress: { [weak self] in self?.exportProgress = $0 }, preserveHDR: false, webOptimized: true)
                    if captions {
                        let cues = CaptionFileCodec.cues(request.project.captionTrack?.captionCues ?? [], within: request.range)
                        try CaptionFileCodec.encode(cues, format: .webVTT).write(to: package.appendingPathComponent("captions.vtt"))
                    }
                    let markup = WebVideoMarkup.fragment(title: request.project.name, captions: captions, language: language,
                        languageName: Locale.current.localizedString(forLanguageCode: language) ?? language)
                    try Data(markup.utf8).write(to: package.appendingPathComponent("embed.txt"))
                    try Task.checkCancellation()
                    var output = destination.appendingPathComponent("Web Video")
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: output.path) {
                        output = destination.appendingPathComponent("Web Video \(suffix)")
                        suffix += 1
                    }
                    try FileManager.default.moveItem(at: package, to: output)
                } else {
                    try ExportFileCommit.protectSources(Array(urls.values), destination: destination)
                    let staged = temporary.appendingPathComponent("frame.png")
                    try png.write(to: staged)
                    try ExportFileCommit.commit(staged, to: destination)
                }
                InterfaceSounds.shared.exportCompleted()
                ExportNotificationCenter.postExportCompleted(filename: request.web ? "Web Video" : destination.lastPathComponent)
            } catch is CancellationError {
            } catch {
                presentedError = ProjectPresentedError(title: "Export Failed", message: error.localizedDescription)
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

        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        isPresentingExportPanel = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPresentingExportPanel = false }
            let policy: VideoColorPolicy
            var hasSpatial = false
            var spatialReason: String?
            do {
                for id in Set(self.project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).map(\.assetID))
                    .union(self.project.cutaways.filter { $0.audioMode == .sourceAudio }.map(\.assetID)) {
                    if let url = urls[id], try await SpatialAudioPlan.detect(in: AVURLAsset(url: url)) { hasSpatial = true }
                }
                if hasSpatial {
                    do { _ = try await SpatialAudioPlan.project(self.project, urls: urls) }
                    catch { spatialReason = error.localizedDescription }
                }
                policy = try await VideoColorPolicy.resolve(project: self.project, urls: urls,
                                                           preserveHDR: AppPreferences.preserveHDR())
            } catch {
                self.presentedError = ProjectPresentedError(title: "Export Could Not Be Prepared", message: error.localizedDescription)
                return
            }
            let formats = ExportFormat.projectFormats.filter { format in
                ((format.isAudioOnly && self.project.hasTimelineAudio) ||
                    (!format.isAudioOnly && self.project.hasTimelineVideo && (policy == .sdr || format.supportsHDR || format == .compactMP4)))
            }
            let summary = self.project.hasTimelineVideo
                ? "\(policy == .hlg ? "HDR video" : "SDR video")"
                : nil
            let savePanel = ExportSavePanel(
                title: "Export Project", baseName: self.project.name, formats: formats,
                hasCaptions: self.project.captionTrack?.captionCues.isEmpty == false,
                hasDescriptions: self.project.descriptionTranscriptTrack?.captionCues.isEmpty == false,
                outputSummary: summary, offersAudioChoice: hasSpatial, spatialUnavailableReason: spatialReason)
            let selection = await savePanel.selection(parentWindow: parentWindow)
            guard let selection else { return }
            self.startProjectExport(
                format: selection.format,
                outputURL: selection.url,
                exportRange: exportRange,
                mediaURLs: urls,
                captionDelivery: selection.captionDelivery,
                exportDescriptions: selection.exportDescriptions, audioMode: selection.audioMode
            )
        }
    }

    private func startProjectExport(
        format: ExportFormat,
        outputURL: URL,
        exportRange: ProjectTimeRange?,
        mediaURLs: [UUID: URL],
        captionDelivery: CaptionDelivery,
        exportDescriptions: Bool,
        audioMode: ExportAudioMode
    ) {
        if captionDelivery != .none,
           project.captionTrack?.captionCues.contains(where: \.isDraft) == true {
            outputURL.stopAccessingSecurityScopedResource()
            presentedError = ProjectPresentedError(
                title: "Finalize Captions Before Exporting",
                message: "Choose Timeline > Finalize Captions, then export the project."
            )
            return
        }
        isExporting = true
        exportProgress = 0
        announce("Export started")
        var projectSnapshot = project
        if captionDelivery != .burnedIn {
            for index in projectSnapshot.tracks.indices where projectSnapshot.tracks[index].kind == .captions && projectSnapshot.tracks[index].recordingPurpose != .descriptionTranscript {
                projectSnapshot.tracks[index].captionCues = []
            }
        }
        let sidecarCues = CaptionFileCodec.cues(
            project.captionTrack?.captionCues ?? [],
            within: exportRange
        )
        exportTask = Task { @MainActor in
            defer { outputURL.stopAccessingSecurityScopedResource() }
            var mediaWasSaved = false
            do {
                var companionFiles: [(URL, Data)] = []
                if let sidecarFormat = captionDelivery.sidecarFormat {
                    let data = try CaptionFileCodec.encode(sidecarCues, format: sidecarFormat)
                    companionFiles.append((outputURL.deletingPathExtension().appendingPathExtension(sidecarFormat.fileExtension), data))
                }
                if exportDescriptions {
                    let cues = CaptionFileCodec.cues(projectSnapshot.descriptionTranscriptTrack?.captionCues ?? [], within: exportRange)
                    companionFiles.append((outputURL.deletingPathExtension().appendingPathExtension("descriptions.vtt"),
                                           try CaptionFileCodec.encode(cues, format: .webVTT)))
                }
                try await ProjectExporter.export(
                    project: projectSnapshot,
                    mediaURLs: mediaURLs,
                    timeRange: exportRange,
                    format: format,
                    to: outputURL, audioMode: audioMode
                ) { [weak self] progress in
                    guard let self else { return }
                    let value = min(progress, 0.99)
                    if self.exportProgress != value { self.exportProgress = value }
                }
                mediaWasSaved = true
                for (url, data) in companionFiles {
                    try RelatedExportFileWriter.write(data, to: url, relatedTo: outputURL)
                }
                isExporting = false
                exportProgress = nil
                InterfaceSounds.shared.exportCompleted()
                ExportNotificationCenter.postExportCompleted(filename: outputURL.lastPathComponent)
                announce("Export complete")
            } catch is CancellationError {
                isExporting = false
                exportProgress = nil
                if mediaWasSaved {
                    presentedError = ProjectPresentedError(title: "Export Partly Completed",
                        message: "The media file \(outputURL.lastPathComponent) was saved. Export was cancelled before all caption or description files were saved.")
                    announce("Export partly completed")
                } else { announce("Export canceled") }
            } catch {
                isExporting = false
                exportProgress = nil
                presentedError = ProjectPresentedError(
                    title: mediaWasSaved ? "Export Partly Completed" : "Export Failed",
                    message: mediaWasSaved
                        ? "The media file \(outputURL.lastPathComponent) was saved, but a caption or description file could not be saved. \(error.localizedDescription)"
                        : error.localizedDescription
                )
                announce(mediaWasSaved ? "Export partly completed" : "Export failed")
            }
            exportTask = nil
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportTask?.cancel()
        announce("Canceling export")
    }

    func exportCaptions() {
        guard let cues = project.captionTrack?.captionCues, !cues.isEmpty,
              NSApp.modalWindow == nil,
              let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        guard !cues.contains(where: \.isDraft) else {
            presentedError = ProjectPresentedError(
                title: "Finalize Captions Before Exporting",
                message: "Choose Timeline > Finalize Captions, then export the caption track."
            )
            return
        }
        let panel = CaptionExportSavePanel(baseName: project.name)
        Task { @MainActor [weak self] in
            guard let self, let (url, format) = await panel.selection(parentWindow: parentWindow) else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let range = self.projectPlayer?.exportRange
                let exportedCues = CaptionFileCodec.cues(cues, within: range)
                let data: Data
                if let captionFormat = format.captionFileFormat {
                    data = try CaptionFileCodec.encode(exportedCues, format: captionFormat)
                } else {
                    data = try CaptionFileCodec.encodePlainText(exportedCues, projectTitle: self.project.name)
                }
                try data.write(to: url, options: .atomic)
                self.announce("Captions exported")
            } catch {
                self.presentedError = ProjectPresentedError(
                    title: "Captions Could Not Be Exported",
                    message: error.localizedDescription
                )
            }
        }
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

    var selectedCaptionCue: CaptionCue? {
        selectedCaptionCueID.flatMap(project.captionCue)
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
            selectedCaptionCueID = nil
            let clipSelection = EditorSelection.timelineClip(id)
            if selection != clipSelection { selection = clipSelection }
            projectInfoTarget = .selection(.timelineClip(id))
            if let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
                editorDirectClipIDs[track.id] = id
            }
        case .transition(let id):
            selectedCaptionCueID = nil
            let transitionSelection = EditorSelection.transition(id)
            if selection != transitionSelection { selection = transitionSelection }
            projectInfoTarget = .selection(.transition(id))
        case .marker(let id):
            selectedMarkerID = id
            selection = .project
        case .caption(let id):
            selection = .project
            selectedCaptionCueID = id
        }
    }

    func addCaptionCue(start: ProjectTime, end: ProjectTime, text: String) throws -> UUID {
        let cue = try CaptionCue(start: start, end: end, text: text, isDraft: true).validated()
        guard end <= project.nonCaptionDuration else {
            throw CaptionFileError.invalidCue("The caption ends after the project media.")
        }
        try mutateProjectThrowing(actionName: "Add Caption") { try $0.addCaptionCues([cue]) }
        activeTimelineTrackID = project.captionTrack?.id
        selection = .project
        selectedCaptionCueID = cue.id
        return cue.id
    }

    func finalizeCaptions() {
        guard canFinalizeCaptions, let cues = project.captionTrack?.captionCues else { return }
        let result = CaptionFinalizer.finalize(
            cues: cues,
            projectDuration: project.nonCaptionDuration,
            width: project.format.width ?? 1_920,
            height: project.format.height ?? 1_080,
            frameRate: project.format.frameRate ?? 30
        )
        do {
            if result.changed {
                try mutateProjectThrowing(actionName: "Finalize Captions") {
                    try $0.replaceCaptionCues(result.cues)
                }
            }
            activeTimelineTrackID = project.captionTrack?.id
            if !result.issues.isEmpty {
                captionFinalizationReport = CaptionFinalizationReport(
                    finalizedPassages: result.finalizedPassages,
                    createdCues: result.createdCues,
                    issues: result.issues,
                    fatalError: nil
                )
            } else {
                announce("Captions finalized")
            }
        } catch {
            captionFinalizationReport = CaptionFinalizationReport(
                finalizedPassages: 0,
                createdCues: 0,
                issues: [],
                fatalError: error.localizedDescription
            )
        }
    }

    func dismissCaptionFinalizationReport() {
        captionFinalizationReport = nil
    }

    func revealCaptionFinalizationIssue(_ cueID: UUID) {
        guard project.captionCue(id: cueID) != nil else { return }
        activeTimelineTrackID = project.captionTrack?.id
        focusTimelineElement(.caption(cueID))
        movePlayheadToCaption(id: cueID)
        requestTimelineFocusRestore(to: .caption(cueID))
    }

    func updateCaptionCue(_ cue: CaptionCue) throws {
        guard cue.end <= project.nonCaptionDuration else {
            throw CaptionFileError.invalidCue("The caption ends after the project media.")
        }
        try mutateProjectThrowing(actionName: "Update Caption") { try $0.updateCaptionCue(cue) }
        selection = .project
        selectedCaptionCueID = cue.id
    }

    func deleteCaptionCue(id: UUID) throws {
        try mutateProjectThrowing(actionName: "Delete Caption") { try $0.removeCaptionCue(id: id) }
        selectedCaptionCueID = nil
        selection = .project
    }

    func deleteSelectedCaptionCue() {
        guard let id = selectedCaptionCueID else { return }
        do { try deleteCaptionCue(id: id) }
        catch { announce(error.localizedDescription) }
    }

    func setProjectInfoTarget(_ target: ProjectInfoTarget) {
        projectInfoTarget = target
    }

    func projectInfoSnapshot(editorFocused: Bool = false,
                             selection selectionOverride: EditorSelection? = nil) -> ProjectInfoSnapshot {
        projectInfoSnapshot(
            editorFocused: editorFocused,
            selection: selectionOverride,
            technicalDetails: nil
        )
    }

    func projectInfoSnapshotWithTechnicalDetails(
        editorFocused: Bool = false,
        selection selectionOverride: EditorSelection? = nil
    ) async -> ProjectInfoSnapshot {
        let target = resolvedProjectInfoTarget(
            editorFocused: editorFocused,
            selection: selectionOverride
        )
        let details = await technicalDetails(for: target)
        return ProjectInfoSnapshot.make(
            target: target,
            project: project,
            playhead: timelinePlayhead,
            activeTrackID: activeTimelineTrackID,
            technicalDetails: details
        )
    }

    private func projectInfoSnapshot(
        editorFocused: Bool,
        selection selectionOverride: EditorSelection?,
        technicalDetails: FFmpegMediaProbe.Report.TechnicalDetails?
    ) -> ProjectInfoSnapshot {
        let target = resolvedProjectInfoTarget(
            editorFocused: editorFocused,
            selection: selectionOverride
        )
        return ProjectInfoSnapshot.make(
            target: target,
            project: project,
            playhead: timelinePlayhead,
            activeTrackID: activeTimelineTrackID,
            technicalDetails: technicalDetails
        )
    }

    private func resolvedProjectInfoTarget(
        editorFocused: Bool,
        selection selectionOverride: EditorSelection?
    ) -> ProjectInfoTarget {
        let target: ProjectInfoTarget
        if let selectionOverride {
            target = .selection(selectionOverride)
        } else if editorFocused {
            target = .editor
        } else {
            target = projectInfoTarget
        }
        return target
    }

    private func technicalDetails(
        for target: ProjectInfoTarget
    ) async -> FFmpegMediaProbe.Report.TechnicalDetails? {
        let asset: MediaAssetRecord?
        switch target {
        case .selection(.asset(let id)):
            asset = project.asset(id: id)
        case .selection(.timelineClip(let id)):
            asset = project.timelineClip(id: id).flatMap { project.asset(id: $0.assetID) }
        case .selection(.cutaway(let id)):
            asset = project.cutaways.first(where: { $0.id == id }).flatMap { project.asset(id: $0.assetID) }
        default:
            asset = nil
        }
        guard let asset, asset.generator == nil, let url = resolveURL(for: asset) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? await FFmpegMediaProbe.inspect(url: url).technicalDetails
    }

    func trimTimelineClipEnd(id: UUID) throws {
        try mutateProjectThrowing(actionName: "Trim Timeline Clip End") {
            try $0.trimTrackClipEnd(id: id, at: timelinePlayhead)
        }
        selection = .timelineClip(id)
        announce("Clip end trimmed to project playhead")
    }

    func selectAdjacentTrack(_ offset: Int, restoreTimelineFocus: Bool = true) {
        let tracks = project.orderedTimelineTracks
        guard !tracks.isEmpty else { return }
        let current = (activeTimelineTrack?.id).flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        let destination = min(max(current + offset, 0), tracks.count - 1)
        let track = tracks[destination]
        activeTimelineTrackID = track.id
        let target = Self.timelineNavigationTarget(on: track, at: timelinePlayhead,
            transitions: TimelineElementSequence.transitions(for: track, in: project))
        TimelineFocusDiagnostics.record("track-command offset=\(offset) from=\(current) to=\(destination) track=\(track.id) role=\(track.role) target=\(String(describing: target?.selection)) restore=\(restoreTimelineFocus)")
        let announcement = Self.activeTrackAnnouncement(trackName: track.name, clipName: target?.name)
        pendingTrackAnnouncement = nil
        guard restoreTimelineFocus else { announce(announcement); return }
        selectedCaptionCueID = nil
        selectedMarkerID = nil
        switch target?.selection {
        case .clip(let id): selection = .timelineClip(id)
        case .transition(let id): selection = .transition(id)
        case .caption(let id):
            selection = .project
            selectedCaptionCueID = id
        case .marker(let id):
            selection = .project
            selectedMarkerID = id
        case nil: selection = .project
        }
        if let target {
            requestTimelineFocusRestore(to: target.selection)
        } else {
            requestTimelineListFocusRestore()
        }
        pendingTrackAnnouncement = PendingTrackAnnouncement(trackID: track.id, target: target?.selection,
            itemRevision: timelineFocusRestoreRequest, listRevision: timelineListFocusRestoreRequest,
            message: announcement)
    }

    func timelineTrackKeyboardFocusArrived(_ target: TimelineElementSelection?, itemRevision: Int, listRevision: Int) {
        guard let message = takePendingTrackAnnouncement(target, itemRevision: itemRevision, listRevision: listRevision) else { return }
        TimelineFocusDiagnostics.record("track-announcement-after-keyboard-focus target=\(String(describing: target)) itemRevision=\(itemRevision) listRevision=\(listRevision)")
        announce(message)
    }

    func takePendingTrackAnnouncement(_ target: TimelineElementSelection?, itemRevision: Int, listRevision: Int) -> String? {
        guard let pending = pendingTrackAnnouncement,
              pending.trackID == activeTimelineTrackID, pending.target == target,
              pending.itemRevision == itemRevision, pending.listRevision == listRevision,
              itemRevision == timelineFocusRestoreRequest, listRevision == timelineListFocusRestoreRequest else { return nil }
        pendingTrackAnnouncement = nil
        return pending.message
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
        if project.tracks[trackIndex].isMagnetic {
            try project.updateTrackClip(id: id, segments: retainedSegments)
        } else {
            project.tracks[trackIndex].clips[clipIndex].segments = retainedSegments
            project.tracks[trackIndex].clips[clipIndex].timelineStart = playhead
        }
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
              let clip = mode == .quickFade ? editorClip(at: time)
                : track.sortedClips.first(where: { time >= $0.timelineStart && time <= $0.timelineEnd }) else {
            announce("Move the playhead to a clip first")
            return
        }
        transitionRequestReturnsToEditor = true
        let outgoing = mode == .quickFade && clip.timelineStart == time
            ? track.sortedClips.last(where: { $0.id != clip.id && $0.timelineEnd == time }) : nil
        transitionRequest = TransitionRequest(trackID: track.id, clipID: clip.id, mode: mode,
                                               fadeOutClipID: outgoing?.id)
    }

    func requestQuickTransition(at time: ProjectTime, mode: TransitionRequest.Mode) {
        requestTransition(at: time, mode: mode)
    }

    func beginWorkspaceNavigation(_ pane: WorkspacePane) {
        workspaceNavigation = WorkspaceFocusRequest(pane: pane, revision: workspaceNavigation.revision + 1)
    }

    func requestToolFocus() {
        guard toolPane != nil else { return }
        beginWorkspaceNavigation(.tool)
        toolFocusRevision += 1
    }

    func requestEditorFocusRestore() {
        beginWorkspaceNavigation(.editor)
        pendingTrackAnnouncement = nil
        editorFocusRestoreRequest += 1
    }

    // Initial presentation waits for all preview work, including a pending spatial
    // mix rebuild. Later edits keep the existing workspace in place.
    var canPresentWorkspace: Bool {
        guard isWorkspacePreparationPending else { return true }
        guard let projectPlayer else { return false }
        return !projectPlayer.isInitialPreparationPending && !projectPlayer.isPreparing
    }

    @discardableResult
    func finishWorkspacePreparation() -> Bool {
        guard isWorkspacePreparationPending, canPresentWorkspace else { return false }
        isWorkspacePreparationPending = false
        let empty = project.media.isEmpty && project.folders.isEmpty &&
            project.primaryTimeline.isEmpty && project.cutaways.isEmpty &&
            project.tracks.allSatisfy { $0.clips.isEmpty && $0.captionCues.isEmpty && $0.markers.isEmpty }
        openingEntry.install(target: empty ? .importFiles : .projectSource,
                             hasFailure: projectPlayer?.errorMessage != nil)
        return true
    }

    var canEnterInitialWorkspace: Bool {
        openingEntry.pendingTarget != nil && acceptsWorkspaceCommands &&
            projectPlayer?.isPreparing == false && projectPlayer?.presentedPreviewFailure == nil
    }

    func confirmInitialWorkspaceEntry(_ target: ProjectOpeningEntry.Target, isKeyboardDestination: Bool) {
        guard openingEntry.confirm(target, windowReady: canEnterInitialWorkspace,
                                   isKeyboardDestination: isKeyboardDestination) else { return }
        recordWorkspaceReadiness("opening-keyboard-entry-confirmed")
    }

    func refreshInitialWorkspaceEntry() {
        if openingEntry.pendingTarget != nil { objectWillChange.send() }
    }

    func finishInitialPreviewFailureReview() { openingEntry.finishFailureReview() }
    func cancelInitialWorkspaceEntry() { openingEntry.cancel() }

    var isPreparingProject: Bool {
        isWorkspacePreparationPending || projectPlayer?.isInitialPreparationPending == true
    }

    var acceptsWorkspaceCommands: Bool {
        projectSaveCoordinator?.acceptsWorkspaceCommands == true && !isPreparingProject && !isImporting &&
            !isExporting && !isPresentingExportPanel && applyingTransitionName == nil
    }

    func requestWorkspaceFocus(_ pane: WorkspacePane) {
        recordWorkspaceReadiness("command-\(pane.rawValue)")
        pendingTrackAnnouncement = nil
        guard acceptsWorkspaceCommands else { return }
        // A user-selected pane supersedes any delayed initial entry.
        cancelInitialWorkspaceEntry()
        if pane == .tool {
            guard toolPane != nil else { return }
            requestToolFocus()
        } else { beginWorkspaceNavigation(pane) }
        workspaceFocusRequest = WorkspaceFocusRequest(pane: pane, revision: workspaceFocusRequest.revision + 1)
    }

    func recordWorkspaceReadiness(_ reason: String) {
        #if DEBUG
        TimelineFocusDiagnostics.record("workspace-readiness \(reason) project=\(ObjectIdentifier(self)) accepts=\(acceptsWorkspaceCommands) preparing=\(isPreparingProject) opening=\(openingEntry.phase) importing=\(isImporting) exporting=\(isExporting) exportPanel=\(isPresentingExportPanel) transition=\(applyingTransitionName != nil) active=\(NSApp?.isActive == true) modal=\(NSApp?.modalWindow != nil) closing=\(projectSaveCoordinator?.isResolvingClose == true) quitting=\(projectSaveCoordinator?.isApplicationTerminating == true) \(TimelineFocusDiagnostics.windowState(projectSaveCoordinator?.attachedWindow))")
        #endif
    }

    func beginProjectSourceImportFocus(returningTo item: ProjectSourceItemID?) {
        sourceImportFocus = (Set(project.media.map(\.id)), item ?? .clips(project.id))
    }

    /// Called only after import progress has dismissed and the project window has returned.
    @discardableResult
    func finishProjectSourceImportFocus() -> Bool {
        guard !isImporting, let pending = sourceImportFocus else { return false }
        sourceImportFocus = nil
        let importedID = ProjectSourcePasteFocus.firstImportedAssetID(
            existingAssetIDs: pending.existingIDs, assets: project.media)
        requestProjectSourceFocus(to: importedID.map { .asset($0) } ?? pending.fallback)
        return true
    }

    func requestProjectSourceFocus(to item: ProjectSourceItemID) {
        beginWorkspaceNavigation(.project)
        pendingTrackAnnouncement = nil
        projectSourceFocusRequest.target = item
        projectSourceFocusRequest.revision += 1
    }

    func installEditorAccessibilityFocusProvider(_ provider: @escaping () -> Bool) {
        editorAccessibilityFocusProvider = provider
    }

    func requestEditorFocusRestoreIfNeeded() {
        guard editorAccessibilityFocusProvider?() != true else { return }
        requestEditorFocusRestore()
    }

    func restoreTimelineClipAfterEditing(id: UUID) {
        guard let track = project.tracks.first(where: { $0.clips.contains(where: { $0.id == id }) }) else { return }
        activeTimelineTrackID = track.id
        selection = .timelineClip(id)
        requestTimelineFocusRestore(to: .clip(id))
    }

    func requestTimelineFocusRestore(to element: TimelineElementSelection) {
        beginWorkspaceNavigation(.timeline)
        pendingTrackAnnouncement = nil
        TimelineFocusDiagnostics.record("controller-item-request target=\(element) nextRevision=\(timelineFocusRestoreRequest + 1)")
        timelineFocusRestoreTarget = element
        timelineFocusRestoreRequest += 1
    }

    func requestTimelineListFocusRestore() {
        beginWorkspaceNavigation(.timeline)
        pendingTrackAnnouncement = nil
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

    func deleteTransition(id: UUID, selecting selectionAfterDeletion: EditorSelection = .project) {
        mutateProject(actionName: "Delete Transition") { $0.removeTransition(id: id) }
        if selection != selectionAfterDeletion { selection = selectionAfterDeletion }
        projectInfoTarget = .selection(selectionAfterDeletion)
    }

    func deleteTimelineClip(id: UUID, selecting selectionAfterDeletion: EditorSelection) {
        do {
            try mutateProjectThrowing(actionName: "Remove from Timeline") { try $0.removeTrackClip(id: id) }
            if selection != selectionAfterDeletion { selection = selectionAfterDeletion }
            projectInfoTarget = .selection(selectionAfterDeletion)
            announce("Timeline clip removed")
        } catch {
            announce(error.localizedDescription)
        }
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

    nonisolated static func timelineNavigationClip(
        on track: TimelineTrack,
        at time: ProjectTime
    ) -> TimelineClip? {
        let clips = track.sortedClips
        return clips.first(where: { $0.timelineStart == time })
            ?? clips.first(where: { time >= $0.visibleTimelineStart && time < $0.visibleTimelineEnd })
            ?? clips.first(where: { $0.visibleTimelineStart > time })
            ?? clips.last
    }

    nonisolated struct TrackNavigationTarget: Equatable {
        let selection: TimelineElementSelection
        let name: String
    }

    nonisolated static func timelineNavigationTarget(
        on track: TimelineTrack, at time: ProjectTime,
        transitions: [TimelineTransition] = []
    ) -> TrackNavigationTarget? {
        switch track.kind {
        case .video, .audio:
            if let clip = timelineNavigationClip(on: track, at: time) {
                return TrackNavigationTarget(selection: .clip(clip.id), name: clip.displayName)
            }
            // An orphaned transition is still an item displayed by the collection.
            guard let transition = transitions.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first else { return nil }
            return TrackNavigationTarget(selection: .transition(transition.id), name: transition.displayName)
        case .captions:
            let cues = track.sortedCaptionCues
            guard let cue = cues.first(where: { $0.start == time })
                ?? cues.first(where: { $0.start <= time && time < $0.end })
                ?? cues.first(where: { $0.start > time })
                ?? cues.last else { return nil }
            return TrackNavigationTarget(selection: .caption(cue.id), name: cue.displayName)
        case .markers:
            let markers = track.sortedMarkers
            guard let marker = markers.first(where: { $0.time >= time }) ?? markers.last else { return nil }
            return TrackNavigationTarget(selection: .marker(marker.id), name: marker.title)
        }
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

    func currentTimelineClip(at time: ProjectTime) -> TimelineClip? {
        activeTimelineTrack?.sortedClips.first {
            time >= $0.visibleTimelineStart && time < $0.visibleTimelineEnd
        }
    }

    func toggleClipMovement(id: UUID) {
        if movingTimelineClipID != nil { finishClipMovement() }
        else { beginClipMovement(id: id) }
    }

    func beginClipMovement(id: UUID) {
        guard movingTimelineClipID == nil, let clip = project.timelineClip(id: id) else { return }
        movementBaseline = project
        movementPreview = project
        movementNudgeOrigin = project
        movementNudgeFrames = 0
        movingTimelineClipID = id
        selection = .timelineClip(id)
        announce("Moving \(clip.displayName). \(movementPositionDescription ?? "")")
    }

    var movementPositionDescription: String? {
        guard let id = movingTimelineClipID, let preview = movementPreview,
              let track = preview.tracks.first(where: { $0.clips.contains { $0.id == id } }),
              let index = track.sortedClips.firstIndex(where: { $0.id == id }) else { return nil }
        if track.role == .additional && !track.isMagnetic {
            return Self.nudgePositionDescription(clip: track.sortedClips[index], track: track, project: preview)
        }
        return "Position \(index + 1) of \(track.clips.count), \(track.name) track"
    }

    func finishClipMovement() {
        guard let id = movingTimelineClipID, let preview = movementPreview,
              let baseline = movementBaseline else { return }
        let name = preview.timelineClip(id: id)?.displayName ?? "Clip"
        clearClipMovement()
        guard project == baseline else {
            announce("Clip movement cancelled because the project changed")
            return
        }
        guard preview != baseline else {
            announce("Dropped \(name)")
            return
        }
        apply(preview, undoingTo: baseline, actionName: "Move Timeline Clip")
        if let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
            activeTimelineTrackID = track.id
        }
        selection = .timelineClip(id)
        requestTimelineFocusRestore(to: .clip(id))
        announce("Dropped \(name)")
    }

    func cancelClipMovement() {
        guard movingTimelineClipID != nil else { return }
        clearClipMovement()
        announce("Clip movement cancelled")
    }

    private func clearClipMovement() {
        movingTimelineClipID = nil
        movementPreview = nil
        movementBaseline = nil
        movementNudgeOrigin = nil
        movementNudgeFrames = 0
    }

    var clipMovementSourceID: UUID? { movingTimelineClipID ?? copiedTimelineClipID }

    func canMoveClip(to destination: TimelineMoveDestination, targetID: UUID) -> Bool {
        let sourceID = movingTimelineClipID ?? targetID
        guard let source = project.tracks.first(where: { $0.clips.contains { $0.id == sourceID } }),
              let target = (destination == .start || destination == .end || destination == .playhead) ? activeTimelineTrack : project.tracks.first(where: { $0.clips.contains { $0.id == targetID } }),
              source.kind == target.kind else { return false }
        if destination == .playhead { return !target.isMagnetic && target.role == .additional }
        return destination == .start || destination == .end || sourceID != targetID
    }

    func previewClipMovement(to destination: TimelineMoveDestination, targetID: UUID, destinationTrackID: UUID? = nil) -> Bool {
        guard let id = movingTimelineClipID, var preview = movementBaseline else { return false }
        guard project == movementBaseline else { cancelClipMovement(); return false }
        do {
            try preview.moveTrackClip(id: id, to: destination, targetID: targetID, destinationTrackID: destinationTrackID, playhead: timelinePlayhead)
            guard preview != movementPreview else { return true }
            movementPreview = preview
            movementNudgeOrigin = preview
            movementNudgeFrames = 0
            announce(movementPositionDescription)
            return true
        } catch {
            announce(error.localizedDescription)
            return false
        }
    }

    func moveClip(to destination: TimelineMoveDestination, targetID: UUID) {
        let trackID = (destination == .start || destination == .end || destination == .playhead) ? activeTimelineTrackID : nil
        if movingTimelineClipID != nil {
            if previewClipMovement(to: destination, targetID: targetID, destinationTrackID: trackID) { finishClipMovement() }
        } else {
            moveTimelineClip(id: targetID, to: destination, targetID: targetID, destinationTrackID: trackID)
        }
    }

    func moveTimelineClip(id: UUID, to destination: TimelineMoveDestination, targetID: UUID, destinationTrackID: UUID? = nil) {
        do {
            let wasLinked = project.timelineClip(id: id)?.linkedClipID != nil
            let playhead = timelinePlayhead
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveTrackClip(id: id, to: destination, targetID: targetID, destinationTrackID: destinationTrackID, playhead: playhead)
            }
            didMoveClip(id, becameIndependent: wasLinked && project.timelineClip(id: id)?.linkedClipID == nil)
        } catch {
            presentedError = ProjectPresentedError(title: "Clip Could Not Be Moved", message: error.localizedDescription)
        }
    }

    func moveMarkedClip(by offset: Int) {
        guard let id = movingTimelineClipID, let preview = movementPreview,
              let track = preview.tracks.first(where: { $0.clips.contains { $0.id == id } }),
              let index = track.sortedClips.firstIndex(where: { $0.id == id }) else { return }
        if track.role == .additional && !track.isMagnetic {
            nudgeTimelineClip(id: id, by: offset)
            return
        }
        guard track.sortedClips.indices.contains(index + offset) else {
            announce(offset < 0 ? "Start of track" : "End of track")
            return
        }
        _ = previewClipMovement(to: offset < 0 ? .before : .after, targetID: track.sortedClips[index + offset].id)
    }

    func canNudgeTimelineClip(id: UUID) -> Bool {
        project.tracks.contains { $0.role == .additional && !$0.isMagnetic && $0.clips.contains { $0.id == id } }
    }

    func moveFocusedTimelineClip(id: UUID, by offset: Int) {
        if movingTimelineClipID != nil { moveMarkedClip(by: offset) }
        else if canNudgeTimelineClip(id: id) { nudgeTimelineClip(id: id, by: offset) }
    }

    private func nudgeTimelineClip(id: UUID, by offset: Int) {
        guard offset != 0 else { return }
        do {
            if movingTimelineClipID == id {
                guard project == movementBaseline else { cancelClipMovement(); return }
                guard var preview = movementNudgeOrigin else { return }
                let frames = movementNudgeFrames + offset
                try preview.nudgeAdditionalTrackClip(id: id, byFrames: frames)
                movementNudgeFrames = frames
                movementPreview = preview
                announce(movementPositionDescription)
            } else {
                try mutateProjectThrowing(actionName: "Nudge Timeline Clip") {
                    try $0.nudgeAdditionalTrackClip(id: id, byFrames: offset)
                }
                guard let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }),
                      let clip = track.clips.first(where: { $0.id == id }) else { return }
                // Updating the time does not select the clip, move the playhead,
                // or request a focus reset. Neighboring clips stay where they are.
                announce("\(clip.displayName), \(Self.nudgePositionDescription(clip: clip, track: track, project: project))")
            }
        } catch { announce(error.localizedDescription) }
    }

    private static func nudgePositionDescription(clip: TimelineClip, track: TimelineTrack, project: TrimatoProject) -> String {
        let rate = project.format.frameRate ?? 30
        let frameRate = rate.isFinite && rate > 0 ? rate : 30
        let frame = Int((clip.timelineStart.seconds * frameRate).rounded())
        return "Start at frame \(frame), \(track.name) track"
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

    func setTrackMagnetic(id: UUID, enabled: Bool) throws {
        try mutateProjectThrowing(actionName: enabled ? "Enable Magnetic Track" : "Disable Magnetic Track") {
            try $0.setTrackMagnetic(id: id, enabled: enabled)
        }
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
        if movingTimelineClipID != nil {
            moveClip(to: .after, targetID: targetID)
        } else if let copiedTimelineClipID {
            moveTimelineClip(id: copiedTimelineClipID, to: .after, targetID: targetID)
        } else {
            announce("Copy a Timeline clip first")
        }
    }

    func installMediaLocations(_ locations: [UUID: URL], projectFolder: URL) {
        var updated = document.project
        for index in updated.media.indices {
            guard let url = locations[updated.media[index].id] else { continue }
            updated.media[index].originalPath = url.path
            updated.media[index].bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            updated.media[index].projectRelativePath = MediaFileReference.relativePath(for: url, in: projectFolder)
            updated.media[index].recordingRelativePath = nil
            mediaLocationOverrides[updated.media[index].id] = updated.media[index]
        }
        document.project = updated
        timelineContentRevision += 1
        mediaFiles.refresh()
    }

    func resolveURL(for asset: MediaAssetRecord) -> URL? {
        if let generator = asset.generator { return try? GeneratorRenderer.cacheURL(for: generator) }
        if let bookmark = project.recordingsFolderBookmark {
            var stale = false
            if let granted = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
               !accessedURLs.contains(granted), granted.startAccessingSecurityScopedResource() {
                accessedURLs.append(granted)
            }
        }
        if let url = MediaFileReference.relativeURL(asset.projectRelativePath ?? asset.recordingRelativePath,
            folder: projectSaveCoordinator?.projectURL?.deletingLastPathComponent()),
           FileManager.default.isReadableFile(atPath: url.path) { return url }
        guard let url = ProjectImportCoordinator.resolveURL(for: asset) else { return nil }
        if !accessedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
        return url
    }

    func preparedMediaSource(
        for requestedAsset: MediaAssetRecord,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> MediaSource? {
        guard var asset = project.asset(id: requestedAsset.id) else { return nil }
        if let generator = asset.generator {
            let url = try await GeneratorRenderer.ensure(generator)
            return .native(url: url, asset: AVURLAsset(url: url), contentType: nil, mode: .nativePlaybackMP4Export, hasVideo: asset.hasVideo, hasAudio: asset.hasAudio)
        }
        let reference = asset
        let folder = projectSaveCoordinator?.projectURL?.deletingLastPathComponent()
        let folderBookmark = project.recordingsFolderBookmark
        let resolved = await Task.detached(priority: .userInitiated) {
            MediaFileAccess.resolve(reference, folder: folder, folderBookmark: folderBookmark)
        }.value
        try Task.checkCancellation()
        guard let originalURL = resolved else { mediaFiles.refresh(); return nil }
        if !accessedURLs.contains(originalURL), originalURL.startAccessingSecurityScopedResource() {
            accessedURLs.append(originalURL)
        }
        // Activate the project folder's saved grant for project-relative source URLs.
        if let bookmark = folderBookmark {
            var stale = false
            if let granted = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
               !accessedURLs.contains(granted), granted.startAccessingSecurityScopedResource() {
                accessedURLs.append(granted)
            }
        }
        let currentFingerprint = try await Task.detached(priority: .userInitiated) {
            try MediaCacheManager.sourceFingerprint(for: originalURL)
        }.value
        if asset.playbackMode == nil || asset.sourceFingerprint != currentFingerprint {
            let previousCacheKey = asset.proxyCacheKey
            let preparation = try await ProjectImportCoordinator.preparePlayback(
                at: originalURL,
                preferredCacheKey: asset.sourceFingerprint == nil ? asset.proxyCacheKey : nil,
                progress: progress
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
                hasVideo: asset.hasVideo,
                progress: progress
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
        guard !isImporting, !mediaFiles.isBusy, !isRelinkingMedia,
              projectFilePanel == nil,
              NSApp.modalWindow == nil,
              let parentWindow = projectSaveCoordinator?.attachedWindow,
              parentWindow.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Media or Captions"
        MediaSelection.configure(panel, importing: true)
        projectFilePanel = panel
        Self.afterCurrentViewUpdate { [weak self, weak parentWindow] in
            guard let self, let parentWindow,
                  self.projectFilePanel === panel,
                  parentWindow.isVisible,
                  parentWindow.isKeyWindow,
                  parentWindow.attachedSheet == nil else {
                if self?.projectFilePanel === panel { self?.projectFilePanel = nil }
                return
            }
            panel.beginSheetModal(for: parentWindow) { [weak self] response in
                guard let self else { return }
                let urls = response == .OK ? panel.urls : []
                self.projectFilePanel = nil
                panel.orderOut(nil)
                guard !urls.isEmpty else { return }
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.importFiles(at: urls, into: folderID)
                }
            }
        }
    }

    static func afterCurrentViewUpdate(_ action: @escaping () -> Void) {
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    func importFiles(at urls: [URL], into folderID: UUID? = nil) {
        guard !isImporting, !mediaFiles.isBusy, !isRelinkingMedia, !urls.isEmpty else { return }
        isImporting = true
        canCancelImport = true
        importProgress = nil
        importDetail = nil
        importOutcome = .completed
        importTask = Task { @MainActor in
            defer {
                if Task.isCancelled { importOutcome = .cancelled }
                isImporting = false
                canCancelImport = false
                importTask = nil
            }
            guard let handling = await mediaFiles.importHandling(), !Task.isCancelled else { return }
            if handling == .move, projectSaveCoordinator?.projectURL == nil {
                presentedError = .init(title: "Save Project First", message: "Save the project before moving imported media into its Clips folder.")
                return
            }
            importDetail = "Finding files"
            struct ImportGroup {
                var folderName: String?
                var assets: [MediaAssetRecord]
            }
            var groups: [ImportGroup] = []
            var importedCaptionCues: [CaptionCue] = []
            var failures: [(name: String, message: String)] = []
            var importPaths = Set(project.media.map {
                URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path
            })
            var totalCandidates = 0
            for selectedURL in urls {
                guard !Task.isCancelled else { return }
                let scoped = selectedURL.startAccessingSecurityScopedResource()
                defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
                if let media = try? ProjectImportCoordinator.importableMediaURLs(in: selectedURL),
                   let captions = try? ProjectImportCoordinator.importableCaptionURLs(in: selectedURL) {
                    totalCandidates += media.count + captions.count
                }
            }
            var completedCandidates = 0
            if totalCandidates > 0 { importProgress = 0 }

            @MainActor
            func updateOverallProgress(_ currentFileProgress: Double) {
                guard totalCandidates > 0 else {
                    importProgress = nil
                    return
                }
                let bounded = min(max(currentFileProgress, 0), 1)
                importProgress = min(
                    max((Double(completedCandidates) + bounded) / Double(totalCandidates), 0),
                    1
                )
            }

            @MainActor
            func finishCandidate() {
                completedCandidates += 1
                updateOverallProgress(0)
            }

            for selectedURL in urls {
                guard !Task.isCancelled else { return }
                let scoped = selectedURL.startAccessingSecurityScopedResource()
                defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
                do {
                    let isDirectory = try selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    let candidates = try ProjectImportCoordinator.importableMediaURLs(in: selectedURL)
                    let captionCandidates = try ProjectImportCoordinator.importableCaptionURLs(in: selectedURL)
                    guard !candidates.isEmpty || !captionCandidates.isEmpty else {
                        failures.append((selectedURL.lastPathComponent, "No supported audio, video, SRT, or WebVTT files were found."))
                        continue
                    }
                    var assets: [MediaAssetRecord] = []
                    for candidate in candidates {
                        guard !Task.isCancelled else { return }
                        importDetail = "\(candidate.lastPathComponent): Importing media"
                        let standardizedPath = candidate.standardizedFileURL.path
                        guard importPaths.insert(standardizedPath).inserted else {
                            finishCandidate()
                            continue
                        }
                        do {
                            assets.append(try await ProjectImportCoordinator.importAsset(
                                at: candidate,
                                progress: { progress in
                                    self.importDetail = "\(candidate.lastPathComponent): Creating playback proxy"
                                    updateOverallProgress(progress)
                                }
                            ))
                        } catch is CancellationError {
                            importOutcome = .cancelled
                            return
                        } catch {
                            failures.append((candidate.lastPathComponent, error.localizedDescription))
                        }
                        finishCandidate()
                    }
                    if !assets.isEmpty {
                        groups.append(ImportGroup(
                            folderName: isDirectory && folderID == nil
                                ? selectedURL.lastPathComponent
                                : nil,
                            assets: assets
                        ))
                    }
                    for candidate in captionCandidates {
                        guard !Task.isCancelled else { return }
                        importDetail = "\(candidate.lastPathComponent): Importing captions"
                        do {
                            let cues = try ProjectImportCoordinator.importCaptionCues(at: candidate)
                            if let last = cues.map(\.end).max(), last > project.nonCaptionDuration {
                                throw CaptionFileError.invalidCue("A caption ends after the project media.")
                            }
                            importedCaptionCues.append(contentsOf: cues)
                        } catch {
                            failures.append((candidate.lastPathComponent, error.localizedDescription))
                        }
                        finishCandidate()
                    }
                } catch {
                    failures.append((selectedURL.lastPathComponent, error.localizedDescription))
                }
            }
            guard !Task.isCancelled else { return }
            let additions = groups.flatMap(\.assets)
            if !additions.isEmpty || !importedCaptionCues.isEmpty {
                let actionName = additions.isEmpty ? "Import Captions"
                    : importedCaptionCues.isEmpty ? "Import Media"
                    : "Import Media and Captions"
                mutateProject(actionName: actionName) { project in
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
                    if !importedCaptionCues.isEmpty {
                        let trackID = project.ensureCaptionTrack()
                        if let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) {
                            project.tracks[trackIndex].captionCues.append(contentsOf: importedCaptionCues)
                        }
                    }
                }
            }
            if handling == .move, !additions.isEmpty {
                do { try await mediaFiles.transfer(ids: Set(additions.map(\.id)), move: true) }
                catch { failures.append(("Move to Project", error.localizedDescription)) }
            }
            mediaFiles.refresh()
            if !additions.isEmpty, !importedCaptionCues.isEmpty {
                announce("Imported \(additions.count) clip\(additions.count == 1 ? "" : "s") and \(importedCaptionCues.count) caption\(importedCaptionCues.count == 1 ? "" : "s")")
            } else if !additions.isEmpty {
                announce("Imported \(additions.count) clip\(additions.count == 1 ? "" : "s")")
            } else if !importedCaptionCues.isEmpty {
                announce("Imported \(importedCaptionCues.count) caption\(importedCaptionCues.count == 1 ? "" : "s")")
            }
            if !failures.isEmpty {
                importOutcome = .failed
                let details = failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
                presentedError = ProjectPresentedError(
                    title: additions.isEmpty && importedCaptionCues.isEmpty ? "Import Failed" : "Some Files Could Not Be Imported",
                    message: details
                )
                announce(additions.isEmpty && importedCaptionCues.isEmpty ? "Import failed" : "Some files could not be imported")
            } else {
                importOutcome = .completed
            }
        }
    }

    func importExternalFile(at url: URL, completion: @escaping (UUID) -> Void) {
        guard !isImporting, !mediaFiles.isBusy else {
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
                guard let handling = await mediaFiles.importHandling() else { isImporting = false; return }
                if handling == .move, projectSaveCoordinator?.projectURL == nil {
                    throw QuitDraftError(message: "Save the project before moving imported media into its Clips folder.")
                }
                importDetail = "Importing media"
                let asset = try await ProjectImportCoordinator.importAsset(at: url)
                mutateProject(actionName: "Import Media") { project in
                    project.media.append(asset)
                }
                if handling == .move { try await mediaFiles.transfer(ids: [asset.id], move: true) }
                mediaFiles.refresh()
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
        guard project.asset(id: assetID)?.generator == nil else { return }
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
        mutateProject(actionName: "Delete Media") { project in
            project.removeSourceAsset(assetID)
        }
        switch selection {
        case .asset(let id) where id == assetID: selection = .project
        case .timelineClip(let id) where project.timelineClip(id: id) == nil: selection = .project
        case .cutaway(let id) where !project.cutaways.contains(where: { $0.id == id }): selection = .project
        case .transition(let id) where project.transition(id: id) == nil: selection = .project
        default: break
        }
        projectInfoTarget = .selection(selection)
        if activeTimelineTrackID.flatMap({ project.track(id: $0) }) == nil {
            activeTimelineTrackID = Self.preferredTimelineTrackID(in: project)
        }
        announce("\(asset.name) deleted from the project")
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

    func updateClipDraft(_ selection: EditorSelection, segments: [SourceSegment], audio: AudioClipSettings?, filters: [ClipFilter]) throws {
        for filter in filters { try filter.validate() }
        try mutateProjectThrowing(actionName: "Update Clip") { project in
            let id: UUID
            switch selection {
            case .timelineClip(let clipID):
                id = clipID
                try project.updateTrackClip(id: id, segments: segments)
            case .cutaway(let clipID):
                id = clipID
                try project.updateCutaway(id: id, segments: segments)
            default: throw ProjectTimelineError.clipNotFound
            }
            for trackIndex in project.tracks.indices {
                guard let index = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else { continue }
                project.tracks[trackIndex].clips[index].filters = filters
                if let audio { project.tracks[trackIndex].clips[index].audioSettings = audio }
            }
            project.synchronizeTracksToLegacyTimeline()
        }
        announce("Clip updated")
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
        segments: [SourceSegment]? = nil,
        audioSettings: AudioClipSettings? = nil, filters: [ClipFilter]? = nil,
        announcesConfirmation: Bool = true
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
            if let selectedID { try project.setClipEffects(id: selectedID, audio: audioSettings, filters: filters) }
        }
        guard let selectedID else { throw ProjectTimelineError.unsupportedPlacement }
        selection = placement.isCutaway ? .cutaway(selectedID) : .timelineClip(selectedID)
        advanceAfterInsertion(placement, clipID: selectedID)
        if announcesConfirmation { announce(placement.confirmation) }
        return selectedID
    }

    @discardableResult
    func placeThrowing(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]?,
        onTrack trackID: UUID,
        audioSettings: AudioClipSettings? = nil, filters: [ClipFilter]? = nil,
        announcesConfirmation: Bool = true
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
            if let selectedID { try project.setClipEffects(id: selectedID, audio: audioSettings, filters: filters) }
        }
        guard let selectedID else { throw ProjectTimelineError.unsupportedPlacement }
        activeTimelineTrackID = trackID
        selection = .timelineClip(selectedID)
        advanceAfterInsertion(placement, clipID: selectedID)
        if announcesConfirmation { announce(placement.confirmation) }
        return selectedID
    }

    @discardableResult
    func createTrackAndPlaceThrowing(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment],
        trackKind: TimelineTrackKind,
        trackName requestedTrackName: String,
        audioSettings: AudioClipSettings?,
        filters: [ClipFilter] = []
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
            try project.setClipEffects(id: clipID, audio: nil, filters: filters)
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
            return project.asset(id: id).map { asset in
                [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: asset.duration))]
            }
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
                try mutateProjectThrowing(actionName: "Remove from Timeline") { try $0.removeTrackClip(id: id) }
                selection = .project
                announce("Timeline clip removed")
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
        if movingTimelineClipID != nil || canNudgeTimelineClip(id: clip.id) {
            moveFocusedTimelineClip(id: clip.id, by: offset)
        } else {
            moveTimelineClip(id: clip.id, by: offset)
        }
    }

    func moveSelectedClipToBeginning() {
        guard let clip = selectedTimelineClip else { return }
        moveTimelineClip(id: clip.id, to: .start, targetID: clip.id)
    }

    func moveSelectedClipToEnd() {
        guard let clip = selectedTimelineClip else { return }
        moveTimelineClip(id: clip.id, to: .end, targetID: clip.id)
    }

    func createMarker(at time: ProjectTime) {
        guard time >= .zero, time <= project.duration else { return }
        var created: TimelineMarker?
        mutateProject(actionName: "Add Marker") { created = $0.insertMarker(at: time) }
        activeTimelineTrackID = project.markerTrack?.id
        selectedMarkerID = created?.id
        projectPlayer?.selectEditPointTrack(activeTimelineTrackID, in: project)
        InterfaceSounds.shared.markerCreated()
    }

    func editMarker(_ id: UUID) {
        guard let marker = project.markerTrack?.markers.first(where: { $0.id == id }) else { return }
        projectPlayer?.player.pause()
        editingMarker = marker
    }

    private var markerAtPlayhead: TimelineMarker? {
        guard activeTimelineTrack?.kind == .markers, let player = projectPlayer else { return nil }
        let time = player.precisePlayhead
        return activeTimelineTrack?.sortedMarkers.last { abs($0.time.seconds - time.seconds) < 0.5 / max(project.format.frameRate ?? 30, 1) }
    }

    func editMarkerAtPlayhead() -> Bool {
        guard let marker = markerAtPlayhead else { return false }
        editMarker(marker.id)
        return true
    }

    func deleteMarkerAtPlayhead() -> Bool {
        guard let marker = markerAtPlayhead else { return false }
        deleteMarker(marker.id)
        return true
    }

    func saveMarker(_ marker: TimelineMarker) {
        mutateProject(actionName: "Edit Marker") { project in
            guard let track = project.tracks.firstIndex(where: { $0.kind == .markers }),
                  let index = project.tracks[track].markers.firstIndex(where: { $0.id == marker.id }) else { return }
            project.tracks[track].markers[index] = marker
        }
        editingMarker = nil
    }

    func deleteMarker(_ id: UUID) {
        mutateProject(actionName: "Delete Marker") { project in
            for index in project.tracks.indices { project.tracks[index].markers.removeAll { $0.id == id } }
        }
        if selectedMarkerID == id { selectedMarkerID = nil }
    }

    func setCaptionsVisible(_ visible: Bool) {
        mutateProject(actionName: "Show Captions") { project in
            guard let index = project.tracks.firstIndex(where: { $0.kind == .captions && $0.recordingPurpose != .descriptionTranscript }) else { return }
            project.tracks[index].isMuted = !visible
        }
    }

    private func mutateProject(actionName: String, _ mutation: (inout TrimatoProject) -> Void) {
        mixerAdjustmentEditing(false)
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
        mixerAdjustmentEditing(false)
        guard project != previous else { return }
        if movingTimelineClipID != nil { clearClipMovement() }
        var located = project
        for index in located.media.indices {
            guard let location = mediaLocationOverrides[located.media[index].id] else { continue }
            located.media[index].originalPath = location.originalPath
            located.media[index].bookmarkData = location.bookmarkData
            located.media[index].projectRelativePath = location.projectRelativePath
            located.media[index].recordingRelativePath = location.recordingRelativePath
        }
        document.project = located
        if project.withoutMarkers != previous.withoutMarkers {
            projectPlayer?.updateMix(project: located)
        }
        projectPlayer?.selectEditPointTrack(activeTimelineTrackID, in: located)
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

    private func announce(_ message: String?, priority: NSAccessibilityPriorityLevel = .medium) {
        guard let message, !message.isEmpty else { return }
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: (application.keyWindow as Any?) ?? application,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: priority.rawValue]
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

extension ProjectController {
    /// Prepare every affected recording before committing a single undoable change.
    func applyVoiceToTrack(_ trackID: UUID, settings: VoiceAdjustment) async throws {
        try settings.validate()
        let snapshot = project
        guard let track = snapshot.track(id: trackID), track.kind == .audio else { throw ProjectTimelineError.clipNotFound }
        let clips = track.clips.filter { snapshot.asset(id: $0.assetID)?.recordingPurpose.isNarration == true }
        guard !clips.isEmpty else { throw AudioCaptureError.message("This track has no recorded narration.") }
        for clip in clips {
            guard let record = snapshot.asset(id: clip.assetID), let url = resolveURL(for: record) else {
                throw ProjectCompositionError.missingMedia(clip.displayName)
            }
            var audio = clip.audioSettings
            audio.voice = settings
            let output = try await ClipFilterRenderer.render(source: url, filters: clip.filters, audio: true,
                duration: record.duration.seconds, segments: clip.segments, audioSettings: audio)
            try? FileManager.default.removeItem(at: output)
            try Task.checkCancellation()
        }
        guard project == snapshot else {
            throw AudioCaptureError.message("The project changed while voice adjustments were being prepared. Try applying them again.")
        }
        try mutateProjectThrowing(actionName: "Adjust Track Voice") {
            try $0.setTrackVoice(trackID, settings: settings)
        }
    }
}


extension ProjectController {
    func setTrackMix(_ id: UUID, settings: TrackMixSettings) {
        mutateMixer(actionName: "Adjust Track Mix") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == id && $0.kind == .audio }) else { return }
            project.tracks[index].mix = settings.normalized
        }
    }

    func setMixerTrackMuted(_ id: UUID, muted: Bool) {
        mutateMixer(actionName: muted ? "Mute Track" : "Unmute Track") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == id && $0.kind == .audio }) else { return }
            project.tracks[index].isMuted = muted
        }
    }

    func setMasterVolume(_ value: Double) {
        mutateMixer(actionName: "Adjust Master Volume") {
            $0.masterVolumeDB = TrackMixSettings.bounded(value, -60...12, fallback: 0)
        }
    }

    func resetTrackMix(_ id: UUID) {
        mutateMixer(actionName: "Reset Track Mix") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == id && $0.kind == .audio }) else { return }
            project.tracks[index].mix = .neutral
            project.tracks[index].isMuted = false
        }
    }
}


extension ProjectController {
    func mixerSliderEditingChanged(_ editing: Bool) {
        if editing { mixerAdjustmentEditing(true) }
        else {
            mixerAdjustmentIsDragging = false
            if hasPendingMixerAdjustment { scheduleMixerAdjustmentCompletion() }
        }
    }

    func mixerAdjustmentEditing(_ editing: Bool) {
        mixerAdjustmentIsDragging = editing
        if editing {
            if mixerAdjustmentOrigin == nil {
                mixerAdjustmentOrigin = project
                mixerAdjustmentName = "Adjust Mix"
            }
        } else {
            mixerAdjustmentTask?.cancel()
            mixerAdjustmentTask = nil
            if let before = mixerAdjustmentOrigin {
                mixerAdjustmentOrigin = nil
                registerMixerUndo(before: before, after: project, actionName: mixerAdjustmentName)
            }
            document.flushLiveMixNotification()
        }
    }

    private func scheduleMixerAdjustmentCompletion() {
        mixerAdjustmentRevision &+= 1
        guard mixerAdjustmentTask == nil else { return }
        mixerAdjustmentTask = Task { @MainActor [weak self] in
            while let revision = self?.mixerAdjustmentRevision {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self else { return }
                guard revision == self.mixerAdjustmentRevision else { continue }
                self.mixerAdjustmentTask = nil
                if self.mixerAdjustmentIsDragging { self.document.flushLiveMixNotification() }
                else { self.mixerAdjustmentEditing(false) }
                return
            }
        }
    }

    private func mutateMixer(actionName: String, _ mutation: (inout TrimatoProject) -> Void) {
        guard projectSaveCoordinator?.isResolvingClose != true else { return }
        let before = project
        var after = before
        mutation(&after)
        guard after != before else { return }
        if mixerAdjustmentOrigin == nil {
            mixerAdjustmentOrigin = before
            mixerAdjustmentName = actionName
        }
        document.updateLiveMix(after)
        projectPlayer?.updateMix(project: after)
        scheduleMixerAdjustmentCompletion()
    }
    private func registerMixerUndo(before: TrimatoProject, after: TrimatoProject, actionName: String) {
        guard before != after, let undoManager = projectUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.apply(before, undoingTo: after, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }
}


extension ProjectController {
    var mixerUndoManager: UndoManager? { projectUndoManager }
}
