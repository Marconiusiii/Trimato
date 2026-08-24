import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ExternalMediaOpenRoute: Equatable, Sendable {
    case ignore
    case standaloneEditor
    case activeProject
}

@MainActor
final class ExternalMediaOpenCoordinator {
    static let shared = ExternalMediaOpenCoordinator()

    private struct ProjectRegistration {
        weak var controller: ProjectController?
        var openClipEditor: (EditorSelection) -> Void
    }

    private var registrations: [ObjectIdentifier: ProjectRegistration] = [:]

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
        removeExpiredRegistrations()
    }

    func unregister(controller: ProjectController) {
        registrations[ObjectIdentifier(controller)] = nil
    }

    func handle(
        _ url: URL,
        activeProject: ProjectController?,
        openStandalone: @escaping (URL) -> Void
    ) {
        switch Self.route(for: url, hasActiveProject: activeProject != nil) {
        case .ignore:
            return
        case .standaloneEditor:
            openStandalone(url)
        case .activeProject:
            guard let activeProject,
                  let registration = registrations[ObjectIdentifier(activeProject)],
                  registration.controller != nil else {
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
    }
}

struct ExternalMediaOpenHandler: ViewModifier {
    @FocusedObject private var activeProject: ProjectController?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            ExternalMediaOpenCoordinator.shared.handle(
                url,
                activeProject: activeProject,
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
