import Foundation

nonisolated enum AppPreferenceKey {
    static let processingSounds = "processingSounds"
    static let exportCompletionSound = "exportCompletionSound"
    static let preserveHDR = "preserveHDR"
    static let appearance = "appearance"
    static let importedFileHandling = "importedFileHandling"
    static let autoSaveEnabled = "autoSaveEnabled"
    static let autoSaveMinutes = "autoSaveMinutes"
    static let audioInputDevice = "audioInputDevice"
    static let audioOutputDevice = "audioOutputDevice"
    static let audioInputChannel = "audioInputChannel"
    static let audioRecordingBitDepth = "audioRecordingBitDepth"
    static let timecodeFeedback = "timecodeFeedback"
    static let timecodeVerbosity = "timecodeVerbosity"
}

nonisolated enum TimecodeFeedback: String, CaseIterable, Identifiable, Sendable {
    case live
    case onDemand
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .onDemand: "On Demand"
        case .off: "Off"
        }
    }
}

nonisolated enum TimecodeVerbosity: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case short
    case frames

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: "Default"
        case .short: "Short"
        case .frames: "Frames"
        }
    }
}

nonisolated enum AppPreferences {
    static func preserveHDR(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppPreferenceKey.preserveHDR) as? Bool ?? true
    }

    static let defaultAutoSaveMinutes = 5
    static let autoSaveMinutesRange = 1...120

    static func autoSaveMinutes(in defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.integer(forKey: AppPreferenceKey.autoSaveMinutes)
        return autoSaveMinutesRange.contains(minutes) ? minutes : defaultAutoSaveMinutes
    }

    static func autoSaveInterval(in defaults: UserDefaults = .standard) -> TimeInterval {
        defaults.bool(forKey: AppPreferenceKey.autoSaveEnabled)
            ? TimeInterval(autoSaveMinutes(in: defaults) * 60) : 0
    }

    static func audioRecordingBitDepth(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: AppPreferenceKey.audioRecordingBitDepth) == 16 ? 16 : 24
    }

    static var timecodeFeedback: TimecodeFeedback {
        timecodeFeedback(in: .standard)
    }

    static var timecodeVerbosity: TimecodeVerbosity {
        timecodeVerbosity(in: .standard)
    }

    static func timecodeFeedback(in defaults: UserDefaults) -> TimecodeFeedback {
        TimecodeFeedback(rawValue: defaults.string(
            forKey: AppPreferenceKey.timecodeFeedback
        ) ?? "") ?? .live
    }

    static func timecodeVerbosity(in defaults: UserDefaults) -> TimecodeVerbosity {
        TimecodeVerbosity(rawValue: defaults.string(
            forKey: AppPreferenceKey.timecodeVerbosity
        ) ?? "") ?? .default
    }

    static func spokenTimecode(
        seconds rawSeconds: Double,
        frameRate rawFrameRate: Double,
        verbosity: TimecodeVerbosity? = nil
    ) -> String {
        let seconds = rawSeconds.isFinite ? max(rawSeconds, 0) : 0
        let frameRate = rawFrameRate.isFinite ? max(rawFrameRate, 1) : 30
        switch verbosity ?? timecodeVerbosity {
        case .default:
            return fullTimecode(seconds: seconds)
        case .short:
            return shortTimecode(seconds: seconds)
        case .frames:
            let frame = max(Int((seconds * frameRate).rounded(.towardZero)), 0)
            return "Frame \(frame)"
        }
    }

    private static func fullTimecode(seconds: Double) -> String {
        let milliseconds = max(Int((seconds * 1_000).rounded()), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        var components: [String] = []
        if hours > 0 { components.append(unit(hours, singular: "hour")) }
        if minutes > 0 { components.append(unit(minutes, singular: "minute")) }
        components.append(unit(wholeSeconds, singular: "second"))
        components.append(unit(remainder, singular: "millisecond"))
        return components.joined(separator: ", ")
    }

    private static func shortTimecode(seconds: Double) -> String {
        if seconds < 60 {
            let tenths = Int((seconds * 10).rounded())
            if tenths % 10 == 0 {
                return unit(tenths / 10, singular: "second")
            }
            let value = String(format: "%.1f", Double(tenths) / 10)
            return "\(value) seconds"
        }

        let totalSeconds = max(Int(seconds.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds / 60) % 60
        let remainder = totalSeconds % 60
        var components: [String] = []
        if hours > 0 { components.append(unit(hours, singular: "hour")) }
        if minutes > 0 { components.append(unit(minutes, singular: "minute")) }
        if remainder > 0 || components.isEmpty {
            components.append(unit(remainder, singular: "second"))
        }
        return components.joined(separator: ", ")
    }

    private static func unit(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}
