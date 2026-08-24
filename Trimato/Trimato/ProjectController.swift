import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum EditorSelection: Hashable {
    case project
    case asset(UUID)
    case timelineClip(UUID)
    case cutaway(UUID)
}

@MainActor
final class ProjectController: ObservableObject {
    let document: ProjectDocument

    @Published var selection: EditorSelection = .project
    @Published var timelinePlayhead = ProjectTime.zero
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double?

    private var cancellables: Set<AnyCancellable> = []
    private var accessedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?

    init(document: ProjectDocument) {
        self.document = document
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    deinit {
        exportTask?.cancel()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
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
                replacement.id = asset.id
                mutateProject(actionName: "Relink Media") { project in
                    guard let index = project.media.firstIndex(where: { $0.id == asset.id }) else { return }
                    replacement.name = project.media[index].name
                    replacement.sourceEdit = project.media[index].sourceEdit
                    project.media[index] = replacement
                }
                statusMessage = "Media relinked"
                announce(statusMessage)
            } catch {
                statusMessage = "Relink failed: \(error.localizedDescription)"
                announce(statusMessage)
            }
        }
    }

    func exportProject() {
        guard !isExporting, !project.primaryTimeline.isEmpty, NSApp.modalWindow == nil else { return }
        let urls = resolvedMediaURLs()
        let requiredIDs = Set(project.primaryTimeline.map(\.assetID) + project.cutaways.map(\.assetID))
        guard requiredIDs.allSatisfy({ urls[$0] != nil }) else {
            statusMessage = "Relink offline media before exporting"
            announce(statusMessage)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Project"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        exportProgress = 0
        statusMessage = "Exporting project"
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
                statusMessage = "Export complete"
                announce(statusMessage)
            } catch is CancellationError {
                isExporting = false
                exportProgress = nil
                statusMessage = "Export canceled"
                announce(statusMessage)
            } catch {
                isExporting = false
                exportProgress = nil
                statusMessage = "Export failed: \(error.localizedDescription)"
                announce(statusMessage)
            }
            exportTask = nil
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportTask?.cancel()
        statusMessage = "Canceling export"
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

    func importFiles() {
        guard !isImporting, NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Video Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .data]
        guard panel.runModal() == .OK else { return }

        importFiles(at: panel.urls)
    }

    func importFiles(at urls: [URL]) {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true
        statusMessage = "Importing media"
        Task { @MainActor in
            var imported: [MediaAssetRecord] = []
            var failureCount = 0
            for url in urls {
                do {
                    imported.append(try await ProjectImportCoordinator.importAsset(at: url))
                } catch {
                    failureCount += 1
                }
            }
            if !imported.isEmpty {
                mutateProject(actionName: "Import Media") { project in
                    var knownPaths = Set(project.media.map(\.originalPath))
                    for asset in imported where knownPaths.insert(asset.originalPath).inserted {
                        project.media.append(asset)
                    }
                }
            }
            isImporting = false
            statusMessage = failureCount == 0
                ? "Imported \(imported.count) file\(imported.count == 1 ? "" : "s")"
                : "Imported \(imported.count) files; \(failureCount) could not be imported"
            announce(statusMessage)
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
        guard project.asset(id: assetID)?.sourceEdit != segments else { return }
        mutateProject(actionName: "Edit Source Clip") { project in
            guard let index = project.media.firstIndex(where: { $0.id == assetID }) else { return }
            project.media[index].sourceEdit = segments
        }
    }

    func updateEditSegments(for selection: EditorSelection, segments: [SourceSegment]) {
        guard !segments.isEmpty else { return }
        switch selection {
        case .asset(let id):
            updateSourceEdit(assetID: id, segments: segments)
        case .timelineClip(let id):
            guard project.primaryTimeline.first(where: { $0.id == id })?.segments != segments else { return }
            mutateProject(actionName: "Edit Timeline Clip") { project in
                guard let index = project.primaryTimeline.firstIndex(where: { $0.id == id }) else { return }
                project.primaryTimeline[index].segments = segments
            }
        case .cutaway(let id):
            guard project.cutaways.first(where: { $0.id == id })?.segments != segments else { return }
            mutateProject(actionName: "Edit Cutaway") { project in
                guard let index = project.cutaways.firstIndex(where: { $0.id == id }) else { return }
                let updatedEnd = project.cutaways[index].start + segments.reduce(.zero) { $0 + $1.duration }
                guard updatedEnd <= project.duration else { return }
                guard !project.cutaways.contains(where: { other in
                    other.id != id && project.cutaways[index].start < other.end && other.start < updatedEnd
                }) else { return }
                project.cutaways[index].segments = segments
            }
        case .project:
            break
        }
    }

    func placeSelectedAsset(_ placement: PlacementAction, segments: [SourceSegment]? = nil) {
        guard let asset = selectedAsset else { return }
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
            statusMessage = error.localizedDescription
            announce(statusMessage)
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
        if let undoManager = NSApp.keyWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.apply(previous, undoingTo: project, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
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

    var undoName: String {
        switch self {
        case .append: "Append Clip"
        case .insert: "Insert Clip"
        case .replaceRemainder: "Replace Clip Remainder"
        case .cutawaySourceAudio: "Add Cutaway with Source Audio"
        case .cutawayPrimaryAudio: "Add Cutaway over Primary Audio"
        }
    }

    var confirmation: String {
        switch self {
        case .append: "Clip appended"
        case .insert: "Clip inserted"
        case .replaceRemainder: "Clip remainder replaced"
        case .cutawaySourceAudio: "Cutaway added with source audio"
        case .cutawayPrimaryAudio: "Cutaway added over primary audio"
        }
    }
}
