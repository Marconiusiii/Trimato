import AppKit
import SwiftUI

struct MixerPlayheadSlider: View {
    @Binding var value: Double
    let step: Double
    let timecode: String
    let ready: Bool
    let playing: Bool
    var focusRevision = 0
    @Environment(\.controlActiveState) private var windowActivity
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @State private var needsInitialFocus = true

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
        .onChange(of: focusRevision) { _, _ in
            keyboardFocused = true
            voiceOverFocused = true
        }
        .task(id: ready && windowActivity == .key) {
            guard needsInitialFocus, ready, windowActivity == .key else { return }
            // Allow the native slider to join the active window before focusing it.
            await Task.yield()
            guard !Task.isCancelled, let application = NSApp, application.isActive,
                  application.keyWindow?.attachedSheet == nil,
                  application.modalWindow == nil else { return }
            needsInitialFocus = false
            keyboardFocused = true
            voiceOverFocused = true
        }
    }
}
