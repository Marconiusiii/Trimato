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
    @Published var transitionRequest: TransitionRequest?
    @Published private(set) var transitionRequestReturnsToEditor = false
    @Published private(set) var editorFocusRestoreRequest = 0
    @Published var isImporting = false
    @Published var isShowingProjectSettings = false
    @Published var presentedError: ProjectPresentedError?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double?
    @Published private(set) var isPresentingExportPanel = false

    private var cancellables: Set<AnyCancellable> = []
    private var accessedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?
    private weak var projectSaveCoordinator: ProjectWindowSaveCoordinator?
    private weak var projectPlayer: ProjectPlayerViewModel?
    private var closeProjectAction: (() -> Void)?
    private let cacheOwnerID = UUID()

    init(document: ProjectDocument) {
        self.document = document
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateCacheProtection(for: document.project)
        activeTimelineTrackID = document.project.tracks.first?.id
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

    func focusTimelineElement(_ element: TimelineElementSelection) {
        switch element {
        case .clip(let id): selection = .timelineClip(id)
        case .transition(let id): selection = .transition(id)
        }
    }

    func selectAdjacentTrack(_ offset: Int) {
        guard !project.tracks.isEmpty else { return }
        let current = activeTimelineTrackID.flatMap { id in project.tracks.firstIndex { $0.id == id } } ?? 0
        let destination = min(max(current + offset, 0), project.tracks.count - 1)
        activeTimelineTrackID = project.tracks[destination].id
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
            self.activeTimelineTrackID = project.tracks.first?.id
            selection = .project
        } catch { announce(error.localizedDescription) }
    }

    func addTransition(_ transition: TimelineTransition) throws {
        try mutateProjectThrowing(actionName: "Add Transition") { try $0.addTransition(transition) }
        selection = .transition(transition.id)
    }

    func addTransitions(_ additions: [TimelineTransition], selectAddedTransition: Bool = true) throws {
        guard !additions.isEmpty else { return }
        try mutateProjectThrowing(actionName: additions.count == 1 ? "Add Transition" : "Add Transitions") { project in
            for transition in additions { try project.addTransition(transition) }
        }
        if selectAddedTransition {
            selection = .transition(additions[0].id)
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
        panel.title = "Import Media Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .data]
        guard panel.runModal() == .OK else { return }

        importFiles(at: panel.urls, into: folderID)
    }

    func importFiles(at urls: [URL], into folderID: UUID? = nil) {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true
        Task { @MainActor in
            var imported: [MediaAssetRecord] = []
            var failures: [(name: String, message: String)] = []
            var importPaths = Set(project.media.map(\.originalPath))
            let newURLs = urls.filter { importPaths.insert($0.path).inserted }
            for url in newURLs {
                do {
                    imported.append(try await ProjectImportCoordinator.importAsset(at: url))
                } catch {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            let additions = imported
            if !additions.isEmpty {
                mutateProject(actionName: "Import Media") { project in
                    project.media.append(contentsOf: additions)
                    if let folderID,
                       let folderIndex = project.folders.firstIndex(where: { $0.id == folderID }) {
                        project.folders[folderIndex].assetIDs.append(contentsOf: additions.map(\.id))
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
                    title: failures.count == newURLs.count ? "Import Failed" : "Some Clips Could Not Be Imported",
                    message: details
                )
                announce(failures.count == newURLs.count ? "Import failed" : "Some clips could not be imported")
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

    func place(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]? = nil
    ) {
        guard let asset = asset(for: editSelection) else { return }
        do {
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
            if let selectedID {
                selection = placement.isCutaway ? .cutaway(selectedID) : .timelineClip(selectedID)
            }
            announce(placement.confirmation)
        } catch {
            announce(error.localizedDescription)
        }
    }

    func place(
        _ placement: PlacementAction,
        editing editSelection: EditorSelection,
        segments: [SourceSegment]?,
        onTrack trackID: UUID
    ) {
        guard let asset = asset(for: editSelection) else { return }
        do {
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
                    return
                }
            }
            if let selectedID {
                activeTimelineTrackID = trackID
                selection = .timelineClip(selectedID)
            }
            announce(placement.confirmation)
        } catch { announce(error.localizedDescription) }
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
        guard let clip = selectedTimelineClip,
              let track = project.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }),
              let current = track.sortedClips.firstIndex(where: { $0.id == clip.id }) else { return }
        do {
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveTrackClip(id: clip.id, to: current + offset)
            }
            announce("Clip moved")
        } catch { announce(error.localizedDescription) }
    }

    func moveSelectedClipToBeginning() {
        moveSelectedClip(to: 0)
    }

    func moveSelectedClipToEnd() {
        guard let clip = selectedTimelineClip,
              let track = project.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else { return }
        moveSelectedClip(to: max(track.clips.count - 1, 0))
    }

    private func moveSelectedClip(to destination: Int) {
        guard let clip = selectedTimelineClip else { return }
        do {
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveTrackClip(id: clip.id, to: destination)
            }
            announce("Clip moved")
        } catch { announce(error.localizedDescription) }
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
        document.project = project
        updateCacheProtection(for: project)
        if let undoManager = NSApp.keyWindow?.undoManager {
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
