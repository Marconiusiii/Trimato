import AppKit
import Combine
import SwiftUI

@MainActor
final class ClipPlacementCommandContext: ObservableObject {
    let controller: ProjectController
    let editSelection: EditorSelection
    @Published private(set) var segments: [SourceSegment]
    @Published private(set) var focusRequest = 0
    @Published private(set) var isKeyWindow = false
    @Published var updateErrorMessage: String?
    private var draft: ClipEditorDraft

    init(
        controller: ProjectController,
        editSelection: EditorSelection,
        segments: [SourceSegment]
    ) {
        self.controller = controller
        self.editSelection = editSelection
        self.segments = segments
        draft = ClipEditorDraft(segments: segments)
    }

    var canPlace: Bool {
        isKeyWindow && !segments.isEmpty && NSApp.modalWindow == nil
    }

    var isTimelineEntry: Bool {
        switch editSelection {
        case .timelineClip, .cutaway: true
        case .asset, .project: false
        }
    }

    var hasUncommittedChanges: Bool {
        isTimelineEntry && draft.hasChanges
    }

    var canUpdate: Bool {
        isKeyWindow && hasUncommittedChanges && !segments.isEmpty && NSApp.modalWindow == nil
    }

    func setSegments(_ segments: [SourceSegment]) {
        guard !segments.isEmpty else {
            self.segments = []
            draft.replace(with: [])
            return
        }
        self.segments = segments
        draft.replace(with: segments)
        if case .asset(let id) = editSelection {
            controller.updateSourceEdit(assetID: id, segments: segments)
        }
    }

    func place(_ placement: PlacementAction) {
        guard canPlace else { return }
        controller.place(placement, editing: editSelection, segments: segments)
    }

    @discardableResult
    func performUpdate() -> Bool {
        guard isTimelineEntry else { return false }
        guard !segments.isEmpty else {
            updateErrorMessage = "Set a valid In and Out selection before updating the timeline clip."
            return false
        }
        do {
            try controller.updateTimelineEntry(editSelection, segments: segments)
            objectWillChange.send()
            draft.commit()
            return true
        } catch {
            updateErrorMessage = error.localizedDescription
            return false
        }
    }

    func requestAccessibilityFocus() {
        focusRequest += 1
    }

    func setKeyWindow(_ isKeyWindow: Bool) {
        self.isKeyWindow = isKeyWindow
    }
}

@MainActor
final class ClipEditorWindowCoordinator: ObservableObject {
    private let controller: ProjectController
    private var windows: [EditorSelection: ClipEditorWindowController] = [:]

    init(controller: ProjectController) {
        self.controller = controller
    }

    func open(_ editSelection: EditorSelection) {
        guard editSelection != .project,
              let asset = controller.asset(for: editSelection),
              let segments = controller.segments(for: editSelection) else { return }

        if let existing = windows[editSelection] {
            existing.showAndFocus()
            return
        }

        let commandContext = ClipPlacementCommandContext(
            controller: controller,
            editSelection: editSelection,
            segments: segments
        )
        let rootView = ClipEditorWindowView(
            controller: controller,
            asset: asset,
            editSelection: editSelection,
            initialSegments: segments,
            commandContext: commandContext
        )
        let windowController = ClipEditorWindowController(
            title: "\(asset.name) — Clip Editor",
            rootView: rootView,
            commandContext: commandContext
        )
        windowController.onClose = { [weak self] in
            self?.windows[editSelection] = nil
        }
        windows[editSelection] = windowController
        windowController.showAndFocus()
    }
}

@MainActor
private final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {
    let commandContext: ClipPlacementCommandContext
    var onClose: (() -> Void)?
    private var closeWasConfirmed = false

    init<Content: View>(
        title: String,
        rootView: Content,
        commandContext: ClipPlacementCommandContext
    ) {
        self.commandContext = commandContext
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.collectionBehavior.insert(.participatesInCycle)
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 600)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        commandContext.setKeyWindow(true)
        commandContext.requestAccessibilityFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        commandContext.setKeyWindow(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeWasConfirmed, commandContext.hasUncommittedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Update Clip Before Closing?"
        alert.informativeText = "This timeline clip has changes that have not been applied to the project."
        alert.addButton(withTitle: "Update Clip")
        alert.addButton(withTitle: "Close without Updating")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.commandContext.performUpdate() else { return }
                self.closeWasConfirmed = true
                sender.performClose(nil)
            case .alertSecondButtonReturn:
                self.closeWasConfirmed = true
                sender.performClose(nil)
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        commandContext.setKeyWindow(false)
        onClose?()
        onClose = nil
    }
}

private struct ClipEditorWindowView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext
    @AccessibilityFocusState private var editorGroupFocused: Bool

    var body: some View {
        MacEditorPane("Clip Editor") {
            SourceClipEditorView(
                controller: controller,
                asset: asset,
                editSelection: editSelection,
                initialSegments: initialSegments,
                commandContext: commandContext
            )
        }
        .accessibilityFocused($editorGroupFocused)
        .focusedObject(controller)
        .focusedObject(commandContext)
        .onAppear {
            editorGroupFocused = true
        }
        .onChange(of: commandContext.focusRequest) { _ in
            editorGroupFocused = true
        }
        .alert("Clip Could Not Be Updated", isPresented: Binding(
            get: { commandContext.updateErrorMessage != nil },
            set: { presented in
                if !presented { commandContext.updateErrorMessage = nil }
            }
        )) {
            Button("OK") { commandContext.updateErrorMessage = nil }
        } message: {
            Text(commandContext.updateErrorMessage ?? "The timeline clip could not be updated.")
        }
        .frame(minWidth: 700, minHeight: 600)
    }
}
