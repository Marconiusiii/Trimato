import AppKit
import Combine
import Foundation
import SwiftUI

nonisolated enum MediaFileAccess {
    static func resolve(_ asset: MediaAssetRecord, folder: URL?, folderBookmark: Data? = nil) -> URL? {
        MediaFileReference(originalPath: asset.originalPath, bookmarkData: asset.bookmarkData,
                           projectRelativePath: asset.projectRelativePath ?? asset.recordingRelativePath)
            .resolve(folder: folder, folderBookmark: folderBookmark)
    }

    static func requiredEnd(for id: UUID, in project: TrimatoProject) -> ProjectTime {
        let source = project.asset(id: id)?.sourceEdit.map(\.sourceRange.end) ?? []
        let timeline = project.tracks.flatMap(\.clips).filter { $0.assetID == id }
            .flatMap { $0.segments.map(\.sourceRange.end) }
        let cutaways = project.cutaways.filter { $0.assetID == id }.flatMap { $0.segments.map(\.sourceRange.end) }
        let primary = project.primaryTimeline.filter { $0.assetID == id }.flatMap { $0.segments.map(\.sourceRange.end) }
        return (source + timeline + cutaways + primary).max() ?? .zero
    }
}

@MainActor
final class ProjectMediaFiles: ObservableObject {
    enum Prompt: String, Identifiable { case consolidate, imported, missing; var id: Self { self } }
    @Published private(set) var missingIDs: Set<UUID> = []
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double?
    @Published private(set) var detail: String?
    private var committedTransfer = false
    @Published private(set) var operationTitle = "Organizing Media"
    @Published var prompt: Prompt?
    @Published var resultMessage: ApplicationMessageDescriptor?
    @Published private(set) var outcome = OperationProgressOutcome.completed
    @Published private(set) var missingNames: [String] = []
    private weak var controller: ProjectController?
    private var subscriptions: Set<AnyCancellable> = []
    private var scan: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var pendingRelink: UUID?
    private var pendingImportDecision: ImportedFileHandling?
    private var hasImportDecision = false
    private var importChoice: CheckedContinuation<ImportedFileHandling?, Never>?

    func connect(_ controller: ProjectController) {
        self.controller = controller
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        controller.document.objectWillChange.debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func refresh() {
        guard scan == nil, let controller else { return }
        let media = controller.project.media
        let folder = controller.projectSaveCoordinator?.projectURL?.deletingLastPathComponent()
        let folderBookmark = controller.project.recordingsFolderBookmark
        scan = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(media.filter { $0.generator == nil && MediaFileAccess.resolve($0, folder: folder, folderBookmark: folderBookmark) == nil }.map(\.id))
            }.value
            guard let self else { return }
            scan = nil
            guard controller.project.media == media,
                  controller.projectSaveCoordinator?.projectURL?.deletingLastPathComponent() == folder else {
                refresh()
                return
            }
            if missingIDs != missing { missingIDs = missing }
        }
    }

    func chooseImport(_ choice: ImportedFileHandling?) {
        guard importChoice != nil, !hasImportDecision else { return }
        pendingImportDecision = choice
        hasImportDecision = true
        prompt = nil
    }

    func dismissPrompt() {
        if prompt == .imported { chooseImport(nil) }
        else if !isBusy { prompt = nil }
    }

    func importHandling() async -> ImportedFileHandling? {
        let choice = ImportedFileHandling.preference()
        guard choice == .ask else { return choice }
        hasImportDecision = false
        return await withCheckedContinuation { continuation in
            importChoice = continuation
            prompt = .imported
        }
    }

    var missingAssets: [MediaAssetRecord] {
        controller?.project.media.filter { missingIDs.contains($0.id) && $0.generator == nil } ?? []
    }

    func requestRelink(_ id: UUID) {
        pendingRelink = id
        prompt = nil
    }

    func promptDismissed() {
        if let completion = importChoice, hasImportDecision {
            importChoice = nil
            hasImportDecision = false
            let decision = pendingImportDecision
            pendingImportDecision = nil
            completion.resume(returning: decision)
        }
        guard let id = pendingRelink, let controller else { return }
        pendingRelink = nil
        controller.selection = .asset(id)
        controller.relinkSelectedAsset()
    }

    func showConsolidation() {
        guard !isBusy, prompt == nil, let controller, !controller.isImporting, !controller.isExporting, !controller.isRelinkingMedia else { return }
        outcome = .completed
        operationTitle = "Checking Media"
        resultMessage = nil
        prompt = .consolidate
        isBusy = true
        progress = nil
        operation = Task { [weak self] in
            guard let self else { return }
            let media = controller.project.media.filter { $0.generator == nil }
            let folder = controller.projectSaveCoordinator?.projectURL?.deletingLastPathComponent()
            let folderBookmark = controller.project.recordingsFolderBookmark
            let unavailable = await Task.detached(priority: .utility) {
                media.filter { MediaFileAccess.resolve($0, folder: folder, folderBookmark: folderBookmark) == nil }
            }.value
            isBusy = false
            operation = nil
            guard !Task.isCancelled else { prompt = nil; return }
            missingIDs = Set(unavailable.map(\.id))
            missingNames = unavailable.map(\.name)
        }
    }

    func consolidate(move: Bool) {
        guard !isBusy, operation == nil else { return }
        operation = Task { [weak self] in
            guard let self, let controller else { return }
            defer { operation = nil }
            do {
                try await transfer(ids: Set(controller.project.media.filter { $0.generator == nil }.map(\.id)), move: move)
                resultMessage = .init(title: "Consolidation Complete",
                    message: move ? "The project now uses media in its Clips folder. The transferred originals have been removed."
                                  : "The project now uses media in its Clips folder. The originals have been kept.")
            }
            catch is CancellationError {
                outcome = .cancelled
                if committedTransfer {
                    resultMessage = .init(title: "Consolidation Cancelled", message: "The project uses verified copies in its Clips folder. Original files that were not yet removed have been kept.")
                } else { prompt = nil }
            }
            catch {
                outcome = .failed
                resultMessage = .init(title: "Consolidation Failed", message: error.localizedDescription)
            }
        }
    }

    func cancel() { outcome = .cancelled; operation?.cancel() }

    func transfer(ids: Set<UUID>, move: Bool) async throws {
        guard !isBusy, let controller else { throw CancellationError() }
        committedTransfer = false
        detail = nil
        operationTitle = "Organizing Media"
        isBusy = true
        progress = 0
        defer { isBusy = false; progress = nil; detail = nil; refresh() }
        guard controller.projectSaveCoordinator?.projectURL != nil else {
            throw QuitDraftError(message: "Save the project before moving or consolidating its media.")
        }
        let folder = try await controller.projectMediaDirectory(named: "Clips")
        let media = controller.project.media.filter { ids.contains($0.id) && $0.generator == nil }
        let root = folder.deletingLastPathComponent()
        let sources = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: media.compactMap { asset in
                MediaFileAccess.resolve(asset, folder: root).map { (asset.id, $0) }
            })
        }.value
        let unavailable = media.filter { sources[$0.id] == nil }
        guard unavailable.isEmpty else {
            missingIDs.formUnion(unavailable.map(\.id))
            missingNames = unavailable.map(\.name)
            throw QuitDraftError(message: "Relink these sources before consolidating:\n" + missingNames.joined(separator: "\n"))
        }
        var scopes: [URL] = []
        for url in sources.values where url.startAccessingSecurityScopedResource() { scopes.append(url) }
        defer { for url in scopes { url.stopAccessingSecurityScopedResource() } }
        let result = try await MediaFileTransfer.prepare(sources, in: folder) { [self] value in
            Task { @MainActor in
                guard self.isBusy, self.operationTitle == "Organizing Media" else { return }
                self.progress = value.fraction
                self.detail = value.detail
            }
        }
        // Once references are committed, retain verified copies even if saving fails.
        // Originals are never deleted until the updated project has been saved.
        guard let saveCoordinator = controller.projectSaveCoordinator else {
            throw QuitDraftError(message: "The project is no longer available. Originals have been kept.")
        }
        for asset in media {
            guard let current = controller.project.asset(id: asset.id),
                  current.originalPath == asset.originalPath,
                  current.bookmarkData == asset.bookmarkData else {
                for url in result.created { await RecordingFileStorage.remove(url) }
                throw QuitDraftError(message: "The project sources changed during consolidation. Run Consolidate Clips again.")
            }
        }
        if Task.isCancelled {
            for url in result.created { await RecordingFileStorage.remove(url) }
            throw CancellationError()
        }
        controller.installMediaLocations(result.destinations, projectFolder: root)
        operationTitle = "Saving Project"
        detail = nil
        progress = nil
        let saved = await withCheckedContinuation { continuation in
            saveCoordinator.save { continuation.resume(returning: $0) }
        }
        guard saved else {
            throw QuitDraftError(message: "The media was copied, but the project could not be saved. All originals have been kept. Save the project before removing any originals.")
        }
        committedTransfer = true
        try Task.checkCancellation()
        if move {
            operationTitle = "Removing Originals"
            let failures = await MediaFileTransfer.removeOriginals(result)
            try Task.checkCancellation()
            if !failures.isEmpty {
                throw QuitDraftError(message: "The project now uses the verified copies. Some originals could not be removed:\n" + failures.joined(separator: "\n"))
            }
        }
    }
}

struct ProjectMediaFilesPrompt: View {
    @ObservedObject var model: ProjectMediaFiles
    let kind: ProjectMediaFiles.Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .imported ? "Imported files" : "Consolidate Clips")
                .font(.headline).accessibilityAddTraits(.isHeader)
            if kind == .imported {
                Text("Keep these files where they are, or move them into this project's Clips folder?")
                HStack {
                    Button("Keep in Place") { model.chooseImport(.keep) }
                    Button("Move to Project") { model.chooseImport(.move) }
                    Button("Cancel") { model.chooseImport(nil) }.keyboardShortcut(.cancelAction)
                }
            } else {
                if model.isBusy {
                    Text(model.outcome == .cancelled ? "Cancelling…" : model.operationTitle)
                    if let detail = model.detail { Text(detail) }
                    ProgressView(value: model.progress)
                } else if let result = model.resultMessage {
                    Text(result.title).font(.headline).accessibilityAddTraits(.isHeader)
                    ScrollView {
                        Text(result.message).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(CGFloat(result.message.count / 60 + 2) * 22, 240))
                } else if !model.missingAssets.isEmpty {
                    Text("Relink these sources, then run Consolidate Clips again.")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.missingAssets) { asset in
                                Button("Relink \(asset.name)…") { model.requestRelink(asset.id) }
                                    .help("Last location: \(asset.originalPath)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(CGFloat(model.missingAssets.count) * 36, 240))
                } else {
                    Text("Bring this project's source media into its Clips folder.")
                    Text("Moving removes the originals after the copies are verified and the project is saved.")
                }
                HStack {
                    if !model.isBusy, model.resultMessage == nil, model.missingAssets.isEmpty {
                        Button("Copy Clips") { model.consolidate(move: false) }
                        Button("Move Clips") { model.consolidate(move: true) }
                    }
                    Button(model.isBusy ? "Cancel" : "Close") {
                        if model.isBusy { model.cancel() } else { model.prompt = nil }
                    }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20).frame(width: 480)
        .interactiveDismissDisabled()
    }
}
