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
    @Published var isImporting = false
    @Published var presentedError: ProjectPresentedError?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double?

    private var cancellables: Set<AnyCancellable> = []
    private var accessedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?
    private let cacheOwnerID = UUID()

    init(document: ProjectDocument) {
        self.document = document
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateCacheProtection(for: document.project)
    }

    deinit {
        exportTask?.cancel()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        let cacheOwnerID = cacheOwnerID
        Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: cacheOwnerID) }
    }

    func resolvedMediaURLs() -> [UUID: URL] {
        var result: [UUID: URL] = [:]
        let usedIDs = Set(project.primaryTimeline.map(\.assetID) + project.cutaways.map(\.assetID))
        for id in usedIDs {
            guard let asset = project.asset(id: id), let url = resolveURL(for: asset) else { continue }
            result[id] = url
        }
        return result
    }

    func relinkSelectedAsset() {
        guard let asset = selectedAsset, NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink \(asset.name)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .data]
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
        guard !isExporting, !project.primaryTimeline.isEmpty, NSApp.modalWindow == nil else { return }
        let urls = resolvedMediaURLs()
        let requiredIDs = Set(project.primaryTimeline.map(\.assetID) + project.cutaways.map(\.assetID))
        guard requiredIDs.allSatisfy({ urls[$0] != nil }) else {
            presentedError = ProjectPresentedError(
                title: "Media Is Offline",
                message: "Relink offline media before exporting the project."
            )
            announce("Relink offline media before exporting")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Project"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        exportProgress = 0
        announce("Export started")
        let projectSnapshot = project
        exportTask = Task { @MainActor in
            do {
                try await ProjectExporter.export(
                    project: projectSnapshot,
                    mediaURLs: urls,
                    to: outputURL
                ) { [weak self] progress in
                    self?.exportProgress = progress
                }
                isExporting = false
                exportProgress = nil
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
            return project.primaryTimeline.first(where: { $0.id == id }).flatMap { project.asset(id: $0.assetID) }
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id }).flatMap { project.asset(id: $0.assetID) }
        case .project: return nil
        }
    }

    var selectedTimelineClip: TimelineClip? {
        guard case .timelineClip(let id) = selection else { return nil }
        return project.primaryTimeline.first { $0.id == id }
    }

    var selectedCutaway: TimelineCutaway? {
        guard case .cutaway(let id) = selection else { return nil }
        return project.cutaways.first { $0.id == id }
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
                hasAudio: asset.hasAudio
            )
        case .nativeMP4Export:
            return .native(
                url: originalURL,
                asset: originalAsset,
                contentType: contentType,
                mode: .nativePlaybackMP4Export,
                hasAudio: asset.hasAudio
            )
        case .cachedProxy:
            guard let cacheKey = asset.proxyCacheKey,
                  let fingerprint = asset.sourceFingerprint else { return nil }
            let proxyURL = try await MediaCacheManager.shared.ensureProxy(
                sourceURL: originalURL,
                duration: asset.duration.seconds,
                cacheKey: cacheKey,
                fingerprint: fingerprint
            )
            return MediaSource(
                originalURL: originalURL,
                playbackURL: proxyURL,
                originalAsset: originalAsset,
                playbackAsset: AVURLAsset(url: proxyURL),
                contentType: contentType,
                mode: .proxyPlaybackMP4Export,
                frameTimestamps: [],
                hasAudio: asset.hasAudio
            )
        }
    }

    func importFiles(into folderID: UUID? = nil) {
        guard !isImporting, NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Video Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .data]
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
            project.format = format
            project.targetDuration = targetDuration
        }
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
                try $0.updateTimelineClip(id: id, segments: segments)
            }
            announce("Timeline clip updated")
        case .cutaway(let id):
            try mutateProjectThrowing(actionName: "Update Cutaway") {
                try $0.updateCutaway(id: id, segments: segments)
            }
            announce("Cutaway updated")
        case .asset, .project:
            return
        }
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

    func asset(for editSelection: EditorSelection) -> MediaAssetRecord? {
        switch editSelection {
        case .asset(let id):
            return project.asset(id: id)
        case .timelineClip(let id):
            return project.primaryTimeline.first(where: { $0.id == id })
                .flatMap { project.asset(id: $0.assetID) }
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id })
                .flatMap { project.asset(id: $0.assetID) }
        case .project:
            return nil
        }
    }

    func segments(for editSelection: EditorSelection) -> [SourceSegment]? {
        switch editSelection {
        case .asset(let id):
            return project.asset(id: id)?.sourceEdit
        case .timelineClip(let id):
            return project.primaryTimeline.first(where: { $0.id == id })?.segments
        case .cutaway(let id):
            return project.cutaways.first(where: { $0.id == id })?.segments
        case .project:
            return nil
        }
    }

    func splitSelectedClip() {
        guard let clip = selectedTimelineClip else { return }
        do {
            var rightID: UUID?
            try mutateProjectThrowing(actionName: "Split Clip") { project in
                rightID = try project.splitClip(id: clip.id, atTimelineTime: timelinePlayhead)
            }
            if let rightID { selection = .timelineClip(rightID) }
            announce("Clip split")
        } catch {
            announce(error.localizedDescription)
        }
    }

    func deleteSelection() {
        switch selection {
        case .timelineClip(let id):
            do {
                try mutateProjectThrowing(actionName: "Delete Timeline Clip") { try $0.removeClip(id: id) }
                selection = .project
                announce("Timeline clip deleted")
            } catch { announce(error.localizedDescription) }
        case .cutaway(let id):
            mutateProject(actionName: "Delete Cutaway") { $0.cutaways.removeAll { $0.id == id } }
            selection = .project
            announce("Cutaway removed")
        default:
            break
        }
    }

    func moveSelectedClip(by offset: Int) {
        guard let clip = selectedTimelineClip,
              let current = project.primaryTimeline.firstIndex(where: { $0.id == clip.id }) else { return }
        do {
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveClip(id: clip.id, to: current + offset)
            }
            announce("Clip moved")
        } catch { announce(error.localizedDescription) }
    }

    func moveSelectedClipToBeginning() {
        moveSelectedClip(to: 0)
    }

    func moveSelectedClipToEnd() {
        moveSelectedClip(to: max(project.primaryTimeline.count - 1, 0))
    }

    private func moveSelectedClip(to destination: Int) {
        guard let clip = selectedTimelineClip else { return }
        do {
            try mutateProjectThrowing(actionName: "Move Timeline Clip") {
                try $0.moveClip(id: clip.id, to: destination)
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
        var updated = document.project
        guard let index = updated.media.firstIndex(where: { $0.id == asset.id }) else { return }
        updated.media[index].playbackMode = asset.playbackMode
        updated.media[index].proxyCacheKey = asset.proxyCacheKey
        updated.media[index].sourceFingerprint = asset.sourceFingerprint
        document.project = updated
        updateCacheProtection(for: updated)
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
