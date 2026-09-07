import SwiftUI

/// A native slider with a bounded tick count and native VoiceOver arrow actions.
struct AudioValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let identifier: String
    let spokenValue: ((Double) -> String)?
    let onEditingChanged: (Bool) -> Void
    @StateObject private var keyboard: SettingsSliderKeyboard
    init(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String, identifier: String, spokenValue: ((Double) -> String)? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.spokenValue = spokenValue; self.onEditingChanged = onEditingChanged
        self.label = label; _value = value; self.range = range; self.step = step; self.unit = unit; self.identifier = identifier
        _keyboard = StateObject(wrappedValue: SettingsSliderKeyboard(identifier: identifier))
    }
    var body: some View {
        HStack {
        Slider(value: $value, in: range, step: max(step, (range.upperBound - range.lowerBound) / 200), onEditingChanged: onEditingChanged) { Text(label) }
            .accessibilityValue((spokenValue?(value) ?? String(format: "%.1f %@", value, unit)))
            .accessibilityIdentifier(identifier)
            .onAppear { keyboard.start() }
            .onDisappear { keyboard.stop() }
        Text((spokenValue?(value) ?? String(format: "%.1f %@", value, unit))).monospacedDigit().accessibilityHidden(true)
        }
    }
}

