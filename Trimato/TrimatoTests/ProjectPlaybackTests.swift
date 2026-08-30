import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Trimato

@Suite("Project playback", .serialized)
@MainActor
struct ProjectPlaybackTests {
    @Test func absoluteTrackArrowsWorkWithoutPickupAndPreserveVoiceOverNavigation() throws {
        for key: UInt16 in [123, 124, 125, 126] {
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [], isMoving: false, allowsNudging: true) == (key == 123 || key == 126 ? .earlier : .later))
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [.control, .option], isMoving: false, allowsNudging: true) == nil)
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [], isMoving: false, allowsNudging: false) == nil)
        }
        let clip = TimelineElementSelection.clip(UUID())
        let coordinator = TimelineKeyboardBridge.Coordinator()
        var actions: [TimelineKeyAction] = []
        coordinator.bridge = TimelineKeyboardBridge(accessibilitySelection: clip, keyboardSelection: .clip(UUID()), movingClipID: nil, allowsNudging: { $0 == clip }) { action, target in
            #expect(target == clip)
            actions.append(action)
        }
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        #expect(coordinator.handleKey(arrow, voiceOver: true, editingText: true) == nil)
        #expect(actions == [.later])
    }

    @Test func timelineRoutingUsesVoiceOverRowEvenWithAnotherKeyboardResponder() {
        let voiceOverRow = TimelineElementSelection.clip(UUID())
        let keyboardRow = TimelineElementSelection.clip(UUID())
        #expect(TimelineKeyAction.target(voiceOver: true, accessibilityFocus: voiceOverRow, keyboardFocus: keyboardRow, editingText: true) == voiceOverRow)
        #expect(TimelineKeyAction.target(voiceOver: true, accessibilityFocus: nil, keyboardFocus: keyboardRow, editingText: false) == nil)
        #expect(TimelineKeyAction.target(voiceOver: false, accessibilityFocus: voiceOverRow, keyboardFocus: keyboardRow, editingText: true) == nil)
        #expect(TimelineKeyAction.target(voiceOver: false, accessibilityFocus: voiceOverRow, keyboardFocus: keyboardRow, editingText: false) == keyboardRow)
    }

    @Test func positionsAreSpokenOnlyForThePickedUpClip() {
        #expect(TimelineAccessibility.clipValue(isCurrent: false, isSelected: false).isEmpty)
        #expect(TimelineAccessibility.clipValue(isCurrent: true, isSelected: false) == "Current clip")
        #expect(TimelineAccessibility.clipValue(isCurrent: false, isSelected: true) == "Selected")
    }

    @Test func nativeMouseHoldArrowAndReleaseUseTheSameMovementSession() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = TimelineRowAnchorView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let clip = TimelineElementSelection.clip(UUID())
        anchor.element = clip
        try #require(window.contentView).addSubview(anchor)
        let coordinator = TimelineKeyboardBridge.Coordinator()
        var actions: [TimelineKeyAction] = []
        coordinator.bridge = TimelineKeyboardBridge(accessibilitySelection: clip, keyboardSelection: nil, movingClipID: nil) { action, target in
            #expect(target == clip)
            actions.append(action)
        }
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 20), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        #expect(coordinator.handleMouse(try mouse(.leftMouseDown), in: window) == nil)
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        #expect(coordinator.handleKey(arrow, voiceOver: true, editingText: true) == nil)
        #expect(coordinator.handleMouse(try mouse(.leftMouseUp), in: window) == nil)
        #expect(actions == [.beginMovement, .later, .finishMovement])
        actions.removeAll()
        #expect(coordinator.handleMouse(try mouse(.leftMouseDown), in: window) == nil)
        #expect(coordinator.handleMouse(try mouse(.leftMouseUp), in: window) == nil)
        #expect(actions == [.openEditor])
        try await Task.sleep(for: .milliseconds(180))
        #expect(actions == [.openEditor])
        actions.removeAll()
        #expect(coordinator.handleMouse(try mouse(.leftMouseDown), in: window) == nil)
        try await Task.sleep(for: .milliseconds(180))
        #expect(actions == [.beginMovement])
        #expect(coordinator.handleMouse(try mouse(.leftMouseUp), in: window) == nil)
        #expect(actions == [.beginMovement, .finishMovement])
    }

    @Test func timelineKeysRespectMovementModeAndVoiceOverModifiers() {
        #expect(TimelineKeyAction.resolve(keyCode: 49, modifiers: [], isMoving: false) == .toggleMovement)
        #expect(TimelineKeyAction.resolve(keyCode: 36, modifiers: [], isMoving: false) == .openEditor)
        #expect(TimelineKeyAction.resolve(keyCode: 76, modifiers: [], isMoving: true) == .openEditor)
        for key: UInt16 in [123, 126] {
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [], isMoving: true) == .earlier)
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [], isMoving: false) == nil)
        }
        for key: UInt16 in [124, 125] {
            #expect(TimelineKeyAction.resolve(keyCode: key, modifiers: [], isMoving: true) == .later)
        }
        #expect(TimelineKeyAction.resolve(keyCode: 49, modifiers: [.control, .option], isMoving: true) == nil)
        #expect(TimelineKeyAction.resolve(keyCode: 124, modifiers: [.control, .option], isMoving: true) == nil)
        #expect(TimelineKeyAction.resolve(keyCode: 9, modifiers: [.command, .option], isMoving: false) == .moveAfter)
        #expect(TimelineKeyAction.resolve(keyCode: 53, modifiers: [], isMoving: false) == nil)
    }

    @Test func editorKeyboardRoutingRecognizesTrackSelectionAndAbsolutePositioning() {
        #expect(ProjectPlayerViewModel.trackSelectionOffset(
            keyCode: 126,
            commandAndOptionOnly: true
        ) == -1)
        #expect(ProjectPlayerViewModel.trackSelectionOffset(
            keyCode: 125,
            commandAndOptionOnly: true
        ) == 1)
        #expect(ProjectPlayerViewModel.trackSelectionOffset(
            keyCode: 125,
            commandAndOptionOnly: false
        ) == nil)
        #expect(ProjectPlayerViewModel.absolutePositioningEdge(
            character: "[",
            unmodified: true
        ) == .head)
        #expect(ProjectPlayerViewModel.absolutePositioningEdge(
            character: "]",
            unmodified: true
        ) == .tail)
        #expect(ProjectPlayerViewModel.absolutePositioningEdge(
            character: "]",
            unmodified: false
        ) == nil)
        #expect(ProjectPlayerViewModel.trimEdge(
            character: "[",
            commandOnly: true
        ) == .head)
        #expect(ProjectPlayerViewModel.trimEdge(
            character: "]",
            commandOnly: true
        ) == .tail)
        #expect(ProjectPlayerViewModel.trimEdge(
            character: "[",
            commandOnly: false
        ) == nil)
    }

    @Test func projectPlayheadSliderUsesOneFrameAsItsNativeAdjustmentStep() {
        #expect(abs(ProjectPlayerViewModel.playbackFractionStep(
            duration: ProjectTime(seconds: 10),
            frameRate: 25
        ) - 0.004) < 0.000_001)
        #expect(ProjectPlayerViewModel.playbackFractionStep(
            duration: .zero,
            frameRate: 25
        ) == 1)
    }

    @Test func preparedEditorControlsRemainAvailableDuringBackgroundPreviewRebuilds() {
        #expect(ProjectPlayerViewModel.canControlPlayback(
            hasPreparedItem: true,
            isPreparing: true
        ))
        #expect(ProjectPlayerViewModel.canControlPlayback(
            hasPreparedItem: true,
            isPreparing: false
        ))
        #expect(!ProjectPlayerViewModel.canControlPlayback(
            hasPreparedItem: false,
            isPreparing: true
        ))
    }

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

        let points = ProjectPlayerViewModel.editPoints(in: project).map(\.time)

        #expect(points == [0, 2, 5, 6, 10].map { ProjectTime(seconds: Double($0)) })
    }

    @Test func emptyProjectHasOnePlaybackBoundary() {
        #expect(ProjectPlayerViewModel.editPoints(in: TrimatoProject()).map(\.time) == [.zero])
    }

    @Test func editNavigationRetainsVideoAndAudioBoundaryTypes() throws {
        var video = fixtureAsset(name: "Picture", duration: 5)
        video.hasAudio = false
        var music = fixtureAsset(name: "Music", duration: 3)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject(name: "Typed edit points")
        project.media = [video, music]
        _ = try project.append(asset: video)
        let musicTrackID = project.createTrack(kind: .audio, name: "Music")
        _ = try project.append(asset: music, toTrack: musicTrackID)

        let points = ProjectPlayerViewModel.editPoints(in: project)

        let sharedStart = try #require(points.first { $0.time == .zero })
        #expect(sharedStart.spokenName == "Video and audio edit point")
        let audioEnd = try #require(points.first { $0.time == ProjectTime(seconds: 3) })
        #expect(audioEnd.spokenName == "Audio edit point")
        let videoEnd = try #require(points.first { $0.time == ProjectTime(seconds: 5) })
        #expect(videoEnd.spokenName == "Video edit point")
    }

    @Test func editNavigationOmitsAnAdditionalClipsHiddenNegativeBoundary() throws {
        var music = fixtureAsset(name: "Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject(name: "Negative positioning")
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let clipID = try project.append(asset: music, toTrack: trackID)
        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 15)
        )

        let points = ProjectPlayerViewModel.editPoints(in: project)

        #expect(points.allSatisfy { $0.time >= .zero })
        #expect(!points.contains { $0.time == ProjectTime(seconds: -45) })
        #expect(points.contains { $0.time == ProjectTime(seconds: 15) && $0.hasAudio })
    }

    @Test func videoEndIgnoresLongerLayeredAudioTracks() throws {
        let video = fixtureAsset(name: "Picture", duration: 14.408)
        var music = fixtureAsset(name: "Music", duration: 59.647)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [video, music]
        _ = try project.append(asset: video)
        let musicTrackID = project.createTrack(kind: .audio, name: "Musica")
        _ = try project.append(asset: music, toTrack: musicTrackID)

        #expect(ProjectPlayerViewModel.videoEnd(in: project) == ProjectTime(seconds: 14.408))
        #expect(project.duration == ProjectTime(seconds: 59.647))
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

    @Test func editNavigationCalloutReplacesTheCompetingPlainTimecodeValue() {
        let callout = "Video edit point, 5 seconds"

        #expect(ProjectPlayerViewModel.accessibilityTimeValue(
            time: ProjectTime(seconds: 5),
            showingFrames: false,
            frameRate: 30,
            navigationCallout: callout
        ) == callout)
        #expect(ProjectPlayerViewModel.accessibilityTimeValue(
            time: ProjectTime(seconds: 5),
            showingFrames: false,
            frameRate: 30,
            navigationCallout: nil
        ) == "5 seconds, 0 milliseconds")
    }

    @Test func frameSteppingUsesTheProjectRateAndStopsAtProjectBoundaries() {
        let duration = ProjectTime(seconds: 10)

        #expect(ProjectPlayerViewModel.frameStepDestination(
            current: ProjectTime(seconds: 1),
            duration: duration,
            frameRate: 25,
            forward: true
        ) == ProjectTime(seconds: 1.04))
        #expect(ProjectPlayerViewModel.frameStepDestination(
            current: .zero,
            duration: duration,
            frameRate: 25,
            forward: false
        ) == .zero)
        #expect(ProjectPlayerViewModel.frameStepDestination(
            current: duration,
            duration: duration,
            frameRate: 25,
            forward: true
        ) == duration)
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

    @Test @MainActor func transitionApplicationUsesThePrimaryVideoName() {
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
        #expect(controller.applyingTransitionProgress == 0)

        controller.finishApplyingTransition()
        #expect(controller.applyingTransitionName == nil)
        #expect(controller.applyingTransitionProgress == nil)
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
            frameRate: 30,
            editPoint: ProjectEditPoint(
                time: ProjectTime(seconds: 5),
                hasVideo: true,
                hasAudio: true
            )
        ) == "Video and audio edit point, 5 seconds")
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

    @Test func projectPreviewFailuresRetainTheUnderlyingMediaReason() {
        let underlying = NSError(
            domain: "AVFoundationErrorDomain",
            code: -12780,
            userInfo: [NSLocalizedDescriptionKey: "An unknown media error occurred (-12780)"]
        )
        let outer = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        let message = ProjectPlayerViewModel.previewFailureMessage(for: outer)

        #expect(message.contains("An unknown media error occurred (-12780)"))
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

    @Test func trimmedM4AWithGainBuildsAnAdditionalAudioTrackPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let musicURL = directory.appendingPathComponent("music.m4a")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "1", "-c:a", "aac", musicURL.path,
        ])

        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 0.1),
            duration: ProjectTime(seconds: 0.7)
        ))
        var music = fixtureAsset(name: "Music", duration: 1)
        music.originalPath = musicURL.path
        music.naturalWidth = nil
        music.naturalHeight = nil
        music.frameRate = nil
        var project = TrimatoProject(name: "M4A preview")
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let clipID = try project.append(asset: music, segments: [segment], toTrack: trackID)
        try project.updateAudioSettings(
            clipID: clipID,
            settings: AudioClipSettings(gainDecibels: -9)
        )

        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [music.id: musicURL],
            purpose: .preview
        )
        defer { result.temporaryMediaURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(result.temporaryMediaURLs.count == 1)
        let audioTracks = try await result.composition.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        #expect(abs((try await result.composition.load(.duration)).seconds - 0.7) < 0.02)
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
        var renderedAudioDuration: Double?
        for url in result.temporaryMediaURLs {
            let report = try await FFmpegMediaProbe.inspect(url: url)
            if report.videoStream == nil, report.hasAudio {
                renderedAudioDuration = report.duration
                break
            }
        }
        #expect(abs((renderedAudioDuration ?? 0) - duration.seconds) < 0.02)
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

        let viewModel = ProjectPlayerViewModel()
        var progressValues: [Double] = []
        try await viewModel.prepareTransitionPreview(
            project: project,
            mediaURLs: [leadingAsset.id: leadingURL, trailingAsset.id: trailingURL],
            initialTime: ProjectTime(seconds: 0.75),
            progress: { progressValues.append($0) }
        )

        #expect(viewModel.player.currentItem != nil)
        #expect(!viewModel.isPreparing)
        #expect(progressValues.last == 1)
    }

    @Test @MainActor func transitionPreviewUsesSeparatePlayerItemsForStagingAndCommit() {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: 320, height: 180)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let result = ProjectCompositionResult(
            composition: AVMutableComposition(),
            videoComposition: videoComposition,
            audioMix: AVMutableAudioMix(),
            temporaryMediaURLs: []
        )

        let stagedItem = ProjectPlayerViewModel.makeTransitionPreviewItem(from: result)
        let committedItem = ProjectPlayerViewModel.makeTransitionPreviewItem(from: result)

        #expect(stagedItem !== committedItem)
        #expect(stagedItem.videoComposition != nil)
        #expect(committedItem.videoComposition != nil)
        #expect(stagedItem.audioMix != nil)
        #expect(committedItem.audioMix != nil)
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
