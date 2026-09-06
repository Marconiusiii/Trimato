import Foundation
import Testing
@testable import Trimato

@Suite("App preferences", .serialized)
struct AppPreferencesTests {
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
            verbosity: .default
        ) == "1 hour, 1 minute, 1 second, 42 milliseconds")
    }

    @Test func shortTimecodeUsesTenthsBelowAMinute() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 35.44,
            frameRate: 30,
            verbosity: .short
        ) == "35.4 seconds")
    }

    @Test func shortTimecodeUsesWholeSecondsAtAMinuteOrLonger() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 63.4,
            frameRate: 30,
            verbosity: .short
        ) == "1 minute, 3 seconds")
        #expect(AppPreferences.spokenTimecode(
            seconds: 3_663.4,
            frameRate: 30,
            verbosity: .short
        ) == "1 hour, 1 minute, 3 seconds")
    }

    @Test func frameTimecodeUsesTheCurrentFrameRate() {
        #expect(AppPreferences.spokenTimecode(
            seconds: 1.5,
            frameRate: 30,
            verbosity: .frames
        ) == "Frame 45")
    }
}
