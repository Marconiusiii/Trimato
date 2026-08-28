import AVFoundation
import Combine
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
