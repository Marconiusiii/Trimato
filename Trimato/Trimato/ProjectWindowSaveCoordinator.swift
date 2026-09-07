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

    var autoSaveAllowed: () -> Bool = { true }
    private let projectDocument: ProjectDocument
    private let preferences: UserDefaults
    private var autoSavePreferencesSubscription: AnyCancellable?
    private var autoSaveTimerSubscription: AnyCancellable?
    private weak var window: NSWindow?
    private weak var nativeDocument: NSDocument?
    private var savingSnapshot: TrimatoProject?
    private var closeDelegate: ProjectWindowCloseDelegate?
    private var windowCloseRequested: (() -> Void)?
    @Published var isConfirmingClose = false
    @Published private(set) var isResolvingClose = false
    @Published private(set) var quitError: String?
    private var closeDecision: ProjectCloseDecision?
    private var executingCloseDecision = false
    private var closeWaitsForSave = false
    private weak var confirmationOrigin: NSWindow?
    private var pendingSaveCompletion: ((Bool) -> Void)?
    private var pendingCloseCompletion: ((Bool) -> Void)?
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var sheetEndedObserver: NSObjectProtocol?
    private var awaitingCloseDismissal = false
    private var applicationWillTerminateObserver: NSObjectProtocol?
    private var unsavedChangesSubscription: AnyCancellable?
    private var windowBecameKeyHandler: (() -> Void)?
    private var undoManagerHandler: ((UndoManager) -> Void)?
    private var lastProjectWindowWillCloseHandler: (() -> Void)?
    private var isFinishingProjectWindowClose = false
    private var didRestoreLauncherAfterClose = false
    @Published private(set) var isApplicationTerminating = false
    private var quitEdits: ProjectQuitEdits?
    private var quitPreparation: Task<Void, Never>?
    @Published private(set) var quitCancellationRequested = false
    @Published private(set) var windowAttachmentRevision = 0
    @Published var presentedError: ProjectPresentedError?

    init(projectDocument: ProjectDocument, preferences: UserDefaults = .standard) {
        self.projectDocument = projectDocument
        self.preferences = preferences
        super.init()
        autoSavePreferencesSubscription = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification, object: preferences
        )
        .map { _ in () }
        .prepend(())
        .receive(on: RunLoop.main)
        .map { AppPreferences.autoSaveInterval(in: preferences) }
        .removeDuplicates()
        .sink { [weak self] interval in
            self?.scheduleAutoSave(every: interval)
        }
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
        if let sheetEndedObserver { NotificationCenter.default.removeObserver(sheetEndedObserver) }
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
            if window.delegate !== closeDelegate {
                let delegate = ProjectWindowCloseDelegate(original: window.delegate) { [weak self] in
                    self?.windowCloseRequested?()
                }
                closeDelegate = delegate
                window.delegate = delegate
            }
            return
        }
        if let windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(windowBecameKeyObserver)
        }
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        if let sheetEndedObserver { NotificationCenter.default.removeObserver(sheetEndedObserver) }
        sheetEndedObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.awaitingCloseDismissal else { return }
                self.closeConfirmationDismissed()
            }
        }
        self.window = window
        window.isRestorable = false
        nativeDocument = NSDocumentController.shared.document(for: window)
        let delegate = ProjectWindowCloseDelegate(original: window.delegate) { [weak self] in
            self?.windowCloseRequested?()
        }
        closeDelegate = delegate
        window.delegate = delegate
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

    func onWindowCloseRequested(_ action: @escaping () -> Void) {
        windowCloseRequested = action
    }

    func setTerminationRequested(_ value: Bool) { isApplicationTerminating = value }

    func requestQuit(edits: ProjectQuitEdits, completion: @escaping (Bool) -> Void) {
        guard nativeDocument != nil, pendingCloseCompletion == nil else { completion(false); return }
        isApplicationTerminating = true
        quitEdits = edits
        quitError = nil
        NativeModalWindowController.suspendForQuitReview()
        QuitReviewState.shared.coordinator = self
        requestClose(completion: completion)
    }

    func cancelQuitReview() {
        guard pendingCloseCompletion != nil else { return }
        if isResolvingClose {
            quitCancellationRequested = true
            quitPreparation?.cancel()
            return
        }
        chooseCloseDecision(.cancel)
        closeConfirmationDismissed()
    }

    var projectName: String { projectDocument.project.name }

    func requestClose(completion: @escaping (Bool) -> Void) {
        guard pendingCloseCompletion == nil, nativeDocument != nil else {
            completion(false)
            return
        }
        pendingCloseCompletion = completion
        if pendingSaveCompletion != nil { closeWaitsForSave = true; return }
        beginCloseReview()
    }

    private func beginCloseReview() {
        if hasUnsavedChanges || quitEdits?.hasChanges == true {
            confirmationOrigin = NSApp.keyWindow
            if !isApplicationTerminating { window?.makeKeyAndOrderFront(nil) }
            isConfirmingClose = true
        } else {
            finishClosing()
        }
    }

    func chooseCloseDecision(_ decision: ProjectCloseDecision) {
        if decision == .cancel, isApplicationTerminating, isResolvingClose {
            cancelQuitReview()
            return
        }
        guard pendingCloseCompletion != nil, !isResolvingClose else { return }
        closeDecision = decision
        isResolvingClose = true
        isConfirmingClose = false
    }

    // Called after the confirmation sheet has left, before presenting a save panel.
    func closeConfirmationDismissed() {
        guard pendingCloseCompletion != nil, !executingCloseDecision else { return }
        awaitingCloseDismissal = true
        guard isApplicationTerminating || window?.attachedSheet == nil else { return }
        awaitingCloseDismissal = false
        executingCloseDecision = true
        let decision = closeDecision ?? .cancel
        closeDecision = nil
        switch decision {
        case .cancel:
            completeClose(false)
        case .save:
            if let quitEdits {
                quitPreparation = Task { @MainActor in
                    do {
                        try await quitEdits.apply()
                        try Task.checkCancellation()
                        self.saveAfterCloseReview()
                    } catch is CancellationError {
                        self.completeClose(false)
                    } catch {
                        if self.quitCancellationRequested { self.completeClose(false); return }
                        self.quitError = error.localizedDescription
                        self.isResolvingClose = false
                        self.executingCloseDecision = false
                        self.isConfirmingClose = true
                    }
                }
            } else { saveAfterCloseReview() }
        case .discard:
            let discarded = projectDocument.restoreExplicitlySavedProject()
            guard nativeDocument?.fileURL != nil else {
                finishClosing()
                return
            }
            // Autosave may already have written the edits. Persist the explicit-save
            // baseline before closing so Don't Save really discards those edits.
            nativeDocument?.updateChangeCount(.changeDone)
            save { [weak self] saved in
                guard let self else { return }
                if saved && !self.hasUnsavedChanges && !self.quitCancellationRequested { self.finishClosing() }
                else {
                    if !saved || self.quitCancellationRequested { self.projectDocument.reinstateDiscardedProject(discarded) }
                    self.completeClose(false)
                }
            }
        }
    }

    private func saveAfterCloseReview() {
        save { [weak self] saved in
            guard let self else { return }
            if saved && !self.hasUnsavedChanges && !self.quitCancellationRequested { self.finishClosing() }
            else { self.completeClose(false) }
        }
    }

    private func finishClosing() {
        guard let nativeDocument else { completeClose(false); return }
        nativeDocument.updateChangeCount(.changeCleared)
        nativeDocument.close()
        restoreLauncherAfterProjectClosed()
        completeClose(true)
    }

    private func completeClose(_ closed: Bool) {
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        awaitingCloseDismissal = false
        isResolvingClose = false
        executingCloseDecision = false
        closeDecision = nil
        if !closed, confirmationOrigin?.isVisible == true { confirmationOrigin?.makeKeyAndOrderFront(nil) }
        confirmationOrigin = nil
        quitEdits = nil
        quitPreparation = nil
        quitCancellationRequested = false
        if QuitReviewState.shared.coordinator === self { QuitReviewState.shared.coordinator = nil }
        if !closed {
            isApplicationTerminating = false
            NativeModalWindowController.resumeAfterQuitCancelled()
        }
        completion?(closed)
    }

    private func scheduleAutoSave(every interval: TimeInterval) {
        autoSaveTimerSubscription = nil
        guard interval > 0, !isFinishingProjectWindowClose else { return }
        autoSaveTimerSubscription = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.autoSaveIfNeeded() }
    }

    /// Save committed project changes without opening a save panel or applying editor drafts.
    func autoSaveIfNeeded() {
        guard autoSaveAllowed(), AppPreferences.autoSaveInterval(in: preferences) > 0,
              hasUnsavedChanges,
              nativeDocument?.fileURL != nil,
              nativeDocument?.fileType != nil,
              pendingSaveCompletion == nil,
              pendingCloseCompletion == nil,
              !isApplicationTerminating,
              !isFinishingProjectWindowClose,
              presentedError == nil else { return }
        save { _ in }
    }

    func save(completion: @escaping (Bool) -> Void) {
        guard pendingSaveCompletion == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingSaveCompletion = completion
        savingSnapshot = projectDocument.project
        if hasUnsavedChanges && !nativeDocument.isDocumentEdited { nativeDocument.updateChangeCount(.changeDone) }
        if let url = nativeDocument.fileURL, let type = nativeDocument.fileType {
            nativeDocument.save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
                MainActor.assumeIsolated { self?.completeSave(error == nil, error: error) }
            }
        } else {
            nativeDocument.save(
                withDelegate: self,
                didSave: #selector(document(_:didSave:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    func saveAs(completion: @escaping (Bool) -> Void) {
        guard pendingSaveCompletion == nil, let nativeDocument else {
            completion(false)
            if nativeDocument == nil { presentSaveUnavailableError() }
            return
        }
        pendingSaveCompletion = completion
        savingSnapshot = projectDocument.project
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
        completeSave(successfully)
    }

    private func completeSave(_ successfully: Bool, error: Error? = nil) {
        let completion = pendingSaveCompletion
        pendingSaveCompletion = nil
        if successfully, let savingSnapshot { projectDocument.markProjectAsExplicitlySaved(savingSnapshot) }
        savingSnapshot = nil
        if !successfully {
            presentedError = ProjectPresentedError(title: "Project Could Not Be Saved",
                message: error?.localizedDescription ?? "The save did not complete. The project remains open with its changes.")
        }
        completion?(successfully)
        if closeWaitsForSave {
            closeWaitsForSave = false
            if successfully { beginCloseReview() }
            else { completeClose(false) }
        }
    }

    private func presentSaveUnavailableError() {
        presentedError = ProjectPresentedError(
            title: "Project Could Not Be Saved",
            message: "The save did not complete. The project remains open with its changes."
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
        autoSaveTimerSubscription = nil

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
        if let coordinator = QuitReviewState.shared.coordinator {
            coordinator.chooseCloseDecision(.save)
        } else if saveAs { controller.saveProjectDocumentAs() }
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


@MainActor
private final class ProjectWindowCloseDelegate: NSObject, NSWindowDelegate {
    private weak var original: (any NSWindowDelegate)?
    private let requestClose: () -> Void

    init(original: (any NSWindowDelegate)?, requestClose: @escaping () -> Void) {
        self.original = original
        self.requestClose = requestClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor [weak self] in self?.requestClose() }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
