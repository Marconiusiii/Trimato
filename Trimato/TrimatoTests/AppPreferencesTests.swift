import Foundation
import Testing
@testable import Trimato

@Suite("App preferences", .serialized)
struct AppPreferencesTests {
    @Test func autoSaveIsOptInAndUsesValidWholeMinuteIntervals() throws {
        let name = "AutoSavePreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences.autoSaveInterval(in: defaults) == 0)
        defaults.set(true, forKey: AppPreferenceKey.autoSaveEnabled)
        #expect(AppPreferences.autoSaveInterval(in: defaults) == 300)
        for invalid in [0, -1, 121, Int.max] {
            defaults.set(invalid, forKey: AppPreferenceKey.autoSaveMinutes)
            #expect(AppPreferences.autoSaveInterval(in: defaults) == 300)
        }
        defaults.set(2, forKey: AppPreferenceKey.autoSaveMinutes)
        #expect(AppPreferences.autoSaveInterval(in: defaults) == 120)
        defaults.set(false, forKey: AppPreferenceKey.autoSaveEnabled)
        #expect(AppPreferences.autoSaveInterval(in: defaults) == 0)
    }

    @Test func recordingQualityDefaultsTo24BitAndRejectsInvalidPreferences() throws {
        let name = "AudioQualityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences.audioRecordingBitDepth(in: defaults) == 24)
        defaults.set(8, forKey: AppPreferenceKey.audioRecordingBitDepth)
        #expect(AppPreferences.audioRecordingBitDepth(in: defaults) == 24)
        defaults.set(16, forKey: AppPreferenceKey.audioRecordingBitDepth)
        #expect(AppPreferences.audioRecordingBitDepth(in: defaults) == 16)
    }

    @Test func precisionTimecodeDefaultsOnAndCanBeDisabled() throws {
        let name = "PrecisionTimecodeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences.precisionTimecode(in: defaults))
        defaults.set(false, forKey: AppPreferenceKey.precisionTimecode)
        #expect(!AppPreferences.precisionTimecode(in: defaults))
        defaults.set(true, forKey: AppPreferenceKey.precisionTimecode)
        #expect(AppPreferences.precisionTimecode(in: defaults))
    }

    @Test func passiveCountersUseCompletedSecondsWithoutChangingPreciseTimes() throws {
        for (seconds, simplified, precise) in [
            (0.0, "00:00", "00:00.000"),
            (1.25, "00:01", "00:01.250"),
            (59.999, "00:59", "00:59.999"),
            (60.0, "01:00", "01:00.000"),
            (3599.999, "59:59", "59:59.999"),
            (3600.0, "01:00:00", "01:00:00.000"),
            (3661.042, "01:01:01", "01:01:01.042")
        ] {
            #expect(AppPreferences.passiveTimecode(seconds: seconds, precision: false) == simplified)
            #expect(AppPreferences.passiveTimecode(seconds: seconds, precision: true) == precise)
            #expect(RecordingTimeFormat().format(seconds) == precise)
            #expect(abs(try RecordingTimeFormat().parseStrategy.parse(precise) - seconds) < 0.000_001)
        }
        for invalid in [-1.0, Double.nan, Double.infinity] {
            #expect(AppPreferences.passiveTimecode(seconds: invalid, precision: false) == "00:00")
        }
    }

    @Test func timecodeChoicesStayInTheSettingsOrder() {
        #expect(TimecodeFeedback.allCases == [.whenStopped, .onDemand])
        #expect(TimecodeStyle.allCases == [.numeric, .timeUnits, .frames])
    }

    @Test func missingOrInvalidTimecodePreferencesUseTheDefaults() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppPreferences.timecodeFeedback(in: defaults) == .whenStopped)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .default)

        defaults.set("unknown", forKey: AppPreferenceKey.timecodeFeedback)
        defaults.set("unknown", forKey: AppPreferenceKey.timecodeVerbosity)
        #expect(AppPreferences.timecodeFeedback(in: defaults) == .whenStopped)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .default)

        for (raw, expected) in [("live", TimecodeFeedback.whenStopped), ("off", .onDemand),
                                ("whenStopped", .whenStopped), ("onDemand", .onDemand)] {
            defaults.set(raw, forKey: AppPreferenceKey.timecodeFeedback)
            #expect(AppPreferences.timecodeFeedback(in: defaults) == expected)
            #expect(TimecodeFeedback(rawValue: expected.rawValue) == expected)
        }
        defaults.set(TimecodeFeedback.onDemand.rawValue, forKey: AppPreferenceKey.timecodeFeedback)
        defaults.set(TimecodeVerbosity.frames.rawValue, forKey: AppPreferenceKey.timecodeVerbosity)
        #expect(AppPreferences.timecodeFeedback(in: defaults) == .onDemand)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .frames)
    }

    @Test func timecodeStyleMigratesAndExplicitChoiceWins() throws {
        let name = "TimecodeStyleTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences.timecodeStyle(in: defaults) == .timeUnits)
        for legacy in TimecodeVerbosity.allCases {
            defaults.set(legacy.rawValue, forKey: AppPreferenceKey.timecodeVerbosity)
            #expect(AppPreferences.timecodeStyle(in: defaults) == (legacy == .frames ? .frames : .timeUnits))
        }
        defaults.set(TimecodeStyle.numeric.rawValue, forKey: AppPreferenceKey.timecodeStyle)
        #expect(AppPreferences.timecodeStyle(in: defaults) == .numeric)
    }

    @Test func timecodeStylesAndFeedbackHaveSeparateScopes() {
        for milliseconds in [false, true] {
            #expect(AppPreferences.spokenTimecode(seconds: 3842.344, frameRate: 24, milliseconds: milliseconds, style: .numeric)
                == (milliseconds ? "01:04:02.344" : "01:04:02"))
            #expect(AppPreferences.spokenTimecode(seconds: 3842.344, frameRate: 24, milliseconds: milliseconds, style: .timeUnits)
                == (milliseconds ? "1 hour, 4 minutes, 2 seconds, 344 milliseconds" : "1 hour, 4 minutes, 2 seconds"))
            #expect(AppPreferences.spokenTimecode(seconds: 1.5, frameRate: 24, milliseconds: milliseconds, style: .frames) == "Frame 36")
        }
        for feedback in TimecodeFeedback.allCases {
            #expect(AppPreferences.playheadValue("1 second", feedback: feedback) == (feedback == .whenStopped ? "1 second" : ""))
        }
        #expect(AppPreferences.spokenTimecode(seconds: 4500, frameRate: 30, milliseconds: true, style: .timeUnits) == "1 hour, 15 minutes")
        #expect(AppPreferences.spokenTimecode(seconds: 0, frameRate: 30, milliseconds: true, style: .timeUnits) == "0 seconds")
        #expect(AppPreferences.spokenTimecode(seconds: 59.9996, frameRate: 30, milliseconds: true, style: .timeUnits) == "1 minute")
    }

    @Test func defaultTimecodeSpeaksMillisecondsAsAUnit() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 3_661.042,
            frameRate: 30,
            verbosity: .default, milliseconds: true
        ) == "1 hour, 1 minute, 1 second, 42 milliseconds")
    }

    @Test func legacyShortTimecodeUsesExplicitMillisecondUnits() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 35.44,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "35 seconds, 440 milliseconds")
    }

    @Test func timeUnitsIncludeMinutesAndHours() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 63.4,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "1 minute, 3 seconds, 400 milliseconds")
        #expect(AppPreferences.spokenTimecode(
            seconds: 3_663.4,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "1 hour, 1 minute, 3 seconds, 400 milliseconds")
    }

    @Test func frameTimecodeUsesTheCurrentFrameRate() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 1.5,
            frameRate: 30,
            verbosity: .frames
        ) == "Frame 45")
    }
}
