import Foundation

nonisolated enum AppPreferenceKey {
    static let markerAudio = "markerAudio"
    static let processingSounds = "processingSounds"
    static let exportCompletionSound = "exportCompletionSound"
    static let preserveHDR = "preserveHDR"
    static let showAudioWaveforms = "showAudioWaveforms"
    static let appearance = "appearance"
    static let portraitVideo = "portraitVideo"
    static let accentColor = "accentColor"
    static let importedFileHandling = "importedFileHandling"
    static let autoSaveEnabled = "autoSaveEnabled"
    static let autoSaveMinutes = "autoSaveMinutes"
    static let audioInputDevice = "audioInputDevice"
    static let audioOutputDevice = "audioOutputDevice"
    static let audioInputChannel = "audioInputChannel"
    static let audioRecordingBitDepth = "audioRecordingBitDepth"
    static let timecodeFeedback = "timecodeFeedback"
    static let timecodeVerbosity = "timecodeVerbosity"
    static let timecodeStyle = "timecodeStyle"
    // Keep the persisted key so existing preferences survive the label change.
    static let showMilliseconds = "precisionTimecode"
    static let precisionTimecode = showMilliseconds
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

nonisolated enum TimecodeStyle: String, CaseIterable, Identifiable, Sendable {
    case numeric, timeUnits, frames
    var id: String { rawValue }
    var title: String {
        switch self {
        case .numeric: "Numeric"
        case .timeUnits: "Time units"
        case .frames: "Frames"
        }
    }
}

nonisolated enum AppPreferences {
    static func showAudioWaveforms(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.showAudioWaveforms)
    }

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

    static func showMilliseconds(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppPreferenceKey.precisionTimecode) as? Bool ?? true
    }

    static func precisionTimecode(in defaults: UserDefaults = .standard) -> Bool {
        showMilliseconds(in: defaults)
    }

    /// Presentation only: never use the whole-second result to update an edit boundary.
    static func passiveTimecode(seconds: Double, precision: Bool = showMilliseconds()) -> String {
        let safeSeconds = seconds.isFinite ? min(max(seconds, 0), 359_999_999) : 0
        if precision {
            let milliseconds = Int64((safeSeconds * 1_000).rounded())
            return String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000,
                          milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
        }
        let wholeSeconds = Int64(safeSeconds.rounded(.down))
        return String(format: "%02lld:%02lld:%02lld", wholeSeconds / 3_600,
                      wholeSeconds / 60 % 60, wholeSeconds % 60)
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

    static var timecodeStyle: TimecodeStyle { timecodeStyle(in: .standard) }

    static func timecodeStyle(in defaults: UserDefaults) -> TimecodeStyle {
        if let raw = defaults.string(forKey: AppPreferenceKey.timecodeStyle), let style = TimecodeStyle(rawValue: raw) {
            return style
        }
        return timecodeVerbosity(in: defaults) == .frames ? .frames : .timeUnits
    }

    static func playheadValue(_ value: String, feedback: TimecodeFeedback? = nil) -> String {
        (feedback ?? timecodeFeedback) == .live ? value : ""
    }

    static func displayTimecode(seconds: Double, frame: Int, milliseconds: Bool, style: TimecodeStyle? = nil) -> String {
        switch style ?? timecodeStyle {
        case .numeric: return passiveTimecode(seconds: seconds, precision: milliseconds)
        case .timeUnits: return spokenTimecode(seconds: seconds, frameRate: 30, milliseconds: milliseconds, style: .timeUnits)
        case .frames: return "Frame \(frame)"
        }
    }

    static func spokenTimecode(
        seconds rawSeconds: Double,
        frameRate rawFrameRate: Double,
        verbosity: TimecodeVerbosity? = nil,
        milliseconds: Bool? = nil,
        style: TimecodeStyle? = nil
    ) -> String {
        let seconds = rawSeconds.isFinite ? min(max(rawSeconds, 0), 359_999_999) : 0
        let precise = milliseconds ?? showMilliseconds()
        let frameRate = rawFrameRate.isFinite ? max(rawFrameRate, 1) : 30
        let selectedStyle = style ?? verbosity.map { $0 == .frames ? TimecodeStyle.frames : .timeUnits } ?? timecodeStyle
        switch selectedStyle {
        case .numeric:
            return passiveTimecode(seconds: seconds, precision: precise)
        case .timeUnits:
            return fullTimecode(seconds: seconds, milliseconds: precise)
        case .frames:
            let frame = max(Int((seconds * frameRate).rounded(.towardZero)), 0)
            return "Frame \(frame)"
        }
    }

    private static func fullTimecode(seconds: Double, milliseconds showMilliseconds: Bool) -> String {
        let milliseconds = showMilliseconds ? Int((seconds * 1_000).rounded()) : Int(seconds.rounded(.down)) * 1_000
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        var components: [String] = []
        if hours > 0 { components.append(unit(hours, singular: "hour")) }
        if minutes > 0 { components.append(unit(minutes, singular: "minute")) }
        if wholeSeconds > 0 || components.isEmpty && remainder == 0 {
            components.append(unit(wholeSeconds, singular: "second"))
        }
        if showMilliseconds && remainder > 0 { components.append(unit(remainder, singular: "millisecond")) }
        return components.joined(separator: ", ")
    }

    private static func unit(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

/// Only explicit formatting preference changes invalidate cached accessibility values.
nonisolated struct TimecodePresentationPreference: Equatable {
    var milliseconds = AppPreferences.showMilliseconds()
    var style = AppPreferences.timecodeStyle
    var feedback = AppPreferences.timecodeFeedback
}
