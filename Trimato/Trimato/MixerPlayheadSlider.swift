import AppKit
import SwiftUI

struct MixerPlayheadSlider: View {
    @Binding var value: Double
    let step: Double
    let timecode: String
    let ready: Bool
    let playing: Bool
    @State private var readout = ProjectPlayheadReadout()
    @Environment(\.controlActiveState) private var windowActivity
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @State private var needsInitialFocus = true

    var body: some View {
        // An inline Slider label makes macOS lay out labels for its frame steps.
        // Native LabeledContent keeps the label associated without that work.
        LabeledContent("Project playhead") {
            Slider(value: $value, in: 0...1, step: step)
                .accessibilityValue(readout.value.isEmpty ? timecode : readout.value)
                .accessibilityAddTraits(playing ? .updatesFrequently : [])
                .accessibilityIdentifier("trimato.mixer.playhead")
                .focused($keyboardFocused)
                .accessibilityFocused($voiceOverFocused)
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
        .onChange(of: voiceOverFocused) { _, focused in
            readout.setFocused(focused)
        }
        .onChange(of: timecode, initial: true) { _, value in
            readout.update(value, playing: playing)
        }
        .onChange(of: playing) { _, playing in
            readout.update(timecode, playing: playing)
        }
    }
}

/// Prepare while away; entering focus never changes the value VoiceOver just read.
nonisolated struct ProjectPlayheadReadout {
    private(set) var value = ""
    private var latest = ""
    private var focused = false

    mutating func update(_ current: String, playing: Bool) {
        latest = current
        if value.isEmpty || !focused || !playing { value = current }
    }

    mutating func setFocused(_ focused: Bool) {
        self.focused = focused
        if !focused { value = latest }
    }
}
