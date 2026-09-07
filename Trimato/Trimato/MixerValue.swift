import Foundation

nonisolated enum MixerValue {
    static func decibels(_ value: Double) -> String { String(format: "%.1f dB", value) }
    static func position(_ value: Double) -> String {
        abs(value) < 0.005 ? "Center" : "\(Int((abs(value) * 100).rounded())) percent \(value < 0 ? "left" : "right")"
    }
    static func width(_ value: Double) -> String {
        if value == 0 { return "Mono" }
        if value == 1 { return "Original" }
        return "\(Int((value * 100).rounded())) percent"
    }
}


