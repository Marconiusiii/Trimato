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
        if let editor { editor.showAndFocus(); return }
        guard let player = controller.projectPlayer else { return }
        let session = MixerSession(controller: controller, player: player)
        self.session = session
        changes = session.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        let editor = MixerEditorWindowController(session: session)
        self.editor = editor
        editor.onKeyChange = { [weak self] key in self?.isKeyWindow = key }
        editor.onClose = { [weak self] in
            self?.isKeyWindow = false
            self?.editor = nil
            self?.session = nil
            self?.changes = nil
            session.close()
        }
        editor.showAndFocus()
    }
    func close(for controller: ProjectController) {
        guard session?.controller === controller else { return }
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

    init(session: MixerSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mixer"
        window.contentViewController = NSHostingController(rootView:
            MixerView(session: session, player: session.player)
                .onExitCommand { [weak window] in
                    guard window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                    window?.performClose(nil)
                })
        window.collectionBehavior.insert(.participatesInCycle)
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
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
        if let window, let screen = window.screen ?? NSScreen.main {
            window.setFrame(ClipEditorLayout.fitting(window.frame, in: screen.visibleFrame), display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        onKeyChange?(true)
        ExternalMediaOpenCoordinator.shared.activate(controller: session.controller)
    }
    func windowDidResignKey(_ notification: Notification) { onKeyChange?(false) }
    func windowWillClose(_ notification: Notification) {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        session.player.stopMixerPlayback()
        onClose?(); onClose = nil
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
        case "j": session.player.pressJ()
        case "k": session.player.pressK()
        case "l": session.player.pressL()
        default: return false
        }
        return true
    }
}
