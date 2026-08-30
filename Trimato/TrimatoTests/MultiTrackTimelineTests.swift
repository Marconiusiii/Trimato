import AVFoundation
import Combine
import Foundation
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct MultiTrackTimelineTests {
    @Test(arguments: [24.0, 25.0, 30_000.0 / 1_001.0, 60.0])
    func plainArrowsNudgeFocusedAdditionalClipOneProjectFrame(frameRate: Double) throws {
        let asset = fixtureAsset(name: "Effect", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio, name: "Effects")
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: track)
        let second = try project.append(asset: asset, segments: [segment(2, 2)], toTrack: track)
        project.tracks[0].clips[0].timelineStart = ProjectTime(seconds: 1)
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 5)
        project.format.frameRate = frameRate
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 3)
        controller.focusTimelineElement(.clip(second))
        let focusRequests = controller.timelineFocusRestoreRequest
        // The event target wins even if the Inspector was on another clip.
        controller.moveFocusedTimelineClip(id: first, by: 1)
        #expect(controller.project.timelineClip(id: first)?.timelineStart == ProjectTime(seconds: 1) + ProjectTime(seconds: 1 / frameRate))
        #expect(controller.project.timelineClip(id: second) == project.timelineClip(id: second))
        #expect(controller.project.timelineClip(id: first)?.segments == project.timelineClip(id: first)?.segments)
        #expect(controller.movingTimelineClipID == nil)
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 3))
        #expect(controller.timelineFocusRestoreRequest == focusRequests)
        controller.moveFocusedTimelineClip(id: first, by: -1)
        #expect(controller.project == project)
    }

    @Test func nudgesStopAtNeighborsWithoutMovingOrOverwritingThem() throws {
        let asset = fixtureAsset(name: "Effect", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio, name: "Effects")
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: track)
        let second = try project.append(asset: asset, segments: [segment(2, 2)], toTrack: track)
        project.format.frameRate = 25
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 2.04)
        try project.nudgeAdditionalTrackClip(id: second, byFrames: -1)
        #expect(project.timelineClip(id: second)?.timelineStart == project.timelineClip(id: first)?.timelineEnd)
        let touching = project
        #expect(throws: ProjectTimelineError.clipPositionOverlap("Effects")) {
            try project.nudgeAdditionalTrackClip(id: second, byFrames: -1)
        }
        #expect(project == touching)
        #expect(throws: ProjectTimelineError.clipPositionOverlap("Effects")) {
            try project.nudgeAdditionalTrackClip(id: first, byFrames: 1)
        }
        #expect(project == touching)
        #expect(throws: ProjectTimelineError.clipNudgeBeforeTimeline) {
            try project.nudgeAdditionalTrackClip(id: first, byFrames: -1)
        }
        #expect(project == touching)
    }

    @Test func aFrameNudgeCannotJumpAcrossASubframeNeighbor() throws {
        let asset = fixtureAsset(name: "Tick", duration: 1)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio, name: "Ticks")
        let first = try project.append(asset: asset, segments: [segment(0, 0.001)], toTrack: track)
        _ = try project.append(asset: asset, segments: [segment(0.01, 0.001)], toTrack: track)
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 0.01)
        let before = project
        #expect(throws: ProjectTimelineError.clipPositionOverlap("Ticks")) {
            try project.nudgeAdditionalTrackClip(id: first, byFrames: 1)
        }
        #expect(project == before)
    }

    @Test func rejectedNudgesDoNotRegisterUndoAndSuccessfulNudgesDo() throws {
        let asset = fixtureAsset(name: "Effect", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio)
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: track)
        _ = try project.append(asset: asset, segments: [segment(2, 2)], toTrack: track)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        controller.moveFocusedTimelineClip(id: first, by: 1)
        #expect(controller.project == project)
        #expect(!undo.canUndo)
        // The last clip can nudge into empty time without a movement selection.
        let last = try #require(project.track(id: track)?.sortedClips.last?.id)
        undo.beginUndoGrouping()
        controller.moveFocusedTimelineClip(id: last, by: 1)
        undo.endUndoGrouping()
        #expect(controller.project.timelineClip(id: last)?.timelineStart == ProjectTime(seconds: 2) + ProjectTime(seconds: 1.0 / 30))
        #expect(controller.movingTimelineClipID == nil)
        undo.undo()
        #expect(controller.project == project)
    }

    @Test func pickedUpAdditionalClipNudgesWithoutReorderingAndDropsAsOneUndo() throws {
        let asset = fixtureAsset(name: "Effect", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio, name: "Effects")
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: track)
        let second = try project.append(asset: asset, segments: [segment(2, 2)], toTrack: track)
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 4)
        project.format.frameRate = 25
        let controller = ProjectController(document: ProjectDocument(project: project))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        controller.beginClipMovement(id: first)
        controller.moveFocusedTimelineClip(id: second, by: 1)
        controller.moveFocusedTimelineClip(id: second, by: 1)
        #expect(controller.project == project)
        #expect(controller.movementPreview?.timelineClip(id: first)?.timelineStart == ProjectTime(seconds: 0.08))
        #expect(controller.movementPreview?.timelineClip(id: second) == project.timelineClip(id: second))
        #expect(controller.movementPositionDescription == "Start at frame 2, Effects track")
        undo.beginUndoGrouping()
        controller.finishClipMovement()
        undo.endUndoGrouping()
        #expect(controller.project.timelineClip(id: first)?.timelineStart == ProjectTime(seconds: 0.08))
        undo.undo()
        #expect(controller.project == project)
        #expect(!undo.canUndo)
    }

    @Test func linkedPictureNudgeChecksAudioCollisionBeforeCommittingEitherTrack() throws {
        let asset = fixtureAsset(name: "Footage", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let picture = try project.append(asset: asset, segments: [segment(0, 2)])
        let next = try project.append(asset: asset, segments: [segment(2, 2)])
        let linkedAudio = try #require(project.timelineClip(id: picture)?.linkedClipID)
        let nextAudio = try #require(project.timelineClip(id: next)?.linkedClipID)
        // A picture clip moved onto an additional track still carries its audio.
        let additional = project.createTrack(kind: .video)
        let sourceIndex = try #require(project.tracks.firstIndex(where: { $0.role == .primaryVideo }))
        let clip = project.tracks[sourceIndex].clips.removeFirst()
        project.tracks[project.tracks.count - 1].clips.append(clip)
        project.synchronizeTracksToLegacyTimeline()
        let before = project
        #expect(throws: ProjectTimelineError.clipPositionOverlap("Primary Audio")) {
            try project.nudgeAdditionalTrackClip(id: picture, byFrames: 1)
        }
        #expect(project == before)
        let audioTrackIndex = try #require(project.tracks.firstIndex(where: { $0.role == .primaryAudio }))
        let nextAudioIndex = try #require(project.tracks[audioTrackIndex].clips.firstIndex(where: { $0.id == nextAudio }))
        project.tracks[audioTrackIndex].clips[nextAudioIndex].timelineStart = ProjectTime(seconds: 5)
        try project.nudgeAdditionalTrackClip(id: picture, byFrames: 1)
        #expect(project.track(id: additional)?.clips.first?.timelineStart == ProjectTime(seconds: 1.0 / 30))
        #expect(project.timelineClip(id: linkedAudio)?.timelineStart == project.timelineClip(id: picture)?.timelineStart)
    }

    @Test func pickupArrowsAndDropKeepRowsStableUntilOneCommittedMove() throws {
        let asset = fixtureAsset(name: "Footage", duration: 12)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        let second = try project.append(asset: asset, segments: [segment(2, 2)])
        let third = try project.append(asset: asset, segments: [segment(4, 2)])
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 3)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let focusRequests = controller.timelineFocusRestoreRequest
        controller.beginClipMovement(id: first)
        controller.moveMarkedClip(by: 1)
        controller.moveMarkedClip(by: 1)
        #expect(controller.project == project)
        #expect(controller.movementPreview?.primaryTimeline.map(\.id) == [second, third, first])
        #expect(controller.movementPositionDescription == "Position 3 of 3, Primary Video track")
        #expect(controller.currentTimelineClip(at: controller.timelinePlayhead)?.id == second)
        #expect(controller.movingTimelineClipID == first)
        #expect(controller.timelineFocusRestoreRequest == focusRequests)
        #expect(!undo.canUndo)
        undo.beginUndoGrouping()
        controller.toggleClipMovement(id: first)
        undo.endUndoGrouping()
        #expect(controller.project.primaryTimeline.map(\.id) == [second, third, first])
        #expect(controller.movingTimelineClipID == nil)
        #expect(controller.movementPositionDescription == nil)
        undo.undo()
        #expect(controller.project == project)
        #expect(!undo.canUndo)
    }

    @Test func cancelledOrReturnedMovementDoesNotChangeTheProject() throws {
        let asset = fixtureAsset(name: "Audio", duration: 6)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        _ = try project.append(asset: asset, segments: [segment(2, 2)])
        let audioID = try #require(project.timelineClip(id: first)?.linkedClipID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.beginClipMovement(id: audioID)
        controller.moveMarkedClip(by: 1)
        controller.moveMarkedClip(by: -1)
        controller.finishClipMovement()
        #expect(controller.project == project)
        controller.beginClipMovement(id: first)
        controller.moveMarkedClip(by: 1)
        controller.cancelClipMovement()
        #expect(controller.project == project)
        #expect(controller.movingTimelineClipID == nil)
    }

    @Test func currentClipDoesNotFollowFocusOrReachAcrossAGap() throws {
        let asset = fixtureAsset(name: "Footage", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let trackID = project.createTrack(kind: .video)
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: trackID)
        let second = try project.append(asset: asset, segments: [segment(2, 2)], toTrack: trackID)
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 5)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = trackID
        controller.focusTimelineElement(.clip(second))
        #expect(controller.currentTimelineClip(at: ProjectTime(seconds: 1))?.id == first)
        #expect(controller.currentTimelineClip(at: ProjectTime(seconds: 3)) == nil)
        #expect(controller.currentTimelineClip(at: ProjectTime(seconds: 5))?.id == second)
        #expect(controller.currentTimelineClip(at: ProjectTime(seconds: 7)) == nil)
        #expect(controller.movingTimelineClipID == nil)
    }

    @Test func moveToTrackEdgesWorksForFocusedClipWithoutClipboardState() throws {
        let asset = fixtureAsset(name: "Footage", duration: 6)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        let second = try project.append(asset: asset, segments: [segment(2, 2)])
        let controller = ProjectController(document: ProjectDocument(project: project))
        #expect(controller.canMoveClip(to: .end, targetID: first))
        controller.moveClip(to: .end, targetID: first)
        #expect(controller.project.primaryTimeline.map(\.id) == [second, first])
    }

    @Test func repeatedInsertionsAdvancePlayheadAndKeepSourceOrder() throws {
        let asset = fixtureAsset(name: "Footage", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset, segments: [segment(0, 8)])
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 4)
        var inserted: [UUID] = []
        for sourceStart in [10.0, 12.0, 14.0] {
            inserted.append(try controller.placeThrowing(.insert, editing: .asset(asset.id), segments: [segment(sourceStart, 2)]))
        }
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 10))
        #expect(Array(controller.project.primaryTimeline.dropFirst().prefix(3).map(\.id)) == inserted)
        #expect(inserted.compactMap { controller.project.timelineClip(id: $0)?.timelineStart.seconds } == [4, 6, 8])
    }

    @Test func explicitAndNewTrackInsertionsAdvanceTheSharedPlayhead() throws {
        let asset = fixtureAsset(name: "Music", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        let trackID = project.createTrack(kind: .audio)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.timelinePlayhead = ProjectTime(seconds: 4)
        let first = try controller.placeThrowing(.insert, editing: .asset(asset.id), segments: [segment(0, 2)], onTrack: trackID)
        let second = try controller.placeThrowing(.insert, editing: .asset(asset.id), segments: [segment(2, 2)], onTrack: trackID)
        #expect(controller.project.track(id: trackID)?.sortedClips.map(\.id) == [first, second])
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 8))
        _ = try controller.createTrackAndPlaceThrowing(.insert, editing: .asset(asset.id), segments: [segment(4, 2)], trackKind: .audio, trackName: "New music", audioSettings: nil)
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 10))
        #expect(throws: ProjectTimelineError.emptyIncomingClip) {
            try controller.placeThrowing(.insert, editing: .asset(asset.id), segments: [], onTrack: trackID)
        }
        #expect(controller.timelinePlayhead == ProjectTime(seconds: 10))
    }

    @Test func primaryMoveSurvivesLaterInsertionAndKeepsLinkedAudio() throws {
        let asset = fixtureAsset(name: "Footage", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        let second = try project.append(asset: asset, segments: [segment(2, 2)])
        let third = try project.append(asset: asset, segments: [segment(4, 2)])
        try project.moveTrackClip(id: first, after: third)
        #expect(project.primaryTimeline.map(\.id) == [second, third, first])
        let inserted = try project.insert(asset: asset, segments: [segment(6, 2)], at: ProjectTime(seconds: 6))
        #expect(project.primaryTimeline.map(\.id) == [second, third, first, inserted])
        for video in try #require(project.tracks.first { $0.role == .primaryVideo }).clips {
            let audio = try #require(video.linkedClipID.flatMap { project.timelineClip(id: $0) })
            #expect(audio.timelineStart == video.timelineStart)
            #expect(audio.segments == video.segments)
        }
    }

    @Test func movementSelectionDoesNotFollowDestinationFocusAndSupportsUndo() throws {
        let asset = fixtureAsset(name: "Footage", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        let second = try project.append(asset: asset, segments: [segment(2, 2)])
        let controller = ProjectController(document: ProjectDocument(project: project))
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        controller.toggleClipMovement(id: first)
        controller.focusTimelineElement(.clip(second))
        #expect(controller.movingTimelineClipID == first)
        undo.beginUndoGrouping()
        controller.moveClip(to: .after, targetID: second)
        undo.endUndoGrouping()
        #expect(controller.project.primaryTimeline.map(\.id) == [second, first])
        undo.undo()
        #expect(controller.project.primaryTimeline.map(\.id) == [first, second])
        undo.redo()
        #expect(controller.project.primaryTimeline.map(\.id) == [second, first])
        controller.finishClipMovement()
        #expect(controller.movingTimelineClipID == nil)
    }

    @Test func movingAdditionalClipsPreservesTrackOffsetAndGaps() throws {
        let asset = fixtureAsset(name: "Music", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio)
        let first = try project.append(asset: asset, segments: [segment(0, 2)], toTrack: track)
        let second = try project.append(asset: asset, segments: [segment(2, 3)], toTrack: track)
        project.tracks[0].clips[0].timelineStart = ProjectTime(seconds: 5)
        project.tracks[0].clips[1].timelineStart = ProjectTime(seconds: 9)
        try project.moveTrackClip(id: second, to: .start, targetID: first)
        #expect(project.tracks[0].sortedClips.map(\.id) == [second, first])
        #expect(project.timelineClip(id: second)?.timelineStart == ProjectTime(seconds: 5))
        #expect(project.timelineClip(id: first)?.timelineStart == ProjectTime(seconds: 10))
    }

    @Test func moveThatSeparatesTransitionIsTransactional() throws {
        let asset = fixtureAsset(name: "Music", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let track = project.createTrack(kind: .audio)
        let first = try project.append(asset: asset, segments: [segment(2, 3)], toTrack: track)
        let second = try project.append(asset: asset, segments: [segment(8, 3)], toTrack: track)
        let third = try project.append(asset: asset, segments: [segment(14, 3)], toTrack: track)
        try project.addTransition(TimelineTransition(trackID: track, edge: .between, kind: .audio(.crossFade), duration: ProjectTime(seconds: 1), leadingClipID: first, trailingClipID: second))
        let before = project
        #expect(throws: (any Error).self) { try project.moveTrackClip(id: first, after: third) }
        #expect(project == before)
    }

    @Test func trackMuteSurvivesInsertionAndUndo() throws {
        let asset = fixtureAsset(name: "Footage", duration: 10)
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let track = try #require(project.tracks.first { $0.kind == .audio })
        controller.activeTimelineTrackID = track.id
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        undo.beginUndoGrouping()
        controller.setActiveTrackMuted(true)
        undo.endUndoGrouping()
        #expect(controller.project.track(id: track.id)?.isMuted == true)
        undo.undo()
        #expect(controller.project.track(id: track.id)?.isMuted == false)
        undo.redo()
        undo.beginUndoGrouping()
        _ = try controller.placeThrowing(.insert, editing: .asset(asset.id), segments: [segment(0, 2)])
        undo.endUndoGrouping()
        #expect(controller.project.track(id: track.id)?.isMuted == true)
    }

    @Test func moveToStartCanUseAnEmptyCompatibleTrack() throws {
        let asset = fixtureAsset(name: "Music", duration: 4)
        var project = TrimatoProject()
        project.media = [asset]
        let source = project.createTrack(kind: .audio, name: "Music")
        let destination = project.createTrack(kind: .audio, name: "Effects")
        let clipID = try project.append(asset: asset, toTrack: source)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.toggleClipMovement(id: clipID)
        controller.activeTimelineTrackID = destination
        controller.moveClip(to: .start, targetID: clipID)
        #expect(controller.project.track(id: source)?.clips.isEmpty == true)
        #expect(controller.project.track(id: destination)?.clips.first?.id == clipID)
        #expect(controller.project.timelineClip(id: clipID)?.timelineStart == .zero)
    }

    @Test func independentlyMovedAudioSurvivesLaterPictureInsertionAndSave() throws {
        let asset = fixtureAsset(name: "Footage", duration: 12)
        var project = TrimatoProject()
        project.media = [asset]
        let first = try project.append(asset: asset, segments: [segment(0, 2)])
        let second = try project.append(asset: asset, segments: [segment(2, 2)])
        let firstAudio = try #require(project.timelineClip(id: first)?.linkedClipID)
        let secondAudio = try #require(project.timelineClip(id: second)?.linkedClipID)
        try project.moveTrackClip(id: firstAudio, after: secondAudio)
        #expect(project.timelineClip(id: firstAudio)?.isIndependentAudio == true)
        let saved = try ProjectDocument.manifestData(for: project)
        project = try JSONDecoder().decode(TrimatoProject.self, from: saved)
        _ = try project.append(asset: asset, segments: [segment(4, 2)])
        #expect(project.timelineClip(id: firstAudio)?.timelineStart == ProjectTime(seconds: 2))
        #expect(project.timelineClip(id: secondAudio)?.timelineStart == .zero)
        #expect(project.timelineClip(id: first)?.linkedClipID == nil)
        #expect(project.timelineClip(id: second)?.linkedClipID == nil)
    }

    @Test func primaryAudioSplitAndDeletionDoNotLeaveOldClipsBehind() throws {
        var asset = fixtureAsset(name: "Audio", duration: 6)
        asset.naturalWidth = nil
        asset.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [asset]
        let original = try project.append(asset: asset)
        let second = try project.splitClip(id: original, atTimelineTime: ProjectTime(seconds: 3))
        #expect(project.tracks.flatMap(\.clips).count == 2)
        #expect(project.timelineClip(id: original) == nil)
        try project.removeTrackClip(id: second)
        #expect(project.tracks.flatMap(\.clips).count == 1)
        #expect(project.duration == ProjectTime(seconds: 3))
    }

    @Test func legacyVideoAndAudioMigrateIntoLinkedPrimaryTracks() throws {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var legacy = TrimatoProject()
        legacy.media = [asset]
        _ = try legacy.append(asset: asset)
        let data = try ProjectDocument.manifestData(for: legacy)

        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)

        let video = try #require(decoded.tracks.first { $0.role == .primaryVideo }?.clips.first)
        let audio = try #require(decoded.tracks.first { $0.role == .primaryAudio }?.clips.first)
        #expect(video.linkedClipID == audio.id)
        #expect(audio.linkedClipID == video.id)
        #expect(audio.displayName == "Interview Audio")
    }

    @Test func additionalTrackEditsRemainMagneticWithinThatTrack() throws {
        var music = fixtureAsset(name: "Music", duration: 12)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let firstID = try project.append(asset: music, segments: [segment(0, 4)], toTrack: trackID)
        let secondID = try project.append(asset: music, segments: [segment(4, 4)], toTrack: trackID)

        try project.updateTrackClip(id: firstID, segments: [segment(0, 2)])

        #expect(project.timelineClip(id: secondID)?.timelineStart == ProjectTime(seconds: 2))
        #expect(project.track(id: trackID)?.end == ProjectTime(seconds: 6))
    }

    @Test func crossFadeRequiresAdjacentClipsAndAvailableHandles() throws {
        var audio = fixtureAsset(name: "Music", duration: 20)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let firstID = try project.append(asset: audio, segments: [segment(2, 5)], toTrack: trackID)
        let secondID = try project.append(asset: audio, segments: [segment(10, 5)], toTrack: trackID)
        let transition = TimelineTransition(
            trackID: trackID,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: firstID,
            trailingClipID: secondID
        )

        try project.addTransition(transition)

        #expect(project.transitions == [transition])
        project.removeTransition(id: transition.id)
        #expect(project.transitions.isEmpty)
        #expect(project.timelineClip(id: secondID)?.timelineStart == ProjectTime(seconds: 5))
    }

    @Test func linkedVideoAndAudioTransitionsShareADeletedBundle() throws {
        let asset = fixtureAsset(name: "Interview", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let leadingVideoID = try project.append(asset: asset, segments: [segment(2, 5)])
        let trailingVideoID = try project.append(asset: asset, segments: [segment(10, 5)])
        let videoTrack = try #require(project.tracks.first { $0.role == .primaryVideo })
        let audioTrack = try #require(project.tracks.first { $0.role == .primaryAudio })
        let leadingAudioID = try #require(project.timelineClip(id: leadingVideoID)?.linkedClipID)
        let trailingAudioID = try #require(project.timelineClip(id: trailingVideoID)?.linkedClipID)
        let video = TimelineTransition(
            trackID: videoTrack.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingVideoID,
            trailingClipID: trailingVideoID
        )
        let audio = TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID
        )

        let added = try project.addTransitionBatch([video, audio])

        let bundleID = try #require(added.first?.bundleID)
        #expect(added.allSatisfy { $0.bundleID == bundleID })
        #expect(project.transitions.count == 2)

        project.removeTransition(id: video.id)

        #expect(project.transitions.isEmpty)
    }

    @Test func pairedAdditionAdoptsACompatibleOrphanedAudioTransition() throws {
        let asset = fixtureAsset(name: "Interview", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let leadingVideoID = try project.append(asset: asset, segments: [segment(2, 5)])
        let trailingVideoID = try project.append(asset: asset, segments: [segment(10, 5)])
        let videoTrack = try #require(project.tracks.first { $0.role == .primaryVideo })
        let audioTrack = try #require(project.tracks.first { $0.role == .primaryAudio })
        let leadingAudioID = try #require(project.timelineClip(id: leadingVideoID)?.linkedClipID)
        let trailingAudioID = try #require(project.timelineClip(id: trailingVideoID)?.linkedClipID)
        let orphanedAudio = TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID
        )
        try project.addTransition(orphanedAudio)
        let video = TimelineTransition(
            trackID: videoTrack.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingVideoID,
            trailingClipID: trailingVideoID
        )
        let replacementAudio = TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID
        )

        let added = try project.addTransitionBatch([video, replacementAudio])

        #expect(project.transitions.count == 2)
        #expect(added[1].id == orphanedAudio.id)
        #expect(added[0].bundleID != nil)
        #expect(added[0].bundleID == added[1].bundleID)
    }

    @Test func aNamedAudioTransitionIsNotAdoptedAsALegacyOrphan() throws {
        let asset = fixtureAsset(name: "Interview", duration: 20)
        var project = TrimatoProject()
        project.media = [asset]
        let leadingVideoID = try project.append(asset: asset, segments: [segment(2, 5)])
        let trailingVideoID = try project.append(asset: asset, segments: [segment(10, 5)])
        let videoTrack = try #require(project.tracks.first { $0.role == .primaryVideo })
        let audioTrack = try #require(project.tracks.first { $0.role == .primaryAudio })
        let leadingAudioID = try #require(project.timelineClip(id: leadingVideoID)?.linkedClipID)
        let trailingAudioID = try #require(project.timelineClip(id: trailingVideoID)?.linkedClipID)
        let independentAudio = TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID,
            customName: "Independent Audio Blend"
        )
        try project.addTransition(independentAudio)
        let video = TimelineTransition(
            trackID: videoTrack.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingVideoID,
            trailingClipID: trailingVideoID
        )
        let audio = TimelineTransition(
            trackID: audioTrack.id,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2),
            leadingClipID: leadingAudioID,
            trailingClipID: trailingAudioID
        )

        #expect(throws: ProjectTimelineError.transitionNotAvailable("A transition already exists at this edit.")) {
            try project.addTransitionBatch([video, audio])
        }
        #expect(project.transitions == [independentAudio])
    }

    @Test func transitionDisplayNameUsesAnEditableNameWithATypeFallback() {
        var transition = TimelineTransition(
            trackID: UUID(),
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: UUID(),
            trailingClipID: UUID()
        )

        #expect(transition.displayName == "Cross Dissolve")
        transition.customName = "  First Interview Blend  "
        #expect(transition.displayName == "First Interview Blend")
        transition.customName = "   "
        #expect(transition.displayName == "Cross Dissolve")
    }

    @Test @MainActor func timelineFocusRequestsRetainTheExactTransitionTarget() {
        let controller = ProjectController(document: ProjectDocument())
        let transitionID = UUID()

        controller.requestTimelineFocusRestore(to: .transition(transitionID))

        #expect(controller.timelineFocusRestoreRequest == 1)
        #expect(controller.timelineFocusRestoreTarget == .transition(transitionID))
    }

    @Test @MainActor func keyboardTrackSwitchRequestsTheNamedTimelineList() throws {
        var audio = fixtureAsset(name: "Music", duration: 10)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let firstTrackID = project.createTrack(kind: .audio, name: "Dialogue")
        let secondTrackID = project.createTrack(kind: .audio, name: "Music")
        _ = try project.append(asset: audio, segments: [segment(0, 4)], toTrack: secondTrackID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = firstTrackID

        controller.selectAdjacentTrack(1)

        #expect(controller.activeTimelineTrackID == secondTrackID)
        #expect(controller.timelineListFocusRestoreRequest == 0)
        #expect(controller.timelineFocusRestoreRequest == 1)
        #expect(controller.timelineTrackPickerFocusRestoreRequest == 0)
        #expect(TimelineAccessibility.clipsListLabel(trackName: "Music") == "Timeline Clips, Music track")
    }

    @Test func musicClipTrimsToTheSharedProjectPlayheadAndMovesLaterMusicEarlier() throws {
        var music = fixtureAsset(name: "Music", duration: 70)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Musica")
        let firstID = try project.append(asset: music, segments: [segment(0, 60)], toTrack: trackID)
        let secondID = try project.append(asset: music, segments: [segment(60, 5)], toTrack: trackID)
        let videoEnd = ProjectTime(seconds: 14.408)

        try project.trimTrackClipEnd(id: firstID, at: videoEnd)

        #expect(project.timelineClip(id: firstID)?.duration == videoEnd)
        #expect(project.timelineClip(id: secondID)?.timelineStart == videoEnd)
        #expect(project.timelineClip(id: firstID)?.segments.first?.sourceRange.start == .zero)
    }

    @Test func aligningAnAdditionalClipTailBeforeZeroKeepsAndRevealsItsSource() throws {
        var music = fixtureAsset(name: "Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Musica")
        let sourceSegments = [segment(0, 30), segment(30, 30)]
        let clipID = try project.append(asset: music, segments: sourceSegments, toTrack: trackID)

        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 15)
        )

        var clip = try #require(project.timelineClip(id: clipID))
        #expect(clip.timelineStart == ProjectTime(seconds: -45))
        #expect(clip.segments == sourceSegments)
        #expect(clip.hiddenBeforeTimeline == ProjectTime(seconds: 45))
        #expect(clip.visibleTimelineStart == .zero)
        #expect(clip.visibleDuration == ProjectTime(seconds: 15))
        #expect(clip.visibleSegments.map(\.sourceRange) == [segment(45, 15).sourceRange])

        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 20)
        )

        clip = try #require(project.timelineClip(id: clipID))
        #expect(clip.timelineStart == ProjectTime(seconds: -40))
        #expect(clip.segments == sourceSegments)
        #expect(clip.visibleDuration == ProjectTime(seconds: 20))
        #expect(clip.visibleSegments.map(\.sourceRange) == [segment(40, 20).sourceRange])
    }

    @Test func aligningAnAdditionalClipHeadMovesTheWholeClipWithoutChangingItsSource() throws {
        var effect = fixtureAsset(name: "Effect", duration: 6)
        effect.naturalWidth = nil
        effect.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [effect]
        let trackID = project.createTrack(kind: .audio, name: "Sound Effects")
        let clipID = try project.append(asset: effect, toTrack: trackID)
        let originalSegments = try #require(project.timelineClip(id: clipID)?.segments)

        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .head,
            at: ProjectTime(seconds: 20)
        )

        let clip = try #require(project.timelineClip(id: clipID))
        #expect(clip.timelineStart == ProjectTime(seconds: 20))
        #expect(clip.timelineEnd == ProjectTime(seconds: 26))
        #expect(clip.segments == originalSegments)
        #expect(clip.hiddenBeforeTimeline == .zero)
    }

    @Test func absolutePositioningRejectsSameTrackOverlapAndAttachedTransitions() throws {
        var audio = fixtureAsset(name: "Effect", duration: 20)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let trackID = project.createTrack(kind: .audio, name: "Effects")
        let firstID = try project.append(asset: audio, segments: [segment(0, 5)], toTrack: trackID)
        let secondID = try project.append(asset: audio, segments: [segment(5, 5)], toTrack: trackID)

        #expect(throws: ProjectTimelineError.clipPositionOverlap("Effects")) {
            try project.positionAdditionalTrackClip(
                id: secondID,
                edge: .head,
                at: ProjectTime(seconds: 2)
            )
        }

        let transition = TimelineTransition(
            trackID: trackID,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: firstID,
            trailingClipID: secondID
        )
        try project.addTransition(transition)
        #expect(throws: ProjectTimelineError.clipPositionHasTransition) {
            try project.positionAdditionalTrackClip(
                id: firstID,
                edge: .tail,
                at: ProjectTime(seconds: 4)
            )
        }
        let beforeNudge = project
        #expect(throws: ProjectTimelineError.clipPositionHasTransition) {
            try project.nudgeAdditionalTrackClip(id: firstID, byFrames: 1)
        }
        #expect(project == beforeNudge)
    }

    @Test @MainActor func editorPositioningUsesTheActiveTracksRememberedClipWithoutTimelineFocus() throws {
        var music = fixtureAsset(name: "Amsterdam Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let dialogueID = project.createTrack(kind: .audio, name: "Dialogue")
        let musicID = project.createTrack(kind: .audio, name: "Musica")
        _ = try project.append(asset: music, segments: [segment(0, 5)], toTrack: dialogueID)
        let clipID = try project.append(asset: music, toTrack: musicID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = dialogueID
        controller.timelinePlayhead = ProjectTime(seconds: 15)

        controller.selectAdjacentTrack(1, restoreTimelineFocus: false)

        #expect(controller.activeTimelineTrackID == musicID)
        #expect(controller.timelineFocusRestoreRequest == 0)
        #expect(controller.timelineListFocusRestoreRequest == 0)
        #expect(ProjectController.activeTrackAnnouncement(
            trackName: "Musica",
            clipName: "Amsterdam Music"
        ) == "Musica track, Amsterdam Music selected")

        controller.positionActiveAdditionalTrackClip(edge: .tail, at: ProjectTime(seconds: 15))
        #expect(controller.project.timelineClip(id: clipID)?.timelineStart == ProjectTime(seconds: -45))
        #expect(controller.selection == .project)
        #expect(controller.timelineFocusRestoreRequest == 0)
        #expect(controller.timelineListFocusRestoreRequest == 0)
        #expect(controller.timelineTrackPickerFocusRestoreRequest == 0)

        controller.positionActiveAdditionalTrackClip(edge: .tail, at: ProjectTime(seconds: 20))
        #expect(controller.project.timelineClip(id: clipID)?.timelineStart == ProjectTime(seconds: -40))
    }

    @Test func timelineTrimRequiresThePlayheadInsideTheFocusedClip() throws {
        var music = fixtureAsset(name: "Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Musica")
        let clipID = try project.append(asset: music, toTrack: trackID)

        #expect(throws: ProjectTimelineError.cannotTrimAtPlayhead) {
            try project.trimTrackClipEnd(id: clipID, at: ProjectTime(seconds: 60))
        }
    }

    @Test @MainActor func editorTrimUsesTheActiveTracksRememberedClipWithoutMovingFocus() throws {
        var music = fixtureAsset(name: "Amsterdam Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Musica")
        let clipID = try project.append(asset: music, toTrack: trackID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = trackID

        controller.trimActiveTrackClip(edge: .head, at: ProjectTime(seconds: 15))

        let headTrimmed = try #require(controller.project.timelineClip(id: clipID))
        #expect(headTrimmed.timelineStart == ProjectTime(seconds: 15))
        #expect(headTrimmed.timelineEnd == ProjectTime(seconds: 60))
        #expect(headTrimmed.segments.first?.sourceRange.start == ProjectTime(seconds: 15))
        #expect(controller.selection == .project)
        #expect(controller.timelineFocusRestoreRequest == 0)
        #expect(controller.timelineListFocusRestoreRequest == 0)
        #expect(controller.timelineTrackPickerFocusRestoreRequest == 0)

        controller.trimActiveTrackClip(edge: .tail, at: ProjectTime(seconds: 40))

        let fullyTrimmed = try #require(controller.project.timelineClip(id: clipID))
        #expect(fullyTrimmed.timelineStart == ProjectTime(seconds: 15))
        #expect(fullyTrimmed.timelineEnd == ProjectTime(seconds: 40))
        #expect(controller.selection == .project)
        #expect(controller.timelineFocusRestoreRequest == 0)
        #expect(controller.timelineListFocusRestoreRequest == 0)
        #expect(controller.timelineTrackPickerFocusRestoreRequest == 0)
    }

    @Test @MainActor func editorHeadTrimRemovesSourceHiddenBeforeProjectStart() throws {
        var music = fixtureAsset(name: "Amsterdam Music", duration: 60)
        music.naturalWidth = nil
        music.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [music]
        let trackID = project.createTrack(kind: .audio, name: "Musica")
        let clipID = try project.append(asset: music, toTrack: trackID)
        try project.positionAdditionalTrackClip(
            id: clipID,
            edge: .tail,
            at: ProjectTime(seconds: 15)
        )
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = trackID

        controller.trimActiveTrackClip(edge: .head, at: ProjectTime(seconds: 5))

        let trimmed = try #require(controller.project.timelineClip(id: clipID))
        #expect(trimmed.timelineStart == ProjectTime(seconds: 5))
        #expect(trimmed.timelineEnd == ProjectTime(seconds: 15))
        #expect(trimmed.segments.first?.sourceRange.start == ProjectTime(seconds: 50))
    }

    @Test @MainActor func keyboardTrackSwitchRequestsTheTimelineListForAnEmptyTrack() throws {
        var audio = fixtureAsset(name: "Dialogue", duration: 10)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let firstTrackID = project.createTrack(kind: .audio, name: "Dialogue")
        let secondTrackID = project.createTrack(kind: .audio, name: "Music")
        _ = try project.append(asset: audio, segments: [segment(0, 4)], toTrack: firstTrackID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = firstTrackID

        controller.selectAdjacentTrack(1)

        #expect(controller.activeTimelineTrackID == secondTrackID)
        #expect(controller.timelineListFocusRestoreRequest == 1)
        #expect(controller.timelineTrackPickerFocusRestoreRequest == 0)
        #expect(controller.timelineFocusRestoreRequest == 0)
    }

    @Test func timelineElementIdentifiersResolveTheActualFocusedControl() {
        let clipID = UUID()
        let transitionID = UUID()

        #expect(TimelineElementAccessibilityIdentifier.selection(
            from: TimelineElementAccessibilityIdentifier.clip(clipID)
        ) == .clip(clipID))
        #expect(TimelineElementAccessibilityIdentifier.selection(
            from: TimelineElementAccessibilityIdentifier.transition(transitionID)
        ) == .transition(transitionID))
        #expect(TimelineElementAccessibilityIdentifier.selection(from: "trimato.timeline.clips") == nil)
    }

    @Test func clipDeletionConfirmationIsNamedAndExplainsUndo() {
        #expect(TimelineClipDeletionConfirmation.title == "Delete Clip?")
        #expect(TimelineClipDeletionConfirmation.message(clipName: "Interview") ==
                "Remove Interview from the timeline? This can be undone.")
    }

    @Test func clipDeletionFocusChoosesTheNextThenPreviousElement() throws {
        var audio = fixtureAsset(name: "Music", duration: 12)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let firstID = try project.append(asset: audio, segments: [segment(0, 4)], toTrack: trackID)
        let middleID = try project.append(asset: audio, segments: [segment(4, 4)], toTrack: trackID)
        let lastID = try project.append(asset: audio, segments: [segment(8, 4)], toTrack: trackID)
        let track = try #require(project.track(id: trackID))
        let elements = TimelineElementSequence.elements(track: track, transitions: [])

        #expect(TimelineElementSequence.focusTargetAfterDeletingClip(firstID, from: elements) == .clip(middleID))
        #expect(TimelineElementSequence.focusTargetAfterDeletingClip(middleID, from: elements) == .clip(lastID))
        #expect(TimelineElementSequence.focusTargetAfterDeletingClip(lastID, from: elements) == .clip(middleID))
        #expect(TimelineElementSequence.focusTargetAfterDeletingClip(
            firstID,
            from: [TimelineListElement(content: .clip(try #require(project.timelineClip(id: firstID))))]
        ) == nil)
    }

    @Test func clipDeletionFocusSkipsTransitionsRemovedWithTheClip() throws {
        var audio = fixtureAsset(name: "Music", duration: 8)
        audio.naturalWidth = nil
        audio.naturalHeight = nil
        var project = TrimatoProject()
        project.media = [audio]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let firstID = try project.append(asset: audio, segments: [segment(0, 4)], toTrack: trackID)
        let secondID = try project.append(asset: audio, segments: [segment(4, 4)], toTrack: trackID)
        let transition = TimelineTransition(
            trackID: trackID,
            edge: .between,
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: firstID,
            trailingClipID: secondID
        )
        let elements = [
            TimelineListElement(content: .clip(try #require(project.timelineClip(id: firstID)))),
            TimelineListElement(content: .transition(transition)),
            TimelineListElement(content: .clip(try #require(project.timelineClip(id: secondID)))),
        ]

        #expect(TimelineElementSequence.focusTargetAfterDeletingClip(firstID, from: elements) == .clip(secondID))
    }

    @Test func ffmpegFiltersUseAccessibleEditorValues() {
        let settings = AudioClipSettings(
            gainDecibels: 3,
            lowGainDecibels: -2,
            midGainDecibels: 0,
            highGainDecibels: 1,
            highPassEnabled: true,
            highPassFrequency: 90,
            lowPassEnabled: false,
            lowPassFrequency: 16_000
        )

        let filter = FFmpegTimelineEffectRenderer.audioFilter(for: settings)

        #expect(filter?.contains("volume=3dB") == true)
        #expect(filter?.contains("equalizer=f=100") == true)
        #expect(filter?.contains("highpass=f=90") == true)
        #expect(FFmpegTimelineEffectRenderer.videoTransitionName(.wipeLeft) == "wipeleft")
        #expect(FFmpegTimelineEffectRenderer.crossFilter(
            kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 1),
            offset: .zero
        ).hasPrefix("acrossfade="))
    }

    @Test func transitionDurationAcceptsFractionalSecondsAndKeepsSpokenUnit() throws {
        #expect(TransitionDurationInput.defaultText == "1.0")
        #expect(TransitionDurationInput.accessibilityLabel == "Duration in Seconds")
        #expect(TransitionDurationInput.parse("1.25") == ProjectTime(seconds: 1.25))
        #expect(TransitionDurationInput.parse("0") == nil)
        #expect(TransitionDurationInput.parse("seconds") == nil)
        #expect(TransitionDurationInput.string(for: ProjectTime(seconds: 1)) == "1.0")
        #expect(TransitionDurationInput.string(for: ProjectTime(seconds: 1.25)) == "1.25")
        #expect(TransitionDurationInput.accessibilityValue(for: "2.0") == "2.0 seconds")
        #expect(TransitionDurationInput.accessibilityValue(for: "") == "No value")
    }

    @Test func audioCrossFadeGraphBlendsWhileFadeOutInRemainsSequential() {
        let crossFade = FFmpegTimelineEffectRenderer.audioCrossFadeGraph(
            leadingStart: 1,
            trailingStart: 2,
            duration: 1,
            leadingSettings: AudioClipSettings(),
            trailingSettings: AudioClipSettings(),
            format: AudioTransitionFormat(sampleRate: 44_100, channelLayout: "mono")
        )
        let fadeOutIn = FFmpegTimelineEffectRenderer.audioFadeOutInGraph(
            leadingStart: 1,
            trailingStart: 2,
            duration: 1,
            leadingSettings: AudioClipSettings(),
            trailingSettings: AudioClipSettings()
        )

        let equalPower = FFmpegTimelineEffectRenderer.audioCrossFadeGraph(
            leadingStart: 1,
            trailingStart: 2,
            duration: 1,
            leadingSettings: AudioClipSettings(),
            trailingSettings: AudioClipSettings(),
            format: AudioTransitionFormat(sampleRate: 44_100, channelLayout: "mono"),
            curve: .equalPower
        )

        #expect(crossFade.contains("[a0][a1]acrossfade=d=1:o=1:c1=tri:c2=tri"))
        #expect(equalPower.contains("[a0][a1]acrossfade=d=1:o=1:c1=qsin:c2=qsin"))
        #expect(crossFade.components(separatedBy: "aresample=44100:async=1:first_pts=0").count == 3)
        #expect(crossFade.components(separatedBy: "channel_layouts=mono").count == 3)
        #expect(crossFade.components(separatedBy: "atrim=end_sample=44100").count == 4)
        #expect(!crossFade.contains("sample_rates=48000"))
        #expect(!crossFade.contains("channel_layouts=stereo"))
        #expect(!crossFade.contains("asetpts=N/SR/TB"))
        #expect(!crossFade.contains("concat="))
        #expect(fadeOutIn.contains("afade=t=out"))
        #expect(fadeOutIn.contains("afade=t=in"))
        #expect(fadeOutIn.contains("concat=n=2:v=0:a=1"))
        #expect(!fadeOutIn.contains("acrossfade="))
    }

    @Test @MainActor func audioTransitionFormatUsesTheProbedProjectReference() {
        let reference = FFmpegMediaProbe.Report.Stream(
            codecType: "audio",
            sampleRate: "44100",
            sampleFormat: "s16",
            channels: 1,
            channelLayout: "mono"
        )
        let trailing = FFmpegMediaProbe.Report.Stream(
            codecType: "audio",
            sampleRate: "48000",
            sampleFormat: "fltp",
            channels: 2,
            channelLayout: "stereo"
        )

        let format = AudioTransitionFormat(
            reference: reference,
            leading: reference,
            trailing: trailing
        )

        #expect(format == AudioTransitionFormat(sampleRate: 44_100, channelLayout: "mono"))
        #expect(format.filterSuffix.contains("aresample=44100"))
        #expect(format.filterSuffix.contains("channel_layouts=mono"))
    }

    @Test @MainActor func renderedThreeSecondCrossFadeContainsBothSourcesThroughoutTheOverlap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leadingURL = directory.appendingPathComponent("leading.wav")
        let trailingURL = directory.appendingPathComponent("trailing.wav")
        try await makeStereoFixture(
            expression: "sin(2*PI*440*t)|0",
            outputURL: leadingURL
        )
        try await makeStereoFixture(
            expression: "0|sin(2*PI*660*t)",
            outputURL: trailingURL
        )

        let leadingClip = TimelineClip(
            assetID: UUID(),
            name: "Outgoing",
            segments: [segment(0, 3)]
        )
        let trailingClip = TimelineClip(
            assetID: UUID(),
            name: "Incoming",
            segments: [segment(3, 3)]
        )
        var progressValues: [Double] = []
        let renderedURL = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
            leadingURL: leadingURL,
            trailingURL: trailingURL,
            leadingClip: leadingClip,
            trailingClip: trailingClip,
            type: .crossFade,
            duration: ProjectTime(seconds: 3),
            progress: { progressValues.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: renderedURL) }

        let report = try await FFmpegMediaProbe.inspect(url: renderedURL)
        #expect(abs(report.duration - 3) < 0.02)
        #expect(progressValues.last == 1)
        #expect(zip(progressValues, progressValues.dropFirst()).allSatisfy { $0 <= $1 })

        let earlyLeft = try await meanVolume(
            url: renderedURL, channel: 0, start: 0.15, duration: 0.2
        )
        let earlyRight = try await meanVolume(
            url: renderedURL, channel: 1, start: 0.15, duration: 0.2
        )
        let middleLeft = try await meanVolume(
            url: renderedURL, channel: 0, start: 1.4, duration: 0.2
        )
        let middleRight = try await meanVolume(
            url: renderedURL, channel: 1, start: 1.4, duration: 0.2
        )
        let lateLeft = try await meanVolume(
            url: renderedURL, channel: 0, start: 2.65, duration: 0.2
        )
        let lateRight = try await meanVolume(
            url: renderedURL, channel: 1, start: 2.65, duration: 0.2
        )

        #expect(earlyLeft > earlyRight + 10)
        #expect(middleLeft > -12)
        #expect(middleRight > -12)
        #expect(lateRight > lateLeft + 10)
    }

    @Test @MainActor func delayedAACCrossFadeKeepsTheExactRequestedSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leadingURL = directory.appendingPathComponent("leading.mov")
        let trailingURL = directory.appendingPathComponent("trailing.mov")
        try await makeDelayedAACFixture(
            expression: "sin(2*PI*440*t)|0",
            delay: 0,
            outputURL: leadingURL
        )
        try await makeDelayedAACFixture(
            expression: "0|sin(2*PI*660*t)",
            delay: 0.3,
            outputURL: trailingURL
        )

        let leadingClip = TimelineClip(
            assetID: UUID(),
            name: "Outgoing",
            segments: [segment(2, 2)]
        )
        let trailingClip = TimelineClip(
            assetID: UUID(),
            name: "Incoming",
            segments: [segment(2, 2)]
        )
        let renderedURL = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
            leadingURL: leadingURL,
            trailingURL: trailingURL,
            leadingClip: leadingClip,
            trailingClip: trailingClip,
            type: .crossFade,
            duration: ProjectTime(seconds: 3)
        )
        defer { try? FileManager.default.removeItem(at: renderedURL) }

        let renderedAsset = AVURLAsset(url: renderedURL)
        let audioTrack = try #require(await renderedAsset.loadTracks(withMediaType: .audio).first)
        let timeRange = try await audioTrack.load(.timeRange)
        #expect(timeRange.start == .zero)
        #expect(timeRange.duration == CMTime(value: 144_000, timescale: 48_000))

        let middleLeft = try await meanVolume(
            url: renderedURL, channel: 0, start: 1.4, duration: 0.2
        )
        let middleRight = try await meanVolume(
            url: renderedURL, channel: 1, start: 1.4, duration: 0.2
        )
        #expect(abs(middleLeft - middleRight) < 1)
    }

    @Test @MainActor func renderedCrossDissolveUsesStableRateAndExactDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leadingURL = directory.appendingPathComponent("leading.mov")
        let trailingURL = directory.appendingPathComponent("trailing.mov")
        try await makeVideoFixture(color: "red", outputURL: leadingURL)
        try await makeVideoFixture(color: "blue", outputURL: trailingURL)
        let leadingClip = TimelineClip(
            assetID: UUID(),
            name: "Outgoing",
            segments: [segment(1.5, 3)]
        )
        let trailingClip = TimelineClip(
            assetID: UUID(),
            name: "Incoming",
            segments: [segment(1.5, 3)]
        )

        let renderedURL = try await FFmpegTimelineEffectRenderer.renderVideoTransition(
            leadingURL: leadingURL,
            trailingURL: trailingURL,
            leadingClip: leadingClip,
            trailingClip: trailingClip,
            type: .crossDissolve,
            duration: ProjectTime(seconds: 2),
            width: 320,
            height: 240,
            frameRate: 30.004427
        )
        defer { try? FileManager.default.removeItem(at: renderedURL) }
        let report = try await FFmpegMediaProbe.inspect(url: renderedURL)

        #expect(abs(report.duration - 2) < 0.001)
        #expect(report.frameRate == 30)
        #expect(report.videoStream?.width == 320)
        #expect(report.videoStream?.height == 240)
    }

    @Test @MainActor func completedTimelineMixDoesNotDoubleIncomingAudioDuringCrossFade() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leadingURL = directory.appendingPathComponent("leading.wav")
        let trailingURL = directory.appendingPathComponent("trailing.wav")
        try await makeStereoFixture(expression: "sin(2*PI*440*t)|0", outputURL: leadingURL)
        try await makeStereoFixture(expression: "0|sin(2*PI*660*t)", outputURL: trailingURL)

        for usesLinkedPrimaryTrack in [true, false] {
            var leadingAsset = fixtureAsset(name: "Outgoing", duration: 6)
            var trailingAsset = fixtureAsset(name: "Incoming", duration: 6)
            if !usesLinkedPrimaryTrack {
                leadingAsset.naturalWidth = nil
                leadingAsset.naturalHeight = nil
                trailingAsset.naturalWidth = nil
                trailingAsset.naturalHeight = nil
            }
            var project = TrimatoProject(name: "Cross fade mix")
            project.media = [leadingAsset, trailingAsset]
            let trackID: UUID
            let leadingID: UUID
            let trailingID: UUID
            if usesLinkedPrimaryTrack {
                let leadingVideoID = try project.append(asset: leadingAsset, segments: [segment(1.5, 3)])
                let trailingVideoID = try project.append(asset: trailingAsset, segments: [segment(1.5, 3)])
                let videoTrack = try #require(project.tracks.first { $0.role == .primaryVideo })
                let leadingVideo = try #require(videoTrack.clips.first { $0.id == leadingVideoID })
                let trailingVideo = try #require(videoTrack.clips.first { $0.id == trailingVideoID })
                let audioTrack = try #require(project.tracks.first { $0.role == .primaryAudio })
                trackID = audioTrack.id
                leadingID = try #require(leadingVideo.linkedClipID)
                trailingID = try #require(trailingVideo.linkedClipID)
            } else {
                trackID = project.createTrack(kind: .audio, name: "Music")
                leadingID = try project.append(
                    asset: leadingAsset,
                    segments: [segment(1.5, 3)],
                    toTrack: trackID
                )
                trailingID = try project.append(
                    asset: trailingAsset,
                    segments: [segment(1.5, 3)],
                    toTrack: trackID
                )
            }
            try project.addTransition(TimelineTransition(
                trackID: trackID,
                edge: .between,
                kind: .audio(.crossFade),
                duration: ProjectTime(seconds: 2),
                leadingClipID: leadingID,
                trailingClipID: trailingID
            ))

            var buildProgress: [Double] = []
            let result = try await ProjectCompositionBuilder.build(
                project: project,
                mediaURLs: [leadingAsset.id: leadingURL, trailingAsset.id: trailingURL],
                progress: { buildProgress.append($0) }
            )
            defer { result.temporaryMediaURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
            let outputURL = directory.appendingPathComponent(
                usesLinkedPrimaryTrack ? "primary-mix.wav" : "additional-mix.wav"
            )
            try await AudioOnlyExporter.export(
                asset: result.composition,
                audioMix: result.audioMix,
                timeRange: nil,
                format: .wav,
                to: outputURL,
                progress: { _ in }
            )

            let renderedTransitionURL = try #require(result.temporaryMediaURLs.first)
            let mixedIncoming = try await meanVolume(url: outputURL, channel: 1, start: 3.45, duration: 0.1)
            let renderedIncoming = try await meanVolume(
                url: renderedTransitionURL,
                channel: 1,
                start: 1.45,
                duration: 0.1
            )
            let middleOutgoing = try await meanVolume(url: outputURL, channel: 0, start: 2.95, duration: 0.1)
            let middleIncoming = try await meanVolume(url: outputURL, channel: 1, start: 2.95, duration: 0.1)
            let afterLeft = try await meanVolume(url: outputURL, channel: 0, start: 4.5, duration: 0.1)
            let afterRight = try await meanVolume(url: outputURL, channel: 1, start: 4.5, duration: 0.1)

            #expect(abs(mixedIncoming - renderedIncoming) < 1)
            #expect(middleOutgoing > -12)
            #expect(middleIncoming > -12)
            #expect(afterRight > afterLeft + 20)
            #expect(buildProgress.last == 0.9)
            #expect(zip(buildProgress, buildProgress.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test func transitionProgressUsesSpokenTenPercentMilestones() {
        #expect(TransitionProgressAccessibility.value(0) == "0 percent")
        #expect(TransitionProgressAccessibility.value(0.349) == "30 percent")
        #expect(TransitionProgressAccessibility.value(1) == "100 percent")
        #expect(TransitionProgressAccessibility.announcement(
            40,
            transitionName: "Cross Fade"
        ) == "Applying Cross Fade, 40 percent")
    }

    @Test func transitionFailuresUseSpecificNativeDialogContent() {
        let validation = TransitionPresentedError.invalidSettings("Enter a valid duration.")
        let application = TransitionPresentedError.applicationFailed(
            transitionName: "Cross Dissolve",
            message: "The preview could not be prepared."
        )

        #expect(validation.title == "Check transition settings")
        #expect(validation.message == "Enter a valid duration.")
        #expect(application.title == "Cross Dissolve could not be applied")
        #expect(application.message == "The preview could not be prepared.")
    }

    @Test func timelineElementsPlaceCrossTransitionsBetweenTheirClips() throws {
        let asset = fixtureAsset(name: "Interview", duration: 15)
        var project = TrimatoProject(name: "Three clips")
        project.media = [asset]
        let firstID = try project.append(asset: asset, segments: [segment(0, 5)])
        let secondID = try project.append(asset: asset, segments: [segment(5, 5)])
        let thirdID = try project.append(asset: asset, segments: [segment(10, 5)])
        let track = try #require(project.tracks.first { $0.kind == .video })
        let firstTransition = TimelineTransition(
            trackID: track.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: firstID,
            trailingClipID: secondID
        )
        let secondTransition = TimelineTransition(
            trackID: track.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: secondID,
            trailingClipID: thirdID
        )
        let finalFadeOut = TimelineTransition(
            trackID: track.id,
            edge: .outro,
            kind: .video(.fade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: thirdID,
            trailingClipID: nil
        )

        let elements = TimelineElementSequence.elements(
            track: track,
            transitions: [finalFadeOut, secondTransition, firstTransition]
        )

        #expect(elements.map(\.id) == [
            "clip-\(firstID.uuidString)",
            "transition-\(firstTransition.id.uuidString)",
            "clip-\(secondID.uuidString)",
            "transition-\(secondTransition.id.uuidString)",
            "clip-\(thirdID.uuidString)",
            "transition-\(finalFadeOut.id.uuidString)",
        ])
        #expect(TimelineElementSequence.contextDescription(for: firstTransition, in: project) ==
            "Interview A to Interview B")
    }

    @Test @MainActor func committedCrossDissolvePublishesAfterTimelineContainsItsElement() throws {
        let asset = fixtureAsset(name: "Interview", duration: 12)
        var project = TrimatoProject(name: "Live cross dissolve")
        project.media = [asset]
        let leadingID = try project.append(asset: asset, segments: [segment(1, 3)])
        let trailingID = try project.append(asset: asset, segments: [segment(6, 3)])
        let controller = ProjectController(document: ProjectDocument(project: project))
        let videoTrack = try #require(controller.project.tracks.first { $0.role == .primaryVideo })
        let transition = TimelineTransition(
            trackID: videoTrack.id,
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: leadingID,
            trailingClipID: trailingID
        )
        var publishedElementIDs: [[String]] = []
        let subscription = controller.objectWillChange.sink {
            guard let track = controller.project.track(id: videoTrack.id) else { return }
            publishedElementIDs.append(TimelineElementSequence.elements(
                track: track,
                transitions: TimelineElementSequence.transitions(for: track, in: controller.project)
            ).map(\.id))
        }

        try controller.addTransitions([transition], selectAddedTransition: false)

        #expect(controller.timelineContentRevision == 1)
        #expect(publishedElementIDs.last == [
            "clip-\(leadingID.uuidString)",
            "transition-\(transition.id.uuidString)",
            "clip-\(trailingID.uuidString)",
        ])
        _ = subscription
    }

    @Test func timelineElementsKeepIntroAndOutroFadesSeparateInSourceOrder() throws {
        let asset = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject(name: "Fades")
        project.media = [asset]
        let firstID = try project.append(asset: asset, segments: [segment(0, 5)])
        let secondID = try project.append(asset: asset, segments: [segment(5, 5)])
        let track = try #require(project.tracks.first { $0.role == .primaryVideo })
        let intro = TimelineTransition(
            trackID: track.id,
            edge: .intro,
            kind: .video(.fade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: nil,
            trailingClipID: firstID
        )
        let outro = TimelineTransition(
            trackID: track.id,
            edge: .outro,
            kind: .video(.fade),
            duration: ProjectTime(seconds: 1),
            leadingClipID: secondID,
            trailingClipID: nil
        )

        let elements = TimelineElementSequence.elements(track: track, transitions: [outro, intro])

        #expect(elements.map(\.id) == [
            "transition-\(intro.id.uuidString)",
            "clip-\(firstID.uuidString)",
            "clip-\(secondID.uuidString)",
            "transition-\(outro.id.uuidString)",
        ])
    }

    @Test @MainActor func reopenedProjectsSelectPrimaryVideoAndRecoverTransitionOwnership() throws {
        let asset = fixtureAsset(name: "Interview", duration: 12)
        var project = TrimatoProject(name: "Saved transitions")
        project.media = [asset]
        let leadingID = try project.append(asset: asset, segments: [segment(1, 3)])
        let trailingID = try project.append(asset: asset, segments: [segment(6, 3)])
        let videoTrack = try #require(project.tracks.first { $0.role == .primaryVideo })
        let audioTrack = try #require(project.tracks.first { $0.role == .primaryAudio })
        project.transitions = [TimelineTransition(
            trackID: UUID(),
            edge: .between,
            kind: .video(.crossDissolve),
            duration: ProjectTime(seconds: 1),
            leadingClipID: leadingID,
            trailingClipID: trailingID
        )]
        project.tracks = [audioTrack, videoTrack]

        let data = try ProjectDocument.manifestData(for: project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)
        let controller = ProjectController(document: ProjectDocument(project: decoded))
        let reopenedVideoTrack = try #require(decoded.tracks.first { $0.role == .primaryVideo })
        let transitions = TimelineElementSequence.transitions(for: reopenedVideoTrack, in: decoded)
        let restoredTransition = try #require(transitions.first)
        let elements = TimelineElementSequence.elements(track: reopenedVideoTrack, transitions: transitions)

        #expect(controller.activeTimelineTrackID == reopenedVideoTrack.id)
        #expect(transitions.count == 1)
        #expect(restoredTransition.trackID == reopenedVideoTrack.id)
        #expect(elements.map(\.id) == [
            "clip-\(leadingID.uuidString)",
            "transition-\(restoredTransition.id.uuidString)",
            "clip-\(trailingID.uuidString)",
        ])
    }

    @Test @MainActor func editorClipLookupPrefersIncomingThenContainingThenFollowing() throws {
        let asset = fixtureAsset(name: "Interview", duration: 12)
        var project = TrimatoProject(name: "Editor lookup")
        project.media = [asset]
        let trackID = project.createTrack(kind: .video, name: "Main Video")
        let firstID = try project.append(asset: asset, segments: [segment(0, 3)], toTrack: trackID)
        let secondID = try project.append(asset: asset, segments: [segment(3, 4)], toTrack: trackID)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.activeTimelineTrackID = trackID

        #expect(controller.editorClip(at: .zero)?.id == firstID)
        #expect(controller.editorClip(at: ProjectTime(seconds: 3))?.id == secondID)
        #expect(controller.editorClip(at: ProjectTime(seconds: 5))?.id == secondID)
        #expect(controller.editorClip(at: ProjectTime(seconds: 7))?.id == secondID)

        var projectWithGap = project
        let trackIndex = try #require(projectWithGap.tracks.firstIndex(where: { $0.id == trackID }))
        let secondIndex = try #require(projectWithGap.tracks[trackIndex].clips.firstIndex(where: { $0.id == secondID }))
        projectWithGap.tracks[trackIndex].clips[secondIndex].timelineStart = ProjectTime(seconds: 6)
        let gapController = ProjectController(document: ProjectDocument(project: projectWithGap))
        gapController.activeTimelineTrackID = trackID
        #expect(gapController.editorClip(at: ProjectTime(seconds: 4))?.id == secondID)
    }

    @Test func videoTransitionGraphNormalizesBothInputsForXfade() {
        let graph = FFmpegTimelineEffectRenderer.videoTransitionGraph(
            leadingStart: 2,
            trailingStart: 5,
            type: "fade",
            duration: 1.25,
            width: 1_920,
            height: 1_080,
            frameRate: 29.97
        )

        #expect(graph.components(separatedBy: "fps=30000/1001").count == 3)
        #expect(graph.components(separatedBy: "settb=AVTB").count == 3)
        #expect(graph.components(separatedBy: "setsar=1").count == 3)
        #expect(graph.components(separatedBy: "format=yuv444p").count == 3)
        #expect(graph.contains("xfade=transition=fade:duration=1.25:offset=0"))
        #expect(graph.contains("trim=duration=1.25"))
        #expect(FFmpegTimelineEffectRenderer.frameRateExpression(30.004427) == "30")
    }

    @Test func transitionRenderErrorUsesUsefulFFmpegDiagnostic() {
        let error = FFmpegCommandError(
            tool: .ffmpeg,
            status: 1,
            diagnostics: "Input streams must have the same timebase\nConversion failed!\n"
        )

        #expect(ProjectTransitionRenderError.diagnosticSummary(for: error) == "Input streams must have the same timebase")
    }

    private func segment(_ start: Double, _ duration: Double) -> SourceSegment {
        SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: start),
            duration: ProjectTime(seconds: duration)
        ))
    }
}

private func makeStereoFixture(expression: String, outputURL: URL) async throws {
    _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
        "-hide_banner", "-nostdin", "-y",
        "-f", "lavfi", "-i", "aevalsrc=\(expression):s=48000:d=6",
        "-c:a", "pcm_s16le", outputURL.path,
    ])
}

private func makeDelayedAACFixture(
    expression: String,
    delay: Double,
    outputURL: URL
) async throws {
    _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
        "-hide_banner", "-nostdin", "-y",
        "-itsoffset", String(delay),
        "-f", "lavfi", "-i", "aevalsrc=\(expression):s=48000:d=6",
        "-c:a", "aac", "-b:a", "192k", outputURL.path,
    ])
}

private func makeVideoFixture(color: String, outputURL: URL) async throws {
    _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
        "-hide_banner", "-nostdin", "-y",
        "-f", "lavfi", "-i", "color=c=\(color):s=320x240:r=30004427/1000000:d=6",
        "-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le",
        "-video_track_timescale", "60000", outputURL.path,
    ])
}

private func meanVolume(
    url: URL,
    channel: Int,
    start: Double,
    duration: Double
) async throws -> Double {
    let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
        "-hide_banner", "-nostdin",
        "-ss", String(start), "-t", String(duration),
        "-i", url.path,
        "-af", "pan=mono|c0=c\(channel),volumedetect",
        "-f", "null", "-",
    ])
    let pattern = #"mean_volume:\s*(-?(?:\d+(?:\.\d+)?|inf))\s*dB"#
    let expression = try NSRegularExpression(pattern: pattern)
    let diagnostics = result.standardError as NSString
    guard let match = expression.matches(
        in: result.standardError,
        range: NSRange(location: 0, length: diagnostics.length)
    ).last,
          let range = Range(match.range(at: 1), in: result.standardError),
          let value = Double(result.standardError[range]) else {
        throw CrossFadeFixtureError.missingMeanVolume
    }
    return value
}

private enum CrossFadeFixtureError: Error {
    case missingMeanVolume
}
