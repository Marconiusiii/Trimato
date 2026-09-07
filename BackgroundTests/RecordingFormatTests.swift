import CoreAudio
import Testing
@testable import TrimatoMediaSupport

struct RecordingFormatTests {
    @Test func supportedCaptureRatesDoNotInventBluetoothQuality() {
        #expect(AudioCaptureFormat.preferredRate(current: 16000, available: [AudioValueRange(mMinimum: 16000, mMaximum: 16000)]) == 16000)
        #expect(AudioCaptureFormat.preferredRate(current: 16000, available: [AudioValueRange(mMinimum: 16000, mMaximum: 48000)]) == 48000)
        #expect(AudioCaptureFormat.preferredRate(current: 96000, available: [AudioValueRange(mMinimum: 16000, mMaximum: 48000)]) == 96000)
        #expect(AudioCaptureFormat.preferredRate(current: 44100, available: []) == 44100)
    }
    @Test func previewBoundsRestartAtOutAndLeaveVoicerUnbounded() {
        let describer = RecordingPreviewRange(start: 5, end: 8, bounded: true)
        #expect(describer.position(resuming: nil) == 5)
        #expect(describer.position(resuming: 3) == 5)
        #expect(describer.position(resuming: 6) == 6)
        #expect(describer.position(resuming: 8) == 5)
        #expect(describer.position(resuming: 12) == 5)
        #expect(describer.position(resuming: .nan) == 5)
        let voicer = RecordingPreviewRange(start: 5, end: 8, bounded: false)
        #expect(voicer.end == nil)
        #expect(voicer.position(resuming: 12) == 12)
    }
}
