import AppKit
import SwiftUI

/// The native cell owns the accessible value, so quiet feedback has no numeric fallback.
struct NativePlayheadSlider: NSViewRepresentable {
    @Binding var value: Double
    let step: Double
    let label: String
    let identifier: String
    let spokenValue: (Double) -> String
    let feedback: TimecodeFeedback
    var isMoving: () -> Bool = { false }
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> PlayheadSlider {
        let slider = PlayheadSlider()
        slider.cell = PlayheadCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: PlayheadSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = isEnabled
        slider.frameStep = step.isFinite && step > 0 ? min(step, 1) : 1
        let fraction = value.isFinite ? min(max(value, 0), 1) : 0
        if slider.doubleValue != fraction { slider.doubleValue = fraction }
        guard let cell = slider.cell as? PlayheadCell else { return }
        cell.updateSpokenValue(format: spokenValue, feedback: feedback, isMoving: isMoving)
        if cell.accessibilityLabel() != label { cell.setAccessibilityLabel(label) }
        if cell.accessibilityIdentifier() != identifier { cell.setAccessibilityIdentifier(identifier) }
    }

    static func dismantleNSView(_ slider: PlayheadSlider, coordinator: Coordinator) {
        (slider.cell as? PlayheadCell)?.cancelPendingValue()
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }

    final class PlayheadSlider: NSSlider {
        var frameStep = 1.0

        func adjustFrame(forward: Bool) -> Bool {
            guard isEnabled else { return false }
            let next = min(max(doubleValue + (forward ? frameStep : -frameStep), minValue), maxValue)
            guard next != doubleValue else { return true }
            (cell as? PlayheadCell)?.beginAdjustment()
            doubleValue = next
            sendAction(action, to: target)
            return true
        }
    }

    final class PlayheadCell: NSSliderCell {
        private var format: (Double) -> String = { _ in "" }
        private var isMoving: () -> Bool = { false }
        private var feedback = TimecodeFeedback.whenStopped
        private var settledValue: String?
        private var lastFraction: Double?
        private var lastFormattedValue: String?
        private var wasMoving = false
        private var pendingValue: Task<Void, Never>?

        func cancelPendingValue() {
            pendingValue?.cancel()
            pendingValue = nil
        }

        func beginAdjustment() {
            cancelPendingValue()
            settledValue = nil
            // Force settlement even if a native action reaches the same fraction.
            lastFraction = nil
        }

        func updateSpokenValue(format: @escaping (Double) -> String,
                               feedback: TimecodeFeedback, isMoving: @escaping () -> Bool) {
            let initial = lastFraction == nil && lastFormattedValue == nil
            let preferenceChanged = self.feedback != feedback
            self.format = format
            self.feedback = feedback
            self.isMoving = isMoving
            let moving = isMoving()
            let fraction = doubleValue
            let formatted = moving ? nil : format(fraction)
            let changed = lastFraction != fraction || lastFormattedValue != formatted
                || wasMoving != moving || preferenceChanged
            lastFraction = fraction
            lastFormattedValue = formatted
            wasMoving = moving
            guard changed else { return }
            cancelPendingValue()
            settledValue = nil
            guard feedback == .whenStopped, !moving else { return }
            if initial || preferenceChanged {
                settledValue = formatted.flatMap { $0.isEmpty ? nil : $0 }
                return
            }
            // Delay only the accessible value, never the native slider or seek action.
            pendingValue = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    // A seek can still be finishing after its last clock update.
                    while self.isMoving() {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    guard !Task.isCancelled, self.feedback == .whenStopped else { return }
                    let value = self.format(self.doubleValue)
                    self.settledValue = value.isEmpty ? nil : value
                    self.pendingValue = nil
                    if self.isAccessibilityFocused(), self.controlView?.window?.isKeyWindow == true {
                        NSAccessibility.post(element: self, notification: .valueChanged)
                    }
                } catch { }
            }
        }

        override func accessibilityValue() -> Any? {
            guard feedback == .whenStopped, !isMoving() else { return nil }
            return settledValue
        }

        override func accessibilityValueDescription() -> String? {
            accessibilityValue() as? String
        }

        override func setAccessibilityValue(_ value: Any?) {
            beginAdjustment()
            super.setAccessibilityValue(value)
        }

        override func accessibilityPerformIncrement() -> Bool {
            (controlView as? PlayheadSlider)?.adjustFrame(forward: true) ?? false
        }

        override func accessibilityPerformDecrement() -> Bool {
            (controlView as? PlayheadSlider)?.adjustFrame(forward: false) ?? false
        }
    }
}
