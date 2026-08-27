import Foundation
import Testing
@testable import Trimato

struct MultiTrackTimelineTests {
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
        #expect(TransitionDurationInput.parse("1.25") == ProjectTime(seconds: 1.25))
        #expect(TransitionDurationInput.parse("0") == nil)
        #expect(TransitionDurationInput.parse("seconds") == nil)
        #expect(TransitionDurationInput.string(for: ProjectTime(seconds: 1)) == "1.0")
        #expect(TransitionDurationInput.string(for: ProjectTime(seconds: 1.25)) == "1.25")
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

        #expect(graph.components(separatedBy: "fps=29.97").count == 3)
        #expect(graph.components(separatedBy: "settb=AVTB").count == 3)
        #expect(graph.components(separatedBy: "setsar=1").count == 3)
        #expect(graph.components(separatedBy: "format=yuv444p").count == 3)
        #expect(graph.contains("xfade=transition=fade:duration=1.25:offset=0"))
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
