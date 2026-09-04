import AppKit
import Foundation
import Testing
@testable import Trimato

@Suite("Caption finalization")
struct CaptionFinalizerTests {
    @Test func finalizationSplitsLongPassagesAndPreservesEveryWord() throws {
        let text = """
        I got the water started, and now I am measuring the coffee. I usually use about twenty grams for this cup.
        Then I pour slowly, wait for the bloom, and continue until the scale reaches the amount I want.
        """
        let draft = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 18),
            text: text,
            isDraft: true
        )

        let result = CaptionFinalizer.finalize(
            cues: [draft],
            projectDuration: ProjectTime(seconds: 25),
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )

        #expect(result.issues.isEmpty)
        #expect(result.finalizedPassages == 1)
        #expect(result.cues.count > 1)
        #expect(result.cues.allSatisfy { !$0.isDraft })
        #expect(result.cues.first?.start == draft.start)
        #expect(result.cues.last?.end == draft.end)
        #expect(normalized(result.cues.map(\.text).joined(separator: " ")) == normalized(text))
        for cue in result.cues {
            let startFrame = cue.start.seconds * 30
            let endFrame = cue.end.seconds * 30
            let durationFrames = cue.duration.seconds * 30
            #expect(abs(startFrame.rounded() - startFrame) < 0.000_001)
            #expect(abs(endFrame.rounded() - endFrame) < 0.000_001)
            #expect(durationFrames >= 40 - 0.000_001)
            #expect(durationFrames <= 180 + 0.000_001)
            var definition = GeneratorDefinition()
            definition.kind = .text
            definition.width = 1_920
            definition.height = 1_080
            definition.textSettings.apply(.caption)
            definition.textSettings.text = cue.text
            let layout = try TextGeneratorRenderer.layout(definition)
            #expect(layout.fits)
            #expect(layout.lineCount <= 2)
        }
    }

    @Test func finalizationBorrowsNoMoreThanFifteenFramesAfterOut() {
        let draft = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 2),
            text: "One two three four",
            isDraft: true
        )

        let result = CaptionFinalizer.finalize(
            cues: [draft],
            projectDuration: ProjectTime(seconds: 10),
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )

        #expect(result.issues.isEmpty)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].start == draft.start)
        #expect(result.cues[0].end == ProjectTime(seconds: 2.5))
    }

    @Test func finalizationNeverExtendsPastTheNextCaption() {
        let draft = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 2),
            text: "One two three four",
            isDraft: true
        )
        let next = CaptionCue(
            start: ProjectTime(seconds: 2.2),
            end: ProjectTime(seconds: 4),
            text: "Next caption"
        )

        let result = CaptionFinalizer.finalize(
            cues: [draft, next],
            projectDuration: ProjectTime(seconds: 10),
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )

        #expect(result.finalizedPassages == 0)
        #expect(result.issues.count == 1)
        #expect(result.cues.first(where: { $0.id == draft.id })?.isDraft == true)
        #expect(result.cues.first(where: { $0.id == next.id }) == next)
    }

    @Test func manualLineBreakRemainsInTheFinalCaption() {
        let draft = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 4),
            text: "The first requested line\nThe second requested line",
            isDraft: true
        )

        let result = CaptionFinalizer.finalize(
            cues: [draft],
            projectDuration: ProjectTime(seconds: 10),
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )

        #expect(result.issues.isEmpty)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].text == draft.text)
    }

    @Test func finalizedAndImportedCuesAreNotReformatted() {
        let existing = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 4),
            text: "Already\nformatted",
            identifier: "imported",
            webVTTSettings: "align:start"
        )

        let result = CaptionFinalizer.finalize(
            cues: [existing],
            projectDuration: ProjectTime(seconds: 10),
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )

        #expect(!result.changed)
        #expect(result.cues == [existing])
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
