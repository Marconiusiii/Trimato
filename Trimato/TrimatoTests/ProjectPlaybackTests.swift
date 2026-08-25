import Foundation
import Testing
@testable import Trimato

@Suite("Project playback")
struct ProjectPlaybackTests {
    @Test func editNavigationIncludesStorylineAndCutawayBoundariesWithoutDuplicates() {
        let firstAsset = fixtureAsset(name: "Interview", duration: 5)
        let secondAsset = fixtureAsset(name: "Closing", duration: 5)
        let cutawayAsset = fixtureAsset(name: "Cutaway", duration: 4)
        var project = TrimatoProject(name: "Playback")
        project.media = [firstAsset, secondAsset, cutawayAsset]
        project.primaryTimeline = [
            TimelineClip(assetID: firstAsset.id, name: firstAsset.name, segments: firstAsset.sourceEdit),
            TimelineClip(assetID: secondAsset.id, name: secondAsset.name, segments: secondAsset.sourceEdit),
        ]
        project.cutaways = [
            TimelineCutaway(
                assetID: cutawayAsset.id,
                name: cutawayAsset.name,
                start: ProjectTime(seconds: 2),
                segments: cutawayAsset.sourceEdit,
                audioMode: .primaryAudio
            )
        ]

        let points = ProjectPlayerViewModel.editPoints(in: project)

        #expect(points == [0, 2, 5, 6, 10].map { ProjectTime(seconds: Double($0)) })
    }

    @Test func emptyProjectHasOnePlaybackBoundary() {
        #expect(ProjectPlayerViewModel.editPoints(in: TrimatoProject()) == [.zero])
    }

    @Test func accessibilityTimecodeUsesSpokenTimeComponents() {
        let label = ProjectPlayerViewModel.accessibilityTimeLabel(
            time: ProjectTime(seconds: 3_661.042),
            showingFrames: false,
            frameRate: 30
        )

        #expect(label == "1 hour, 1 minute, 1 second, 42 milliseconds")
    }

    @Test func frameDisplayUsesTheProjectFrameRate() {
        let label = ProjectPlayerViewModel.accessibilityTimeLabel(
            time: ProjectTime(seconds: 1.5),
            showingFrames: true,
            frameRate: 30
        )

        #expect(label == "Frame 45")
    }
}
