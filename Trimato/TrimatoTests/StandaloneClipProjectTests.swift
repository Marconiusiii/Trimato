import Foundation
import Testing
@testable import Trimato

@Suite("Create project from clip")
struct StandaloneClipProjectTests {
    @MainActor
    @Test func currentSelectionBecomesTheFirstTimelineClip() throws {
        let sourceEdit = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 8)
        ))]
        let selection = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 3),
            duration: ProjectTime(seconds: 4)
        ))]
        var asset = fixtureAsset(name: "Interview", duration: 10)
        asset.naturalWidth = 3_840
        asset.naturalHeight = 2_160
        asset.frameRate = 24
        asset.sourceEdit = sourceEdit

        let project = try StandaloneClipProjectBuilder.build(
            asset: asset,
            timelineSegments: selection
        )

        #expect(project.media.count == 1)
        #expect(project.media[0].sourceEdit == sourceEdit)
        #expect(project.primaryTimeline.count == 1)
        #expect(project.primaryTimeline[0].segments == selection)
        #expect(project.duration == ProjectTime(seconds: 4))
        #expect(project.format.width == 3_840)
        #expect(project.format.height == 2_160)
        #expect(project.format.frameRate == 24)
    }

    @MainActor
    @Test func audioOnlySelectionCreatesAnUnresolvedAudioFirstProject() throws {
        var asset = fixtureAsset(name: "Narration", duration: 12)
        asset.naturalWidth = nil
        asset.naturalHeight = nil
        asset.frameRate = nil
        asset.hasAudio = true
        let selection = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 2),
            duration: ProjectTime(seconds: 5)
        ))]

        let project = try StandaloneClipProjectBuilder.build(
            asset: asset,
            timelineSegments: selection
        )

        #expect(project.primaryTimeline.count == 1)
        #expect(project.duration == ProjectTime(seconds: 5))
        #expect(project.hasTimelineAudio)
        #expect(!project.hasTimelineVideo)
        #expect(!project.format.isResolved)
    }
}
