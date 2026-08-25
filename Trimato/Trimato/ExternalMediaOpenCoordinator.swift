import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    nonisolated static func route(for url: URL, hasActiveProject: Bool) -> ExternalMediaOpenRoute {
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("trimato") != .orderedSame,
              isSupportedVideo(url) else { return .ignore }
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

    private nonisolated static func isSupportedVideo(_ url: URL) -> Bool {
        let explicitlySupported = ["mkv", "webm", "ts", "mts", "m2ts", "vob", "wmv", "flv"]
        if explicitlySupported.contains(url.pathExtension.lowercased()) { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
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

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            ExternalMediaOpenCoordinator.shared.handle(
                url,
                openStandalone: { openWindow(value: $0) }
            )
        }
    }
}

extension View {
    func handlesTrimatoMediaOpening() -> some View {
        modifier(ExternalMediaOpenHandler())
    }
}
