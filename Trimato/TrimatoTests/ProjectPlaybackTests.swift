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

    @Test func validProjectMarkersCreateAnExportRange() {
        let range = ProjectPlayerViewModel.validExportRange(
            inMarker: ProjectTime(seconds: 2),
            outMarker: ProjectTime(seconds: 7)
        )

        #expect(range == ProjectTimeRange(
            start: ProjectTime(seconds: 2),
            duration: ProjectTime(seconds: 5)
        ))
        #expect(ProjectPlayerViewModel.validExportRange(
            inMarker: ProjectTime(seconds: 7),
            outMarker: ProjectTime(seconds: 2)
        ) == nil)
    }

    @Test @MainActor func selectingAStorylineCutSelectsTheClipBeginningAtThatCut() {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Selection")
        project.media = [first, second]
        project.primaryTimeline = [
            TimelineClip(assetID: first.id, name: first.name, segments: first.sourceEdit),
            TimelineClip(assetID: second.id, name: second.name, segments: second.sourceEdit),
        ]
        let controller = ProjectController(document: ProjectDocument(project: project))

        controller.selectTimelineEntry(at: ProjectTime(seconds: 5))

        #expect(controller.selection == .timelineClip(project.primaryTimeline[1].id))
    }

    @Test @MainActor func selectingACutawayStartSelectsTheCutaway() {
        let primary = fixtureAsset(name: "Interview", duration: 10)
        let cutawayAsset = fixtureAsset(name: "Cutaway", duration: 3)
        var project = TrimatoProject(name: "Selection")
        project.media = [primary, cutawayAsset]
        project.primaryTimeline = [
            TimelineClip(assetID: primary.id, name: primary.name, segments: primary.sourceEdit)
        ]
        let cutaway = TimelineCutaway(
            assetID: cutawayAsset.id,
            name: cutawayAsset.name,
            start: ProjectTime(seconds: 2),
            segments: cutawayAsset.sourceEdit,
            audioMode: .sourceAudio
        )
        project.cutaways = [cutaway]
        let controller = ProjectController(document: ProjectDocument(project: project))

        controller.selectTimelineEntry(at: ProjectTime(seconds: 2))

        #expect(controller.selection == .cutaway(cutaway.id))
    }
}
