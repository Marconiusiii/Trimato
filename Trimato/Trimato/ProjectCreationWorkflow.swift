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
        private var panelViewController: ProjectCreationPanelViewController?
        private var submitProjectCreation: (() -> Void)?
        private var savePanel: NSSavePanel?
        private var initialProject: TrimatoProject?
        private var isCompleting = false
        private var isChoosingLocation = false

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

        func invalidate() {
            savePanel?.cancel(nil)
            savePanel = nil
            closeProjectPanel()
            source = nil
            parentWindow = nil
        }

        private func presentIfPossible() {
            guard projectPanel == nil,
                  !isChoosingLocation,
                  source?.isPresented == true,
                  let parentWindow,
                  parentWindow.attachedSheet == nil else { return }

            let initialProject = self.initialProject ?? TrimatoProject()
            self.initialProject = initialProject
            let rootView = ProjectCreationView(
                initialProject: initialProject,
                heading: "New Project",
                finish: { [weak self] values in self?.chooseProjectLocation(for: values) },
                submitHandlerReady: { [weak self] submit in self?.submitProjectCreation = submit }
            )
            let hostingController = NSHostingController(rootView: rootView)
            let panelViewController = ProjectCreationPanelViewController(
                hostingController: hostingController,
                cancel: { [weak self] in self?.cancelProjectCreation() },
                proceed: { [weak self] in self?.submitProjectCreation?() }
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "New Project"
            panel.contentViewController = panelViewController
            panel.isReleasedWhenClosed = false
            panel.setAccessibilityModal(true)
            self.panelViewController = panelViewController
            self.projectPanel = panel
            parentWindow.beginSheet(panel)
            configureDefaultButton()
        }

        private func configureDefaultButton() {
            guard let projectPanel,
                  let panelViewController else { return }
            ProjectCreationWindowConfiguration.configureDefaultButton(
                panelViewController.nextButton,
                in: projectPanel
            )
        }

        private func chooseProjectLocation(for values: ProjectSettingsValues) {
            guard savePanel == nil,
                  let projectPanel,
                  let initialProject,
                  let parentWindow else { return }
            let project = values.applying(to: initialProject)
            self.initialProject = project
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
            isChoosingLocation = true
            projectPanel.sheetParent?.endSheet(projectPanel)
            projectPanel.orderOut(nil)
            self.projectPanel = nil
            panelViewController = nil
            submitProjectCreation = nil

            panel.beginSheetModal(for: parentWindow) { [weak self] response in
                guard let self else { return }
                self.savePanel = nil
                self.isChoosingLocation = false
                panel.orderOut(nil)
                guard response == .OK, let folderURL = panel.url else {
                    self.presentIfPossible()
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
            guard let parentWindow else { return }
            let alert = NSAlert()
            alert.messageText = "Project Could Not Be Created"
            if (error as? CocoaError)?.code == .fileWriteFileExists {
                alert.informativeText = "A folder with that name already exists. Choose a different project folder name or location."
            } else {
                alert.informativeText = error.localizedDescription
            }
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: parentWindow) { [weak self] _ in
                self?.presentIfPossible()
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
            isChoosingLocation = false
            if let projectPanel {
                projectPanel.sheetParent?.endSheet(projectPanel)
                projectPanel.orderOut(nil)
            }
            self.projectPanel = nil
            panelViewController = nil
            submitProjectCreation = nil
            initialProject = nil
        }
    }
}

final class ProjectCreationPanelViewController: NSViewController {
    let nextButton = NSButton(title: "Next", target: nil, action: nil)

    private let hostingController: NSViewController
    private let cancel: () -> Void
    private let proceed: () -> Void

    init(
        hostingController: NSViewController,
        cancel: @escaping () -> Void,
        proceed: @escaping () -> Void
    ) {
        self.hostingController = hostingController
        self.cancel = cancel
        self.proceed = proceed
        super.init(nibName: nil, bundle: nil)
        addChild(hostingController)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 610))
        let formView = hostingController.view
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))

        nextButton.bezelStyle = .rounded
        nextButton.setButtonType(.momentaryPushIn)
        nextButton.keyEquivalent = "\r"
        nextButton.keyEquivalentModifierMask = []
        nextButton.target = self
        nextButton.action = #selector(nextPressed)
        nextButton.identifier = NSUserInterfaceItemIdentifier("trimato.new-project.next")

        cancelButton.bezelStyle = .rounded
        cancelButton.setButtonType(.momentaryPushIn)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.identifier = NSUserInterfaceItemIdentifier("trimato.new-project.cancel")

        formView.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(formView)
        rootView.addSubview(cancelButton)
        rootView.addSubview(nextButton)

        NSLayoutConstraint.activate([
            formView.topAnchor.constraint(equalTo: rootView.topAnchor),
            formView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            formView.bottomAnchor.constraint(lessThanOrEqualTo: cancelButton.topAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            nextButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -24),
        ])
        view = rootView
    }

    @objc private func cancelPressed() {
        cancel()
    }

    @objc private func nextPressed() {
        proceed()
    }
}

enum ProjectCreationWindowConfiguration {
    static func configureDefaultButton(_ button: NSButton, in window: NSWindow) {
        guard button.window === window,
              let buttonCell = button.cell as? NSButtonCell else { return }
        window.defaultButtonCell = buttonCell
        window.enableKeyEquivalentForDefaultButtonCell()
    }
}

final class ProjectCreationWindowAnchor: NSView {
    weak var owner: ProjectCreationSheetPresenter.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.attach(to: window)
    }
}
