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
    var label: String = TransitionDurationInput.accessibilityLabel

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .labelsHidden()
        }
    }
}
