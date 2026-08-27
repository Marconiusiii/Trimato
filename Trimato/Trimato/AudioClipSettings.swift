import Foundation

nonisolated struct AudioClipSettings: Codable, Equatable, Hashable, Sendable {
    static let neutral = AudioClipSettings()

    var gainDecibels = 0.0
    var lowGainDecibels = 0.0
    var midGainDecibels = 0.0
    var highGainDecibels = 0.0
    var highPassEnabled = false
    var highPassFrequency = 80.0
    var lowPassEnabled = false
    var lowPassFrequency = 16_000.0

    var isNeutral: Bool {
        gainDecibels == 0 &&
            lowGainDecibels == 0 &&
            midGainDecibels == 0 &&
            highGainDecibels == 0 &&
            !highPassEnabled &&
            !lowPassEnabled
    }
}
