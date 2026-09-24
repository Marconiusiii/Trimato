import AppKit
import SwiftUI

struct MixerPlayheadSlider: View {
    @AppStorage(AppPreferenceKey.timecodeFeedback) private var feedback = TimecodeFeedback.whenStopped
    @Binding var value: Double
    let step: Double
    let timecode: (Double) -> String
    let ready: Bool
    let playing: Bool
    var isMoving: () -> Bool = { false }
    @Environment(\.controlActiveState) private var windowActivity
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @State private var needsInitialFocus = true

    var body: some View {
        LabeledContent("Project playhead") {
            NativePlayheadSlider(value: $value, step: step, label: "Project playhead",
                identifier: "trimato.mixer.playhead", spokenValue: timecode, feedback: feedback, isMoving: { playing || isMoving() })
                .disabled(!ready)
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
    }
}
