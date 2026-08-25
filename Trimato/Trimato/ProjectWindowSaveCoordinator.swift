import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectWindowSaveCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private enum PendingCloseAction {
        case explicitSave((Bool) -> Void)
        case saveAndClose
        case discard(TrimatoProject)
    }

    private let projectDocument: ProjectDocument
    private weak var window: NSWindow?
    private weak var nativeDocument: NSDocument?
    private weak var forwardedDelegate: NSWindowDelegate?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingCloseAction: PendingCloseAction?
    private var closeWasConfirmed = false
    private var terminationResolution: ((Bool) -> Void)?

    init(projectDocument: ProjectDocument) {
        self.projectDocument = projectDocument
        super.init()

        projectDocument.$hasUnsavedChanges
            .removeDuplicates()
            .sink { [weak self] hasUnsavedChanges in
                self?.window?.isDocumentEdited = hasUnsavedChanges
            }
            .store(in: &subscriptions)
    }

    var hasUnsavedChanges: Bool { projectDocument.hasUnsavedChanges }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }

        if let currentWindow = self.window, currentWindow.delegate === self {
            currentWindow.delegate = forwardedDelegate
        }

        self.window = window
        nativeDocument = window.windowController?.value(forKey: "document") as? NSDocument
        forwardedDelegate = window.delegate
        window.delegate = self
        window.isDocumentEdited = projectDocument.hasUnsavedChanges
        ProjectWindowSaveRegistry.shared.register(self)

    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeWasConfirmed {
            closeWasConfirmed = false
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        guard projectDocument.hasUnsavedChanges else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        let alert = NSAlert()
        alert.messageText = "Save Changes to This Project?"
        alert.informativeText = "Your timeline and project changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveThenClose()
            case .alertSecondButtonReturn:
                self.discardThenClose()
            default:
                self.finishTerminationResolution(shouldTerminate: false)
                break
            }
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    func requestCloseForTermination(completion: @escaping (Bool) -> Void) {
        guard terminationResolution == nil else {
            completion(false)
            return
        }
        guard projectDocument.hasUnsavedChanges else {
            completion(true)
            return
        }
        guard let window else {
            completion(false)
            return
        }

        terminationResolution = completion
        window.makeKeyAndOrderFront(nil)
        window.performClose(nil)
    }

    func save(completion: @escaping (Bool) -> Void) {
        guard pendingCloseAction == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingCloseAction = .explicitSave(completion)
        nativeDocument.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    func saveAs(completion: @escaping (Bool) -> Void) {
        guard pendingCloseAction == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingCloseAction = .explicitSave(completion)
        nativeDocument.runModalSavePanel(
            for: .saveAsOperation,
            delegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    private func saveThenClose() {
        guard let nativeDocument else {
            presentSaveUnavailableError()
            return
        }
        pendingCloseAction = .saveAndClose
        nativeDocument.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    private func discardThenClose() {
        guard let nativeDocument else {
            presentSaveUnavailableError()
            return
        }

        let discardedProject = projectDocument.restoreExplicitlySavedProject()
        guard nativeDocument.fileURL != nil else {
            nativeDocument.updateChangeCount(.changeCleared)
            closeAfterSuccessfulResolution()
            return
        }

        pendingCloseAction = .discard(discardedProject)
        DispatchQueue.main.async { [weak self] in
            guard let self, let nativeDocument = self.nativeDocument else { return }
            nativeDocument.save(
                withDelegate: self,
                didSave: #selector(self.document(_:didSave:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    @objc private func document(
        _ document: NSDocument,
        didSave successfully: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let action = pendingCloseAction
        pendingCloseAction = nil

        guard successfully else {
            if case .discard(let discardedProject) = action {
                projectDocument.reinstateDiscardedProject(discardedProject)
            }
            if case .explicitSave(let completion) = action { completion(false) }
            finishTerminationResolution(shouldTerminate: false)
            return
        }

        projectDocument.markCurrentProjectAsExplicitlySaved()
        switch action {
        case .explicitSave(let completion):
            completion(true)
        case .saveAndClose, .discard:
            closeAfterSuccessfulResolution()
        case nil:
            break
        }
    }

    private func closeAfterSuccessfulResolution() {
        guard let window else { return }
        closeWasConfirmed = true
        window.performClose(nil)
        finishTerminationResolution(shouldTerminate: true)
    }

    private func presentSaveUnavailableError() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Project Could Not Be Saved"
        alert.informativeText = "Trimato could not access the native project document. The project will remain open so your changes are not lost."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
        finishTerminationResolution(shouldTerminate: false)
    }

    private func finishTerminationResolution(shouldTerminate: Bool) {
        let resolution = terminationResolution
        terminationResolution = nil
        resolution?(shouldTerminate)
    }
}

@MainActor
private final class ProjectWindowSaveRegistry {
    static let shared = ProjectWindowSaveRegistry()

    private let coordinators = NSHashTable<ProjectWindowSaveCoordinator>.weakObjects()

    func register(_ coordinator: ProjectWindowSaveCoordinator) {
        coordinators.add(coordinator)
    }

    var dirtyCoordinators: [ProjectWindowSaveCoordinator] {
        coordinators.allObjects.filter(\.hasUnsavedChanges)
    }
}

@MainActor
final class ProjectSaveApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinators = ProjectWindowSaveRegistry.shared.dirtyCoordinators
        guard !coordinators.isEmpty else { return .terminateNow }

        resolveForTermination(coordinators, at: 0, application: sender)
        return .terminateLater
    }

    private func resolveForTermination(
        _ coordinators: [ProjectWindowSaveCoordinator],
        at index: Int,
        application: NSApplication
    ) {
        guard index < coordinators.count else {
            application.reply(toApplicationShouldTerminate: true)
            return
        }

        coordinators[index].requestCloseForTermination { [weak self, weak application] shouldContinue in
            guard let self, let application else { return }
            guard shouldContinue else {
                application.reply(toApplicationShouldTerminate: false)
                return
            }
            self.resolveForTermination(coordinators, at: index + 1, application: application)
        }
    }
}

struct ProjectWindowSaveBridge: NSViewRepresentable {
    let saveCoordinator: ProjectWindowSaveCoordinator

    func makeNSView(context: Context) -> ProjectWindowAttachmentView {
        let view = ProjectWindowAttachmentView(frame: .zero)
        view.onWindowChange = { [weak saveCoordinator] window in
            saveCoordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: ProjectWindowAttachmentView, context: Context) {
        nsView.onWindowChange = { [weak saveCoordinator] window in
            saveCoordinator?.attach(to: window)
        }
        if let window = nsView.window { saveCoordinator.attach(to: window) }
    }
}

final class ProjectWindowAttachmentView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindowChange?(window) }
    }
}
