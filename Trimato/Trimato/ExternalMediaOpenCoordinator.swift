import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ExternalMediaOpenRequest: Codable, Hashable {
    let id: UUID
    let originalURL: URL
    let bookmarkData: Data?

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        originalURL = url
        bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )
    }

    var displayName: String {
        (try? originalURL.resourceValues(forKeys: [.nameKey]).name)
            ?? originalURL.lastPathComponent
    }

    func resolvedURL() throws -> URL {
        guard let bookmarkData else { return originalURL }
        var stale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

nonisolated enum ExternalMediaOpenRoute: Equatable, Sendable {
    case ignore
    case standaloneEditor
    case activeProject
}

@MainActor
final class ExternalMediaOpenCoordinator: ObservableObject {
    static let shared = ExternalMediaOpenCoordinator()

    @Published private(set) var activeProjectController: ProjectController?

    private struct ProjectRegistration {
        weak var controller: ProjectController?
        var openClipEditor: (EditorSelection) -> Void
    }

    private var registrations: [ObjectIdentifier: ProjectRegistration] = [:]
    private var activationOrder: [ObjectIdentifier] = []
    private var standalonePresenters: [UUID: (URL) -> Void] = [:]
    private var presenterOrder: [UUID] = []
    private var pendingURLs: [URL] = []

    nonisolated static func route(for url: URL, hasActiveProject: Bool) -> ExternalMediaOpenRoute {
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("trimato") != .orderedSame,
              isSupportedMedia(url) else { return .ignore }
        return hasActiveProject ? .activeProject : .standaloneEditor
    }

    func register(
        controller: ProjectController,
        openClipEditor: @escaping (EditorSelection) -> Void
    ) {
        registrations[ObjectIdentifier(controller)] = ProjectRegistration(
            controller: controller,
            openClipEditor: openClipEditor
        )
        if activationOrder.isEmpty { activate(controller: controller) }
        removeExpiredRegistrations()
    }

    func unregister(controller: ProjectController) {
        let identifier = ObjectIdentifier(controller)
        registrations[identifier] = nil
        activationOrder.removeAll { $0 == identifier }
        updateActiveProjectController()
    }

    func activate(controller: ProjectController) {
        let identifier = ObjectIdentifier(controller)
        guard registrations[identifier]?.controller != nil else { return }
        activationOrder.removeAll { $0 == identifier }
        activationOrder.append(identifier)
        updateActiveProjectController()
    }

    @discardableResult
    func registerStandalonePresenter(_ presenter: @escaping (URL) -> Void) -> UUID {
        let identifier = UUID()
        standalonePresenters[identifier] = presenter
        presenterOrder.append(identifier)
        Task { @MainActor [weak self] in
            self?.deliverPendingURLs()
        }
        return identifier
    }

    func unregisterStandalonePresenter(_ identifier: UUID) {
        standalonePresenters[identifier] = nil
        presenterOrder.removeAll { $0 == identifier }
    }

    func receive(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter {
            Self.route(for: $0, hasActiveProject: activeProjectController != nil) != .ignore
        })
        deliverPendingURLs()
    }

    func handle(
        _ url: URL,
        openStandalone: @escaping (URL) -> Void
    ) {
        removeExpiredRegistrations()
        let activeProject = activeProjectController
        switch Self.route(for: url, hasActiveProject: activeProject != nil) {
        case .ignore:
            return
        case .standaloneEditor:
            openStandalone(url)
        case .activeProject:
            guard let activeProject else {
                openStandalone(url)
                return
            }
            activeProject.importExternalFile(at: url) { [weak self, weak activeProject] assetID in
                guard let self, let activeProject,
                      let current = self.registrations[ObjectIdentifier(activeProject)],
                      current.controller != nil else { return }
                current.openClipEditor(.asset(assetID))
            }
        }
    }

    private nonisolated static func isSupportedMedia(_ url: URL) -> Bool {
        let explicitlySupported = ["mkv", "webm", "ts", "mts", "m2ts", "vob", "wmv", "flv"]
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
        if let type = values?.contentType,
           type.conforms(to: .movie) || type.conforms(to: .audio) {
            return true
        }
        let resourceExtension = values?.name.map { ($0 as NSString).pathExtension }
        let pathExtension = resourceExtension.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.pathExtension
        if explicitlySupported.contains(pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }

    private func deliverPendingURLs() {
        removeExpiredRegistrations()
        presenterOrder.removeAll { standalonePresenters[$0] == nil }
        let presenter = presenterOrder.last.flatMap { standalonePresenters[$0] }
        guard activeProjectController != nil || presenter != nil else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            handle(url, openStandalone: presenter ?? { _ in })
        }
    }

    private func removeExpiredRegistrations() {
        registrations = registrations.filter { $0.value.controller != nil }
        activationOrder.removeAll { registrations[$0] == nil }
        updateActiveProjectController()
    }

    private func updateActiveProjectController() {
        let controller = activationOrder.last.flatMap { registrations[$0]?.controller }
        if activeProjectController !== controller {
            activeProjectController = controller
        }
    }
}

struct ExternalMediaOpenHandler: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var presenterID: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard presenterID == nil else { return }
                presenterID = ExternalMediaOpenCoordinator.shared.registerStandalonePresenter { url in
                    openWindow(value: ExternalMediaOpenRequest(url: url))
                }
            }
            .onDisappear {
                guard let presenterID else { return }
                ExternalMediaOpenCoordinator.shared.unregisterStandalonePresenter(presenterID)
                self.presenterID = nil
            }
    }
}

extension View {
    func handlesTrimatoMediaOpening() -> some View {
        modifier(ExternalMediaOpenHandler())
    }
}
