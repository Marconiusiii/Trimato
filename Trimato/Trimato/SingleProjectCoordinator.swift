import AppKit
import Combine

/// Shared by native panel filtering and the final project-opening boundary.
/// Checking the package identity here does not replace document-content validation.
nonisolated enum ProjectOpenSelection {
    enum Kind { case project, folder, other }

    static func kind(of url: URL) -> Kind {
        guard url.isFileURL else { return .other }
        var target = url.resolvingSymlinksInPath()
        guard var values = try? target.resourceValues(forKeys: [.isAliasFileKey, .isDirectoryKey, .isPackageKey]) else {
            return .other
        }
        if values.isAliasFile == true {
            guard let resolved = try? URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting]),
                  let resolvedValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
                return .other
            }
            target = resolved
            values = resolvedValues
        }
        guard values.isDirectory == true else { return .other }
        if target.pathExtension.caseInsensitiveCompare("trimato") == .orderedSame { return .project }
        return values.isPackage == true ? .other : .folder
    }
}

/// Retained independently of the panel's weak delegate.
@MainActor
final class ProjectOpenPanel: NSObject, NSOpenSavePanelDelegate {
    static let shared = ProjectOpenPanel()

    static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open Trimato Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.trimatoProject]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.delegate = shared
        return panel
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        ProjectOpenSelection.kind(of: url) != .other
    }
}

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
        guard ProjectOpenSelection.kind(of: url) == .project else {
            presentedError = ApplicationMessageDescriptor(
                title: "Project Could Not Be Opened",
                message: "Select a Trimato project (.trimato). To open an audio or video file, use Trim a Clip or import it into a project."
            )
            completion()
            return
        }
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
        let panel = ProjectOpenPanel.make()
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
