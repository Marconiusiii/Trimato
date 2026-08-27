import SwiftUI

nonisolated enum TransitionDurationInput {
    static let defaultText = "1.0"

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
}

struct TransitionDurationField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Duration")
                .accessibilityHidden(true)
            TextField(text: $text) {
                Text("Duration")
            }
            .labelsHidden()
            .accessibilityLabel("Duration")
            .accessibilityValue(accessibilityValue)
            Text("seconds")
                .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "No value" : "\(value) seconds"
    }
}
