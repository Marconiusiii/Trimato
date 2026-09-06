import Foundation

/// Native text-field formatting: seconds or colon-separated time in, millisecond timecode out.
nonisolated struct RecordingTimeFormat: ParseableFormatStyle {
    var parseStrategy = Strategy()

    func format(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 360_000_000 else { return "00:00:00.000" }
        let milliseconds = Int64((value * 1_000).rounded())
        return String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    struct Strategy: ParseStrategy {
        func parse(_ value: String) throws -> Double {
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
