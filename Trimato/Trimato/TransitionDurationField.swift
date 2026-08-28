import AppKit
import SwiftUI

nonisolated enum TransitionDurationInput {
    static let defaultText = "1.0"
    static let accessibilityLabel = "Duration in Seconds"

    static func parse(_ text: String) -> ProjectTime? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let seconds = Double(trimmed),
              seconds.isFinite,
              seconds > 0 else { return nil }
        return ProjectTime(seconds: seconds)
    }

    static func string(for duration: ProjectTime) -> String {
        let seconds = duration.seconds
        if seconds.rounded() == seconds {
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func accessibilityValue(for text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "No value" : "\(value) seconds"
    }
}

struct TransitionDurationField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Duration")
                .accessibilityHidden(true)
            TransitionDurationTextField(text: $text)
            Text("seconds")
                .accessibilityHidden(true)
        }
    }
}

private struct TransitionDurationTextField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(TransitionDurationInput.accessibilityLabel)
        updateAccessibilityValueDescription(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        updateAccessibilityValueDescription(for: field)
    }

    private func updateAccessibilityValueDescription(for field: NSTextField) {
        field.setAccessibilityValueDescription(TransitionDurationInput.accessibilityValue(for: field.stringValue))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            field.setAccessibilityValueDescription(TransitionDurationInput.accessibilityValue(for: field.stringValue))
        }
    }
}
