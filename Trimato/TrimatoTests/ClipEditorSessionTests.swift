import CoreMedia
import Testing
@testable import Trimato

@Suite("Clip editor sessions")
struct ClipEditorSessionTests {
    @Test func oneSourceRangeOpensTheFullSourceWithSavedMarkers() {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))

        let opening = ClipEditorOpeningConfiguration.make(
            segments: [segment],
            sourceDuration: ProjectTime(seconds: 10)
        )

        #expect(opening.playbackSegments == nil)
        #expect(opening.inMarker == ProjectTime(seconds: 1))
        #expect(opening.outMarker == ProjectTime(seconds: 4))
    }

    @Test func multipleSourceRangesOpenAsTheCurrentEditedSequence() {
        let segments = [
            SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 2)
            )),
            SourceSegment(sourceRange: ProjectTimeRange(
                start: ProjectTime(seconds: 5),
                duration: ProjectTime(seconds: 3)
            )),
        ]

        let opening = ClipEditorOpeningConfiguration.make(
            segments: segments,
            sourceDuration: ProjectTime(seconds: 10)
        )

        #expect(opening.playbackSegments == segments)
        #expect(opening.inMarker == .zero)
        #expect(opening.outMarker == ProjectTime(seconds: 5))
    }

    @Test func markerSelectionMapsBackToTheOriginalSourceRange() {
        let timeline = ClipEditTimeline(sourceRanges: [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            CMTimeRange(
                start: CMTime(seconds: 5, preferredTimescale: 600),
                duration: CMTime(seconds: 3, preferredTimescale: 600)
            ),
        ])

        let selected = timeline.sourceRanges(in: CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 600),
            duration: CMTime(seconds: 3, preferredTimescale: 600)
        ))

        #expect(selected == [
            CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600),
                duration: CMTime(seconds: 1, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 5, preferredTimescale: 600),
                duration: CMTime(seconds: 2, preferredTimescale: 600)
            ),
        ])
    }

    @Test func draftTracksRangesWithoutTreatingNewSegmentIdentifiersAsEdits() {
        let range = ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 3))
        var draft = ClipEditorDraft(segments: [SourceSegment(sourceRange: range)])

        draft.replace(with: [SourceSegment(sourceRange: range)])
        #expect(!draft.hasChanges)

        draft.replace(with: [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 2),
            duration: ProjectTime(seconds: 2)
        ))])
        #expect(draft.hasChanges)

        draft.commit()
        #expect(!draft.hasChanges)
    }
}
