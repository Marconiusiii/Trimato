import CoreAudio
import Testing
@testable import TrimatoMediaSupport

struct RecordingFormatTests {
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
