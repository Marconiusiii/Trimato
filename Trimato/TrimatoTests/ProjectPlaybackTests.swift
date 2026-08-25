import AVFoundation
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

    @Test func projectNavigationAnnouncementsIdentifyTheDestinationConcisely() {
        let duration = ProjectTime(seconds: 10)
        let inMarker = ProjectTime(seconds: 2)
        let outMarker = ProjectTime(seconds: 8)

        #expect(ProjectPlayerViewModel.navigationAnnouncement(
            destination: .zero,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: 30
        ) == "Start, 0 seconds")
        #expect(ProjectPlayerViewModel.navigationAnnouncement(
            destination: inMarker,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: 30
        ) == "In, 2 seconds")
        #expect(ProjectPlayerViewModel.navigationAnnouncement(
            destination: ProjectTime(seconds: 5),
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: 30
        ) == "Edit point, 5 seconds")
        #expect(ProjectPlayerViewModel.navigationAnnouncement(
            destination: outMarker,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: 30
        ) == "Out, 8 seconds")
        #expect(ProjectPlayerViewModel.navigationAnnouncement(
            destination: duration,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: 30
        ) == "End, 10 seconds")
    }

    @Test @MainActor func playheadResolutionFindsOnlyTheClipWhoseInteriorContainsTheTime() {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Resolution")
        project.media = [first, second]
        project.primaryTimeline = [
            TimelineClip(assetID: first.id, name: first.name, segments: first.sourceEdit),
            TimelineClip(assetID: second.id, name: second.name, segments: second.sourceEdit),
        ]
        let controller = ProjectController(document: ProjectDocument(project: project))

        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 2))?.id == project.primaryTimeline[0].id)
        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 7))?.id == project.primaryTimeline[1].id)
        #expect(controller.primaryTimelineClip(at: .zero) == nil)
        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 5)) == nil)
        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 10)) == nil)
    }

    @Test @MainActor func bladeSplitsTheClipAtThePlayheadWithoutTimelineSelection() {
        let interview = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Blade")
        project.media = [interview]
        project.primaryTimeline = [
            TimelineClip(assetID: interview.id, name: interview.name, segments: interview.sourceEdit)
        ]
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 4)

        controller.splitClipAtPlayhead()

        #expect(controller.project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 4),
            ProjectTime(seconds: 6),
        ])
        #expect(controller.selection == .project)
    }

    @Test @MainActor func bladeIgnoresAnUnrelatedTimelineSelection() {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Independent Selection")
        project.media = [first, second]
        project.primaryTimeline = [
            TimelineClip(assetID: first.id, name: first.name, segments: first.sourceEdit),
            TimelineClip(assetID: second.id, name: second.name, segments: second.sourceEdit),
        ]
        let selectedID = project.primaryTimeline[1].id
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.selection = .timelineClip(selectedID)
        controller.timelinePlayhead = ProjectTime(seconds: 2)

        controller.splitClipAtPlayhead()

        #expect(controller.project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 2),
            ProjectTime(seconds: 3),
            ProjectTime(seconds: 5),
        ])
        #expect(controller.selection == .timelineClip(selectedID))
    }

    @Test @MainActor func bladeAtAnExistingEditPointLeavesTheTimelineUnchanged() {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Boundary")
        project.media = [first, second]
        project.primaryTimeline = [
            TimelineClip(assetID: first.id, name: first.name, segments: first.sourceEdit),
            TimelineClip(assetID: second.id, name: second.name, segments: second.sourceEdit),
        ]
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 5)

        controller.splitClipAtPlayhead()

        #expect(controller.project.primaryTimeline == project.primaryTimeline)
    }

    @Test @MainActor func nonemptyProjectPreviewPreservesTheRequestedTimelineTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaURL = directory.appendingPathComponent("preview.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=red:size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "0.5", "-c:v", "mpeg4", "-c:a", "aac", mediaURL.path,
        ])

        var asset = fixtureAsset(name: "Preview", duration: 0.5)
        asset.originalPath = mediaURL.path
        var project = TrimatoProject(name: "Preview")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        project.media = [asset]
        _ = try project.append(asset: asset)
        let viewModel = ProjectPlayerViewModel()

        let requestedTime = ProjectTime(seconds: 0.25)
        viewModel.prepare(
            project: project,
            mediaURLs: [asset.id: mediaURL],
            initialTime: requestedTime
        )
        await waitForPreviewPreparation(viewModel)

        #expect(!viewModel.isPreparing)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.player.currentItem != nil)
        #expect(abs(viewModel.player.currentTime().seconds - requestedTime.seconds) < 0.01)
    }

    @Test @MainActor func emptyProjectSupersedesEarlierPreviewPreparation() async throws {
        let asset = fixtureAsset(name: "Unavailable", duration: 1)
        var project = TrimatoProject(name: "Superseded")
        project.media = [asset]
        _ = try project.append(asset: asset)
        let viewModel = ProjectPlayerViewModel()

        viewModel.prepare(project: project, mediaURLs: [:])
        viewModel.prepare(project: TrimatoProject(), mediaURLs: [:])
        try await Task.sleep(for: .milliseconds(100))

        #expect(!viewModel.isPreparing)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.player.currentItem == nil)
    }

    @MainActor
    private func waitForPreviewPreparation(_ viewModel: ProjectPlayerViewModel) async {
        for _ in 0..<400 {
            if !viewModel.isPreparing { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Project preview did not finish preparing")
    }
}
