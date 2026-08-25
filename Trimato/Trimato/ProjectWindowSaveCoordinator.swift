import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectWindowSaveCoordinator: NSObject, ObservableObject {
    private let projectDocument: ProjectDocument
    private weak var window: NSWindow?
    private weak var nativeDocument: NSDocument?
    private var pendingSaveCompletion: ((Bool) -> Void)?
    private var pendingCloseCompletion: ((Bool) -> Void)?
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowBecameKeyHandler: (() -> Void)?

    init(projectDocument: ProjectDocument) {
        self.projectDocument = projectDocument
        super.init()
    }

    deinit {
        if let windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(windowBecameKeyObserver)
        }
    }

    var hasUnsavedChanges: Bool { projectDocument.hasUnsavedChanges }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        if let windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(windowBecameKeyObserver)
        }
        self.window = window
        nativeDocument = window.windowController?.value(forKey: "document") as? NSDocument
        if projectDocument.hasUnsavedChanges {
            nativeDocument?.updateChangeCount(.changeDone)
        }
        windowBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowBecameKeyHandler?() }
        }
        if window.isKeyWindow { windowBecameKeyHandler?() }
    }

    func onWindowBecameKey(_ handler: @escaping () -> Void) {
        windowBecameKeyHandler = handler
        if window?.isKeyWindow == true { handler() }
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
        completion?(true)
        document.close()
    }

    private func presentSaveUnavailableError() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Project Could Not Be Saved"
        alert.informativeText = "Trimato could not access the native project document. The project will remain open so your changes are not lost."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
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
