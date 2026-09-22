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
    var keyboardFocus: FocusState<Bool>.Binding
    #if DEBUG
    @AccessibilityFocusState(for: .voiceOver) private var observedVoiceOverFocus: Bool
    #endif

    var body: some View {
        // An inline Slider label makes macOS lay out labels for its frame steps.
        // Native LabeledContent keeps the label associated without that work.
        LabeledContent("Project playhead") {
            Slider(value: $value, in: 0...1, step: step)
                .accessibilityValue(timecode)
                .accessibilityAddTraits(playing ? .updatesFrequently : [])
                .accessibilityIdentifier("trimato.mixer.playhead")
                .focused(keyboardFocus)
                #if DEBUG
                .accessibilityFocused($observedVoiceOverFocus)
                .onChange(of: observedVoiceOverFocus) { _, focused in
                    recordFocus("voiceover-observed=\(focused)")
                }
                #endif
        }
        .onAppear { recordFocus("appear") }
        .onDisappear { recordFocus("disappear") }
        .onChange(of: ready) { _, _ in recordFocus("readiness-changed") }
        .onChange(of: windowActivity) { _, _ in recordFocus("window-activity-changed") }
        .onChange(of: keyboardFocus.wrappedValue) { _, _ in recordFocus("keyboard-observed") }

    }

    private func recordFocus(_ event: String) {
        #if DEBUG
        TimelineFocusDiagnostics.record("mixer-slider \(event) revision=\(focusRevision) ready=\(ready) activity=\(windowActivity) keyboard=\(keyboardFocus.wrappedValue) voiceOver=\(observedVoiceOverFocus) active=\(NSApp?.isActive == true) modal=\(NSApp?.modalWindow != nil) \(TimelineFocusDiagnostics.windowState(NSApp?.keyWindow))")
        #endif
    }
}
