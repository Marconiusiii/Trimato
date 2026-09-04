import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectCreationSheetPresenter: NSViewRepresentable {
    let isPresented: Bool
    let projectCreated: (URL) -> Void
    let presentationEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProjectCreationWindowAnchor {
        let view = ProjectCreationWindowAnchor(frame: .zero)
        view.owner = context.coordinator
        context.coordinator.update(from: self, parent: view.window)
        return view
    }

    func updateNSView(_ view: ProjectCreationWindowAnchor, context: Context) {
        view.owner = context.coordinator
        context.coordinator.update(from: self, parent: view.window)
    }

    static func dismantleNSView(_ view: ProjectCreationWindowAnchor, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var source: ProjectCreationSheetPresenter?
        private weak var parentWindow: NSWindow?
        private var projectPanel: NSPanel?
        private var hostingController: NSHostingController<ProjectCreationView>?
        private weak var nextButton: ProjectCreationDefaultNSButton?
        private var savePanel: NSSavePanel?
        private var initialProject: TrimatoProject?
        private var isCompleting = false

        func update(from source: ProjectCreationSheetPresenter, parent: NSWindow?) {
            self.source = source
            attach(to: parent)
            if source.isPresented {
                presentIfPossible()
            } else if projectPanel != nil, !isCompleting {
                closeProjectPanel()
            }
        }

        func attach(to parent: NSWindow?) {
            guard parentWindow !== parent else { return }
            if projectPanel != nil { closeProjectPanel() }
            parentWindow = parent
            presentIfPossible()
        }

        func registerNextButton(_ button: NSButton) {
            guard let button = button as? ProjectCreationDefaultNSButton else { return }
            nextButton = button
            configureDefaultButton()
        }

        func invalidate() {
            savePanel?.cancel(nil)
            savePanel = nil
            closeProjectPanel()
            source = nil
            parentWindow = nil
        }

        private func presentIfPossible() {
            guard projectPanel == nil,
                  source?.isPresented == true,
                  let parentWindow,
                  parentWindow.attachedSheet == nil else { return }

            let initialProject = TrimatoProject()
            self.initialProject = initialProject
            let rootView = ProjectCreationView(
                initialProject: initialProject,
                heading: "New Project",
                actionTitle: "Next",
                finish: { [weak self] values in self?.chooseProjectLocation(for: values) },
                cancel: { [weak self] in self?.cancelProjectCreation() },
                nativeDefaultButtonReady: { [weak self] button in self?.registerNextButton(button) }
            )
            let hostingController = NSHostingController(rootView: rootView)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "New Project"
            panel.contentViewController = hostingController
            panel.isReleasedWhenClosed = false
            panel.setAccessibilityModal(true)
            self.hostingController = hostingController
            self.projectPanel = panel
            parentWindow.beginSheet(panel)
            configureDefaultButton()
        }

        private func configureDefaultButton() {
            guard let projectPanel,
                  let nextButton,
                  nextButton.window === projectPanel,
                  let buttonCell = nextButton.cell as? NSButtonCell else { return }
            projectPanel.defaultButtonCell = buttonCell
            projectPanel.enableKeyEquivalentForDefaultButtonCell()
            projectPanel.setAccessibilityDefaultButton(nextButton)
        }

        private func chooseProjectLocation(for values: ProjectSettingsValues) {
            guard savePanel == nil,
                  let projectPanel,
                  let initialProject else { return }
            let project = values.applying(to: initialProject)
            let panel = NSSavePanel()
            panel.title = "Save Project"
            panel.prompt = "Create"
            panel.message = "Choose where to create the project folder."
            panel.nameFieldLabel = "Project Folder:"
            panel.nameFieldStringValue = project.name
            panel.allowedContentTypes = [.folder]
            panel.allowsOtherFileTypes = false
            panel.canCreateDirectories = true
            panel.showsTagField = false
            savePanel = panel

            panel.beginSheetModal(for: projectPanel) { [weak self] response in
                guard let self else { return }
                self.savePanel = nil
                panel.orderOut(nil)
                guard response == .OK, let folderURL = panel.url else {
                    self.configureDefaultButton()
                    return
                }
                self.createProject(project, at: folderURL)
            }
        }

        private func createProject(_ project: TrimatoProject, at folderURL: URL) {
            do {
                let packageURL = try ProjectDocument.writeNewProject(project, toFolderAt: folderURL)
                guard let source else { return }
                isCompleting = true
                closeProjectPanel()
                source.presentationEnded()
                source.projectCreated(packageURL)
                isCompleting = false
            } catch {
                presentCreationError(error)
            }
        }

        private func presentCreationError(_ error: Error) {
            guard let projectPanel else { return }
            let alert = NSAlert()
            alert.messageText = "Project Could Not Be Created"
            if (error as? CocoaError)?.code == .fileWriteFileExists {
                alert.informativeText = "A folder with that name already exists. Choose a different project folder name or location."
            } else {
                alert.informativeText = error.localizedDescription
            }
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: projectPanel) { [weak self] _ in
                self?.configureDefaultButton()
            }
        }

        private func cancelProjectCreation() {
            guard let source else { return }
            closeProjectPanel()
            source.presentationEnded()
        }

        private func closeProjectPanel() {
            savePanel?.cancel(nil)
            savePanel = nil
            guard let projectPanel else { return }
            projectPanel.sheetParent?.endSheet(projectPanel)
            projectPanel.orderOut(nil)
            self.projectPanel = nil
            hostingController = nil
            nextButton = nil
            initialProject = nil
        }
    }
}

final class ProjectCreationWindowAnchor: NSView {
    weak var owner: ProjectCreationSheetPresenter.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.attach(to: window)
    }
}
