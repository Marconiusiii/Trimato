import AppKit
import Combine

/// All project entry points finish closing the current project before opening another.
@MainActor
final class SingleProjectCoordinator: ObservableObject {
    static let shared = SingleProjectCoordinator()
    @Published private(set) var recentURLs: [URL] = []
    @Published private(set) var presentedError: ApplicationMessageDescriptor?
    private var opening = false
    private static let replacement = ProjectReplacementGate()

    static func prepareForReplacement(completion: @escaping (Bool) -> Void) {
        replacement.prepare(
            project: ExternalMediaOpenCoordinator.shared.activeProjectController,
            hasOpenDocuments: !NSDocumentController.shared.documents.isEmpty,
            completion: completion
        )
    }

    func refreshRecentProjects() {
        recentURLs = ProjectLauncherRecentProjects.available(from: NSDocumentController.shared.recentDocumentURLs)
    }

    func dismissError() { presentedError = nil }

    func openDocument(at url: URL, completion: @escaping () -> Void = {}) {
        let documents = NSDocumentController.shared
        if let existing = documents.document(for: url) {
            existing.showWindows()
            completion()
            return
        }
        guard !opening else { return }
        opening = true
        Self.prepareForReplacement { [weak self] allowed in
            guard let self else { return }
            guard allowed else { self.opening = false; completion(); return }
            documents.openDocument(withContentsOf: url, display: true) { _, _, error in
                MainActor.assumeIsolated {
                    self.opening = false
                    self.refreshRecentProjects()
                    if let error, (error as NSError).code != NSUserCancelledError {
                        self.presentedError = ApplicationMessageDescriptor(title: "Project Could Not Be Opened", message: error.localizedDescription)
                    }
                    completion()
                }
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Trimato Project"
        panel.allowedContentTypes = [.trimatoProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openDocument(at: url)
        }
    }
}


@MainActor
final class ProjectReplacementGate {
    private var closing = false

    func prepare(project: ProjectController?, hasOpenDocuments: Bool, completion: @escaping (Bool) -> Void) {
        guard !closing else { completion(false); return }
        guard let project else { completion(!hasOpenDocuments); return }
        closing = true
        project.closeProject { [weak self] closed in
            self?.closing = false
            completion(closed)
        }
    }
}
