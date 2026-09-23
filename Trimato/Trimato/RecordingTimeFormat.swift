import Foundation

/// Native time-field formatting preserves hidden fractions when the displayed text is unchanged.
nonisolated struct RecordingTimeFormat: ParseableFormatStyle {
    var milliseconds: Bool = true
    var originalValue: Double? = nil

    var parseStrategy: Strategy {
        Strategy(unchangedText: originalValue.map(format), originalValue: originalValue)
    }

    func format(_ value: Double) -> String {
        AppPreferences.passiveTimecode(seconds: value, precision: milliseconds)
    }

    struct Strategy: ParseStrategy {
        var unchangedText: String? = nil
        var originalValue: Double? = nil
        func parse(_ value: String) throws -> Double {
            if let originalValue, value.trimmingCharacters(in: .whitespacesAndNewlines) == unchangedText {
                return originalValue
            }
            let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { throw CocoaError(.formatting) }
            var result = 0.0
            for (index, part) in parts.enumerated() {
                guard let number = Double(part), number.isFinite, number >= 0,
                      (index == 0 || number < 60),
                      (index == parts.count - 1 || number.rounded() == number) else { throw CocoaError(.formatting) }
                result = result * 60 + number
            }
            guard result.isFinite, result < 360_000_000 else { throw CocoaError(.formatting) }
            return result
        }
    }
}
