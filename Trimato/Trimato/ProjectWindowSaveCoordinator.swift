import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectWindowSaveCoordinator: NSObject, ObservableObject {
    nonisolated enum NativeChangeAction: Equatable {
        case markChanged
        case clear
        case none
    }

    private let projectDocument: ProjectDocument
    private weak var window: NSWindow?
    private weak var nativeDocument: NSDocument?
    private var pendingSaveCompletion: ((Bool) -> Void)?
    private var pendingCloseCompletion: ((Bool) -> Void)?
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var applicationWillTerminateObserver: NSObjectProtocol?
    private var unsavedChangesSubscription: AnyCancellable?
    private var windowBecameKeyHandler: (() -> Void)?
    private var undoManagerHandler: ((UndoManager) -> Void)?
    private var lastProjectWindowWillCloseHandler: (() -> Void)?
    private var isFinishingProjectWindowClose = false
    private var didRestoreLauncherAfterClose = false
    private var isApplicationTerminating = false
    @Published private(set) var windowAttachmentRevision = 0
    @Published var presentedError: ProjectPresentedError?

    init(projectDocument: ProjectDocument) {
        self.projectDocument = projectDocument
        super.init()
        applicationWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isApplicationTerminating = true }
        }
        unsavedChangesSubscription = projectDocument.unsavedChangesDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] hasUnsavedChanges in
                self?.synchronizeNativeDocumentChangeState(hasUnsavedChanges)
            }
    }

    deinit {
        if let windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(windowBecameKeyObserver)
        }
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        if let applicationWillTerminateObserver {
            NotificationCenter.default.removeObserver(applicationWillTerminateObserver)
        }
    }

    var hasUnsavedChanges: Bool { projectDocument.hasUnsavedChanges }
    var attachedWindow: NSWindow? { window }
    var projectURL: URL? { nativeDocument?.fileURL }

    func attach(to window: NSWindow) {
        if self.window === window {
            if nativeDocument == nil {
                nativeDocument = NSDocumentController.shared.document(for: window)
            }
            return
        }
        if let windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(windowBecameKeyObserver)
        }
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        self.window = window
        window.isRestorable = false
        nativeDocument = NSDocumentController.shared.document(for: window)
        windowAttachmentRevision += 1
        if let undoManager = nativeDocument?.undoManager ?? window.undoManager {
            undoManagerHandler?(undoManager)
        }
        synchronizeNativeDocumentChangeState(projectDocument.hasUnsavedChanges)
        windowBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowBecameKeyHandler?()
            }
        }
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.projectWindowWillClose() }
        }
        if window.isKeyWindow { windowBecameKeyHandler?() }
    }

    func onWindowBecameKey(_ handler: @escaping () -> Void) {
        windowBecameKeyHandler = handler
        if window?.isKeyWindow == true { handler() }
    }

    func onUndoManagerAvailable(_ handler: @escaping (UndoManager) -> Void) {
        undoManagerHandler = handler
        if let undoManager = nativeDocument?.undoManager ?? window?.undoManager {
            handler(undoManager)
        }
    }

    func onLastProjectWindowWillClose(_ handler: @escaping () -> Void) {
        lastProjectWindowWillCloseHandler = handler
    }

    func requestClose(completion: @escaping (Bool) -> Void) {
        guard pendingCloseCompletion == nil, let nativeDocument else {
            completion(false)
            return
        }
        pendingCloseCompletion = completion
        nativeDocument.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    func save(completion: @escaping (Bool) -> Void) {
        guard pendingSaveCompletion == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingSaveCompletion = completion
        nativeDocument.save(
            withDelegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    func saveAs(completion: @escaping (Bool) -> Void) {
        guard pendingSaveCompletion == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingSaveCompletion = completion
        nativeDocument.runModalSavePanel(
            for: .saveAsOperation,
            delegate: self,
            didSave: #selector(document(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(
        _ document: NSDocument,
        didSave successfully: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let completion = pendingSaveCompletion
        pendingSaveCompletion = nil
        if successfully { projectDocument.markCurrentProjectAsExplicitlySaved() }
        completion?(successfully)
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        guard shouldClose else {
            completion?(false)
            return
        }
        document.close()
        restoreLauncherAfterProjectClosed()
        completion?(true)
    }

    private func presentSaveUnavailableError() {
        presentedError = ProjectPresentedError(
            title: "Project Could Not Be Saved",
            message: "Trimato could not access the native project document. The project will remain open so your changes are not lost."
        )
    }

    private func synchronizeNativeDocumentChangeState(_ hasUnsavedChanges: Bool) {
        guard let nativeDocument else { return }
        switch Self.nativeChangeAction(
            hasUnsavedChanges: hasUnsavedChanges,
            isDocumentEdited: nativeDocument.isDocumentEdited
        ) {
        case .markChanged:
            nativeDocument.updateChangeCount(.changeDone)
        case .clear:
            nativeDocument.updateChangeCount(.changeCleared)
        case .none:
            break
        }
    }

    nonisolated static func nativeChangeAction(
        hasUnsavedChanges: Bool,
        isDocumentEdited: Bool
    ) -> NativeChangeAction {
        if hasUnsavedChanges, !isDocumentEdited { return .markChanged }
        if !hasUnsavedChanges, isDocumentEdited { return .clear }
        return .none
    }

    private func projectWindowWillClose() {
        guard !isFinishingProjectWindowClose else { return }
        isFinishingProjectWindowClose = true

        // NSWindow.willCloseNotification arrives before NSDocument.close()
        // removes the document from NSDocumentController. Continue on the next
        // main-actor turn so the launcher cannot race the closing document.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.restoreLauncherAfterProjectClosed()
        }
    }

    private func restoreLauncherAfterProjectClosed() {
        guard !didRestoreLauncherAfterClose, let nativeDocument else { return }
        let openDocuments = NSDocumentController.shared.documents
        guard !openDocuments.contains(where: { $0 === nativeDocument }) else { return }
        if Self.shouldRestoreLauncher(
            isApplicationTerminating: isApplicationTerminating,
            otherProjectDocumentCount: openDocuments.count
        ) {
            didRestoreLauncherAfterClose = true
            lastProjectWindowWillCloseHandler?()
        }
    }

    nonisolated static func shouldRestoreLauncher(
        isApplicationTerminating: Bool,
        otherProjectDocumentCount: Int
    ) -> Bool {
        !isApplicationTerminating && otherProjectDocumentCount == 0
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
            DispatchQueue.main.async {
                saveCoordinator?.attach(to: window)
            }
        }
        if let window = nsView.window {
            DispatchQueue.main.async {
                saveCoordinator.attach(to: window)
            }
        }
    }
}

final class ProjectWindowAttachmentView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onWindowChange?(window)
        }
    }
}


/// Project save commands remain available even when a native pane is first responder
/// or a utility scene has removed its document menu commands.
@MainActor
enum ProjectSaveKeyboard {
    static func handle(_ event: NSEvent, controller: ProjectController?) -> NSEvent? {
        guard let controller, let saveAs = saveAsCommand(event) else { return event }
        if saveAs { controller.saveProjectDocumentAs() }
        else { controller.saveProjectDocument() }
        return nil
    }

    static func saveAsCommand(_ event: NSEvent) -> Bool? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers?.lowercased() == "s",
              modifiers == .command || modifiers == [.command, .shift] else { return nil }
        return modifiers.contains(.shift)
    }
}
