import Testing
@testable import Trimato

struct OperationProgressTests {
    @Test func speaksMilestonesWithoutAWindowOrFocusedControl() {
        var speech = OperationProgressAnnouncements()
        let messages = [0.0, 0.02, 0.1, 0.19, 0.35, 0.34, 0.9, 1.0].compactMap {
            speech.update(title: "Applying Filter", progress: $0)
        }
        #expect(messages == ["Applying Filter, 0 percent.", "Applying Filter, 10 percent.",
                             "Applying Filter, 30 percent.", "Applying Filter, 90 percent."])
        #expect(speech.finish(title: "Applying Filter", outcome: .completed) ==
                "Applying Filter, 100 percent, complete.")
        #expect(speech.update(title: "Applying Filter", progress: 0.5) == nil)
        #expect(speech.finish(title: "Applying Filter", outcome: .completed) == nil)
    }

    @Test func cancellationNeverAnnouncesCompletionAndRetryStartsFresh() {
        var cancelled = OperationProgressAnnouncements()
        _ = cancelled.update(title: "Updating Clip Preview", progress: 0.45)
        #expect(cancelled.finish(title: "Updating Clip Preview", outcome: .cancelled) ==
                "Updating Clip Preview, cancelled.")
        #expect(cancelled.update(title: "Updating Clip Preview", progress: 1) == nil)
        var retry = OperationProgressAnnouncements()
        #expect(retry.update(title: "Updating Clip Preview", progress: 0.1) ==
                "Updating Clip Preview, 10 percent.")
        #expect(retry.finish(title: "Updating Clip Preview", outcome: .failed) ==
                "Updating Clip Preview, failed.")
    }

    @Test func indeterminateWorkHasNoInventedPercentage() {
        var speech = OperationProgressAnnouncements()
        #expect(speech.update(title: "Preparing Waveform", progress: nil) == "Preparing Waveform.")
        #expect(speech.update(title: "Preparing Waveform", progress: .nan) == nil)
        #expect(speech.update(title: "Preparing Waveform", progress: .infinity) == nil)
        #expect(speech.finish(title: "Preparing Waveform", outcome: .completed) == "Preparing Waveform, complete.")
    }
}
