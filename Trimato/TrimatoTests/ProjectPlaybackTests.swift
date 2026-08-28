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

    @Test @MainActor func nonemptyProjectCanExportBeforePreviewIsPrepared() throws {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Immediate Export")
        project.media = [asset]
        _ = try project.append(asset: asset)

        let controller = ProjectController(document: ProjectDocument(project: project))

        #expect(controller.canExportProject)
    }

    @Test @MainActor func emptyProjectCannotExportBeforePreviewIsPrepared() {
        let controller = ProjectController(
            document: ProjectDocument(project: TrimatoProject(name: "Empty"))
        )

        #expect(!controller.canExportProject)
    }

    @Test @MainActor func transitionApplicationUsesThePrimaryVideoNameAndSeparateProgressFocus() {
        let controller = ProjectController(document: ProjectDocument())
        let audio = TimelineTransition(
            trackID: UUID(),
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: UUID(),
            trailingClipID: UUID()
        )
        let video = TimelineTransition(
            trackID: UUID(),
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: UUID(),
            trailingClipID: UUID()
        )

        controller.beginApplyingTransitions([audio, video])
        #expect(controller.applyingTransitionName == "Cross Dissolve")

        controller.requestTransitionProgressFocus()
        #expect(controller.transitionProgressFocusRequest == 1)
        #expect(controller.editorFocusRestoreRequest == 0)

        controller.finishApplyingTransition()
        #expect(controller.applyingTransitionName == nil)
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

    @Test @MainActor func quickTransitionRequestKeepsTheEditorSelectionContext() throws {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Quick transition")
        project.media = [first, second]
        _ = try project.append(asset: first)
        _ = try project.append(asset: second)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.selection = .project

        controller.requestQuickTransition(at: ProjectTime(seconds: 5), mode: .quickCross)

        #expect(controller.selection == .project)
        #expect(controller.transitionRequest?.mode == .quickCross)
        #expect(controller.transitionRequest?.clipID == controller.project.tracks.first?.sortedClips.first?.id)
    }

    @Test @MainActor func standardTransitionRequestUsesTheEditorPlayheadAtAnEditPoint() throws {
        let first = fixtureAsset(name: "Interview", duration: 5)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject(name: "Editor transition")
        project.media = [first, second]
        let firstID = try project.append(asset: first)
        _ = try project.append(asset: second)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.selection = .project

        controller.requestTransition(at: ProjectTime(seconds: 5))

        #expect(controller.selection == .project)
        #expect(controller.transitionRequest?.mode == .standard)
        #expect(controller.transitionRequest?.clipID == firstID)
        #expect(controller.transitionRequestReturnsToEditor)
    }

    @Test @MainActor func quickTransitionAdditionDoesNotSelectTheTimelineTransition() throws {
        let asset = fixtureAsset(name: "Interview", duration: 5)
        var project = TrimatoProject(name: "Quick fade")
        project.media = [asset]
        let clipID = try project.append(asset: asset)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let trackID = try #require(controller.project.tracks.first { $0.kind == .video }?.id)
        let fade = TimelineTransition(
            trackID: trackID,
            edge: .outro,
            kind: .video(.fade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: clipID,
            trailingClipID: nil
        )
        controller.selection = .project

        try controller.addTransitions([fade], selectAddedTransition: false)

        #expect(controller.selection == .project)
        #expect(controller.project.transition(id: fade.id) == fade)
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

    @Test @MainActor func crossDissolvePreviewRendersSourcesWithDifferentFrameRates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leadingURL = directory.appendingPathComponent("leading.mov")
        let trailingURL = directory.appendingPathComponent("trailing.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=red:size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", leadingURL.path,
        ])
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=blue:size=640x360:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
            "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", trailingURL.path,
        ])

        var leadingAsset = fixtureAsset(name: "Leading", duration: 2)
        leadingAsset.originalPath = leadingURL.path
        leadingAsset.frameRate = 24
        var trailingAsset = fixtureAsset(name: "Trailing", duration: 2)
        trailingAsset.originalPath = trailingURL.path
        trailingAsset.frameRate = 30
        var project = TrimatoProject(name: "Cross dissolve")
        project.format = ProjectFormat(mode: .custom, width: 640, height: 360, frameRate: 30)
        project.media = [leadingAsset, trailingAsset]
        let editedSegment = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 0.5),
            duration: ProjectTime(seconds: 1)
        ))]
        let leadingID = try project.append(asset: leadingAsset, segments: editedSegment)
        let trailingID = try project.append(asset: trailingAsset, segments: editedSegment)
        let videoTrack = try #require(project.tracks.first { $0.kind == .video })
        let leadingVideo = try #require(videoTrack.clips.first { $0.id == leadingID })
        let trailingVideo = try #require(videoTrack.clips.first { $0.id == trailingID })
        let audioTrack = try #require(project.tracks.first { $0.kind == .audio })
        let leadingAudioID = try #require(leadingVideo.linkedClipID)
        let trailingAudioID = try #require(trailingVideo.linkedClipID)
        let duration = ProjectTime(seconds: 0.5)
        try project.addTransition(TimelineTransition(
            trackID: videoTrack.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: duration,
            leadingClipID: leadingVideo.id,
            trailingClipID: trailingVideo.id
        ))
        try project.addTransition(TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: duration,
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID
        ))

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [leadingAsset.id: leadingURL, trailingAsset.id: trailingURL],
            purpose: .preview
        )
        defer { result.temporaryMediaURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(result.videoComposition != nil)
        #expect(result.temporaryMediaURLs.count >= 2)
        let audioTracks = try await result.composition.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count >= 2)
        var hasOverlappingTransitionTrack = false
        for track in audioTracks {
            for segment in try await track.load(.segments) where !segment.isEmpty {
                let range = segment.timeMapping.target
                if abs(range.start.seconds - 0.75) < 0.02 && abs(range.duration.seconds - 0.5) < 0.02 {
                    hasOverlappingTransitionTrack = true
                }
            }
        }
        #expect(hasOverlappingTransitionTrack)
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
