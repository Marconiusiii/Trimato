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
            (0.0, "0:00", "00:00:00.000"),
            (1.25, "0:01", "00:00:01.250"),
            (59.999, "0:59", "00:00:59.999"),
            (60.0, "1:00", "00:01:00.000"),
            (3599.999, "59:59", "00:59:59.999"),
            (3600.0, "1:00:00", "01:00:00.000"),
            (3661.042, "1:01:01", "01:01:01.042")
        ] {
            #expect(AppPreferences.passiveTimecode(seconds: seconds, precision: false) == simplified)
            #expect(AppPreferences.passiveTimecode(seconds: seconds, precision: true) == precise)
            #expect(RecordingTimeFormat().format(seconds) == precise)
            #expect(abs(try RecordingTimeFormat().parseStrategy.parse(precise) - seconds) < 0.000_001)
        }
        for invalid in [-1.0, Double.nan, Double.infinity] {
            #expect(AppPreferences.passiveTimecode(seconds: invalid, precision: false) == "0:00")
        }
    }

    @Test func timecodeChoicesStayInTheSettingsOrder() {
        #expect(TimecodeFeedback.allCases == [.live, .onDemand, .off])
        #expect(TimecodeVerbosity.allCases == [.default, .short, .frames])
    }

    @Test func missingOrInvalidTimecodePreferencesUseTheDefaults() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppPreferences.timecodeFeedback(in: defaults) == .live)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .default)

        defaults.set("unknown", forKey: AppPreferenceKey.timecodeFeedback)
        defaults.set("unknown", forKey: AppPreferenceKey.timecodeVerbosity)
        #expect(AppPreferences.timecodeFeedback(in: defaults) == .live)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .default)

        defaults.set(TimecodeFeedback.onDemand.rawValue, forKey: AppPreferenceKey.timecodeFeedback)
        defaults.set(TimecodeVerbosity.frames.rawValue, forKey: AppPreferenceKey.timecodeVerbosity)
        #expect(AppPreferences.timecodeFeedback(in: defaults) == .onDemand)
        #expect(AppPreferences.timecodeVerbosity(in: defaults) == .frames)
    }

    @Test func defaultTimecodeSpeaksMillisecondsAsAUnit() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 3_661.042,
            frameRate: 30,
            verbosity: .default, milliseconds: true
        ) == "1 hour, 1 minute, 1 second, 42 milliseconds")
    }

    @Test func shortTimecodePreservesMillisecondsBelowAMinute() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 35.44,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "35.44 seconds")
    }

    @Test func shortTimecodePreservesMillisecondsAtAMinuteOrLonger() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 63.4,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "1 minute, 3.4 seconds")
        #expect(AppPreferences.spokenTimecode(
            seconds: 3_663.4,
            frameRate: 30,
            verbosity: .short, milliseconds: true
        ) == "1 hour, 1 minute, 3.4 seconds")
    }

    @Test func frameTimecodeUsesTheCurrentFrameRate() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 1.5,
            frameRate: 30,
            verbosity: .frames
        ) == "Frame 45")
    }
}
