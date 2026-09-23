import AppKit
import SwiftUI

struct MixerPlayheadSlider: View {
    @Binding var value: Double
    let step: Double
    let timecode: String
    let ready: Bool
    let playing: Bool
    var focusRevision = 0
    let navigation: WorkspaceFocusRequest
    let session: MixerSession
    @Environment(\.controlActiveState) private var windowActivity
    @State private var issuedRequest: WorkspaceFocusRequest?
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool

    var body: some View {
        // An inline Slider label makes macOS lay out labels for its frame steps.
        // Native LabeledContent keeps the label associated without that work.
        LabeledContent("Project playhead") {
            Slider(value: $value, in: 0...1, step: step)
                .accessibilityValue(timecode)
                .accessibilityAddTraits(playing ? .updatesFrequently : [])
                .accessibilityIdentifier("trimato.mixer.playhead")
                .focused($keyboardFocused)
                .accessibilityFocused($voiceOverFocused)
        }
        .onChange(of: navigation) { _, request in
            guard request.pane != .tool else { return }
            // Withdraw this destination before a newer pane request is applied.
            keyboardFocused = false
            voiceOverFocused = false
        }
        .task(id: ready && windowActivity == .key && navigation.pane == .tool ? navigation : nil) {
            let request = navigation
            guard ready, windowActivity == .key, request.pane == .tool, issuedRequest != request else { return }
            await Task.yield()
            guard !Task.isCancelled, session.controller.workspaceNavigation == request,
                  session.controller.toolPane == .mixer,
                  let window = session.controller.projectSaveCoordinator?.attachedWindow,
                  window.isKeyWindow, NSApp?.isActive == true,
                  window.attachedSheet == nil, NSApp?.modalWindow == nil else { return }
            issuedRequest = request
            recordFocus("entry-request")
            keyboardFocused = true
            voiceOverFocused = true
        }
        .onChange(of: keyboardFocused) { _, _ in recordFocus("keyboard-observed") }
        .onChange(of: voiceOverFocused) { _, _ in recordFocus("voiceover-observed") }
    }

    private func recordFocus(_ event: String) {
        #if DEBUG
        TimelineFocusDiagnostics.record("mixer-slider \(event) revision=\(focusRevision) ready=\(ready) activity=\(windowActivity) keyboard=\(keyboardFocused) voiceOver=\(voiceOverFocused) active=\(NSApp?.isActive == true) modal=\(NSApp?.modalWindow != nil) \(TimelineFocusDiagnostics.windowState(NSApp?.keyWindow))")
        #endif
    }
}
