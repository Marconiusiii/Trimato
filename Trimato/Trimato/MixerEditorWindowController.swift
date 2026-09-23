import AppKit
import Combine
import SwiftUI

@MainActor
final class MixerWindowRegistry: ObservableObject {
    static let shared = MixerWindowRegistry()
    @Published private(set) var session: MixerSession?
    @Published private(set) var isKeyWindow = false
    private var editor: MixerEditorWindowController?
    private var changes: AnyCancellable?
    var activeSession: MixerSession? { isKeyWindow ? session : nil }
    var activeWindow: NSWindow? { isKeyWindow ? editor?.window : nil }

    func open(controller: ProjectController) {
        if let editor, session?.controller === controller { editor.showAndFocus(); return }
        if let previous = session { close(for: previous.controller) }
        guard let player = controller.projectPlayer else { return }
        let session = MixerSession(controller: controller, player: player)
        self.session = session
        changes = session.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        let editor = MixerEditorWindowController(session: session)
        self.editor = editor
        editor.onKeyChange = { [weak self] key in self?.isKeyWindow = key }
        editor.onClose = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.isKeyWindow = false
            self.editor = nil
            self.session = nil
            self.changes = nil
            session.close()
        }
        editor.showAndFocus()
    }
    func close(for controller: ProjectController) {
        guard session?.controller === controller else { return }
        editor?.returnsToProject = false
        editor?.window?.close()
    }
}

/// Uses the Clip Editor's native window lifecycle and screen-fitting behavior.
@MainActor
final class MixerEditorWindowController: NSWindowController, NSWindowDelegate {
    let session: MixerSession
    var onKeyChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private var keyboardMonitor: Any?
    private var didArrange = false
    var returnsToProject = true
    private var timelineReturn: MixerTimelineReturn?

    init(session: MixerSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mixer — \(session.controller.project.name)"
        let hostingController = NSHostingController(rootView:
            MixerView(session: session, player: session.player)
                .editorAppearance()
                .onExitCommand { [weak window] in
                    guard window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                    window?.performClose(nil)
                })
        // The resizable window provides the viewport; the ScrollView handles
        // overflowing controls. Do not remeasure minimum/ideal/maximum content
        // sizes on each playback tick or live control adjustment.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.collectionBehavior.insert(.participatesInCycle)
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 540)
        window.center()
        super.init(window: window)
        window.delegate = self
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndFocus() {
        if let projectWindow = session.controller.projectSaveCoordinator?.attachedWindow, projectWindow.isKeyWindow {
            timelineReturn = MixerTimelineReturn.capture(controller: session.controller,
                target: TimelineKeyboardFocus.selection(in: projectWindow, voiceOver: NSWorkspace.shared.isVoiceOverEnabled))
        }
        if let window, let screen = window.screen ?? NSScreen.main {
            window.setFrame(ClipEditorLayout.fitting(window.frame, in: screen.visibleFrame), display: false)
        }
        showWindow(nil)
        if !didArrange, let window {
            AuthoringWindowArrangement.shared.place(window, beside: session.controller.projectSaveCoordinator?.attachedWindow)
            didArrange = true
        }
        window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        onKeyChange?(true)
        ExternalMediaOpenCoordinator.shared.activate(controller: session.controller)
    }
    func windowDidResignKey(_ notification: Notification) {
        session.controller.mixerAdjustmentEditing(false)
        onKeyChange?(false)
    }
    func windowWillClose(_ notification: Notification) {
        AuthoringWindowArrangement.shared.release(window)
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        onKeyChange?(false)
        onKeyChange = nil
        let shouldReturn = returnsToProject && window?.isKeyWindow == true && NSApp.isActive
        let projectWindow = session.controller.projectSaveCoordinator?.attachedWindow
        session.player.endMixerPlayback()
        let completion = onClose
        onClose = nil
        completion?()
        let timelineReturn = timelineReturn
        // AppKit removes the closing window before its document becomes key again.
        Task { @MainActor [weak projectWindow, weak controller = session.controller] in
            await Task.yield()
            guard shouldReturn, let projectWindow, let controller,
                  projectWindow.isVisible, NSApp.isActive,
                  controller.projectSaveCoordinator?.isResolvingClose != true,
                  controller.projectSaveCoordinator?.isApplicationTerminating != true,
                  projectWindow.attachedSheet == nil,
                  NSApp.keyWindow == nil || NSApp.keyWindow === projectWindow else { return }
            projectWindow.makeKeyAndOrderFront(nil)
            timelineReturn?.restore(in: controller)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Resolve these before examining a control's focus or native activation keys.
        if let command = MixerWindowCommand.resolve(keyCode: event.keyCode, modifiers: modifiers, character: event.charactersIgnoringModifiers) {
            switch command {
            case .close: window?.performClose(nil)
            case .save:
                session.controller.mixerAdjustmentEditing(false)
                session.controller.saveProjectDocument()
            case .previousTrack, .nextTrack:
                guard QuitReviewState.shared.coordinator == nil else { return false }
                if !event.isARepeat { session.selectAdjacentTrack(command == .previousTrack ? -1 : 1) }
            }
            return true
        }
        guard QuitReviewState.shared.coordinator == nil else { return false }
        if modifiers == .command {
            switch event.keyCode {
            case 123: session.player.goToPreviousEdit()
            case 124: session.player.goToNextEdit()
            case 126: session.player.goToStart()
            case 125: session.player.goToEnd()
            default: return false
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        if let editor = window?.firstResponder as? NSTextView, editor.isEditable { return false }
        // Native choices and buttons retain their own activation keys.
        let focused = NSApp.accessibilityFocusedUIElement as? NSObject ?? window?.firstResponder
        let role = focused.flatMap { $0.responds(to: NSSelectorFromString("accessibilityRole"))
            ? $0.value(forKey: "accessibilityRole") as? String : nil }
        if ["AXTextField", "AXTextArea", "AXPopUpButton", "AXComboBox", "AXMenu", "AXMenuItem"].contains(role ?? "") { return false }
        if event.keyCode == 49 {
            if ["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role ?? "") { return false }
            if !event.isARepeat { session.togglePlayback() }
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t":
            if !event.isARepeat { session.player.announceCurrentTimecode() }
        case "i": if !event.isARepeat { session.player.markIn() }
        case "o": if !event.isARepeat { session.player.markOut() }
        case "j": session.player.pressJ()
        case "k": session.togglePlayback()
        case "l": session.player.pressL()
        default: return false
        }
        return true
    }
}

/// A captured item is independent of the playhead and keyboard responder.
/// Later workspace navigation supersedes this return destination.
struct MixerTimelineReturn {
    let target: TimelineElementSelection
    let trackID: UUID
    let navigation: WorkspaceFocusRequest

    @MainActor static func capture(controller: ProjectController, target: TimelineElementSelection?) -> Self? {
        guard let target, let trackID = controller.activeTimelineTrack?.id else { return nil }
        return Self(target: target, trackID: trackID, navigation: controller.workspaceNavigation)
    }

    @MainActor func restore(in controller: ProjectController) {
        guard controller.workspaceNavigation == navigation,
              let track = controller.project.track(id: trackID) else { return }
        let exists: Bool
        switch target {
        case .clip(let id): exists = track.clips.contains { $0.id == id }
        case .caption(let id): exists = track.captionCues.contains { $0.id == id }
        case .marker(let id): exists = track.markers.contains { $0.id == id }
        case .transition(let id): exists = controller.project.transitions.contains { $0.id == id }
        }
        guard exists else { return }
        controller.activeTimelineTrackID = trackID
        controller.focusTimelineElement(target)
        controller.requestTimelineFocusRestore(to: target)
    }
}
