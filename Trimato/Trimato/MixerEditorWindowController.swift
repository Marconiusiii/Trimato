import AppKit
import Combine
import SwiftUI

@MainActor
final class MixerWindowRegistry: ObservableObject {
    static let shared = MixerWindowRegistry()
    @Published private(set) var session: MixerSession?
    private var changes: AnyCancellable?
    private var keyboardMonitor: Any?
    private var presentationID = UUID()
    weak var focusScope: EditorAccessibilityFocusScope?
    private var window: NSWindow? { session?.controller.projectSaveCoordinator?.attachedWindow }
    var activeSession: MixerSession? { window?.isKeyWindow == true ? session : nil }

    func open(controller: ProjectController) {
        TimelineFocusDiagnostics.record("mixer-open-request existing=\(controller.toolPane == .mixer) revision=\(controller.toolFocusRevision) \(TimelineFocusDiagnostics.windowState(controller.projectSaveCoordinator?.attachedWindow))")
        let origin = TimelineKeyboardFocus.mixerOrigin(in: controller.projectSaveCoordinator?.attachedWindow,
                                                       trackID: controller.activeTimelineTrack?.id)
        controller.openToolPane(.mixer) { [weak self, weak controller] in
            guard let self, let controller, let player = controller.projectPlayer else { return }
            self.presentationID = UUID()
            let session = MixerSession(controller: controller, player: player, origin: origin)
            self.session = session
            TimelineFocusDiagnostics.record("mixer-session-created ready=\(player.canControlPlayback) revision=\(controller.toolFocusRevision)")
            changes = session.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          window.isKeyWindow, window.attachedSheet == nil,
                          self.focusScope?.containsInputFocus == true else { return event }
                    return self.handle(event) ? nil : event
                }
            }
        }
    }

    func prepareForEntry(controller: ProjectController) {
        guard let session, session.controller === controller else { return }
        let navigation = controller.workspaceNavigation
        var origin = TimelineKeyboardFocus.mixerOrigin(in: controller.projectSaveCoordinator?.attachedWindow,
                                                       trackID: controller.activeTimelineTrack?.id)
        var insideMixer = focusScope?.containsInputFocus == true
        if case .editor = origin, focusScope?.containsKeyboardFocus == true {
            insideMixer = true
        }
        // A requested Timeline destination takes precedence over a late Mixer
        // observation. Preserve an observed Timeline item when one is available.
        if navigation.pane == .timeline, case .editor = origin {
            origin = .timeline(trackID: controller.activeTimelineTrack?.id, item: nil)
        }
        session.updateReturnOrigin(origin, enteringFromMixer: insideMixer && navigation.pane == .tool)
        TimelineFocusDiagnostics.record("mixer-return-origin \(session.origin) navigation=\(navigation)")
    }

    func close(for controller: ProjectController) {
        guard let closing = session, closing.controller === controller else { return }
        TimelineFocusDiagnostics.record("mixer-close \(TimelineFocusDiagnostics.windowState(window))")
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        focusScope = nil
        session = nil
        changes = nil
        closing.player.stopMixerPlayback()
        if controller.toolPane == .mixer { controller.toolPane = nil }
        closing.close(restoreFocus: false)
        let request = MixerReturnRequest(controller)
        let presentationID = self.presentationID
        Task { @MainActor [weak self, weak controller] in
            await Task.yield()
            guard let self, let controller, self.presentationID == presentationID,
                  self.session == nil, request.isCurrent(in: controller) else { return }
            closing.restoreOriginFocus()
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Resolve these before examining a control's focus or native activation keys.
        if let command = MixerWindowCommand.resolve(keyCode: event.keyCode, modifiers: modifiers, character: event.charactersIgnoringModifiers) {
            switch command {
            case .close: session.controller.requestCloseToolPane()
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
        case "j": session.player.pressJ()
        case "k": session.player.pressK()
        case "l": session.player.pressL()
        default: return false
        }
        return true
    }
}
