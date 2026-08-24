import AppKit
import Combine
import SwiftUI

@MainActor
final class ClipPlacementCommandContext: ObservableObject {
    let controller: ProjectController
    let editSelection: EditorSelection
    @Published var segments: [SourceSegment]
    @Published private(set) var focusRequest = 0
    @Published private(set) var isKeyWindow = false

    init(
        controller: ProjectController,
        editSelection: EditorSelection,
        segments: [SourceSegment]
    ) {
        self.controller = controller
        self.editSelection = editSelection
        self.segments = segments
    }

    var canPlace: Bool {
        isKeyWindow && !segments.isEmpty && NSApp.modalWindow == nil
    }

    func place(_ placement: PlacementAction) {
        guard canPlace else { return }
        controller.place(placement, editing: editSelection, segments: segments)
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
        .frame(minWidth: 700, minHeight: 600)
    }
}
