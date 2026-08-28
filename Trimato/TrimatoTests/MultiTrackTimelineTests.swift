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
            trailingSettings: AudioClipSettings()
        )
        let fadeOutIn = FFmpegTimelineEffectRenderer.audioFadeOutInGraph(
            leadingStart: 1,
            trailingStart: 2,
            duration: 1,
            leadingSettings: AudioClipSettings(),
            trailingSettings: AudioClipSettings()
        )

        #expect(crossFade.contains("[a0][a1]acrossfade=d=1:o=1:c1=qsin:c2=qsin[outa]"))
        #expect(!crossFade.contains("concat="))
        #expect(fadeOutIn.contains("afade=t=out"))
        #expect(fadeOutIn.contains("afade=t=in"))
        #expect(fadeOutIn.contains("concat=n=2:v=0:a=1[outa]"))
        #expect(!fadeOutIn.contains("acrossfade="))
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
        let renderedURL = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
            leadingURL: leadingURL,
            trailingURL: trailingURL,
            leadingClip: leadingClip,
            trailingClip: trailingClip,
            type: .crossFade,
            duration: ProjectTime(seconds: 3)
        )
        defer { try? FileManager.default.removeItem(at: renderedURL) }

        let report = try await FFmpegMediaProbe.inspect(url: renderedURL)
        #expect(abs(report.duration - 3) < 0.02)

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

        let elements = TimelineElementSequence.elements(
            track: track,
            transitions: [secondTransition, firstTransition]
        )

        #expect(elements.map(\.id) == [
            "clip-\(firstID.uuidString)",
            "transition-\(firstTransition.id.uuidString)",
            "clip-\(secondID.uuidString)",
            "transition-\(secondTransition.id.uuidString)",
            "clip-\(thirdID.uuidString)",
        ])
        #expect(TimelineElementSequence.contextDescription(for: firstTransition, in: project) ==
            "Interview A to Interview B")
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

private func makeStereoFixture(expression: String, outputURL: URL) async throws {
    _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
        "-hide_banner", "-nostdin", "-y",
        "-f", "lavfi", "-i", "aevalsrc=\(expression):s=48000:d=6",
        "-c:a", "pcm_s16le", outputURL.path,
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
