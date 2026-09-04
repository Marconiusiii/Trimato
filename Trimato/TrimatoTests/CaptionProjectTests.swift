import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Trimato

@Suite struct CaptionProjectTests {
    @Test func captionsUseOneTrackAndAbsoluteTimes() throws {
        var project = TrimatoProject()
        try project.addCaptionCues([
            CaptionCue(start: ProjectTime(seconds: 5), end: ProjectTime(seconds: 7), text: "Welcome\nto Trimato"),
            CaptionCue(start: ProjectTime(seconds: 1), end: ProjectTime(seconds: 2), text: "Earlier")
        ])
        try project.addCaptionCues([
            CaptionCue(start: ProjectTime(seconds: 9), end: ProjectTime(seconds: 10), text: "Last")
        ])
        #expect(project.tracks.filter { $0.kind == .captions }.count == 1)
        #expect(project.captionTrack?.sortedCaptionCues.map(\.start) == [
            ProjectTime(seconds: 1), ProjectTime(seconds: 5), ProjectTime(seconds: 9)
        ])
        #expect(project.captionTrack?.captionCues.first?.displayName == "Caption: Welcome")
    }

    @Test func captionTrackAndCuesPersistInTheProjectManifest() throws {
        var project = TrimatoProject(name: "Captioned")
        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "Hello")
        try project.addCaptionCues([cue])
        let data = try ProjectDocument.manifestData(for: project)
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: data)
        #expect(reopened.captionTrack?.name == "Captions")
        #expect(reopened.captionCue(id: cue.id) == cue)
        #expect(reopened.schemaVersion == 4)
    }

    @Test func olderSavedCaptionsDecodeAsFinalized() throws {
        let cue = CaptionCue(
            start: ProjectTime(seconds: 1),
            end: ProjectTime(seconds: 3),
            text: "Existing caption",
            isDraft: true
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cue)) as? [String: Any])
        object.removeValue(forKey: "isDraft")
        let olderData = try JSONSerialization.data(withJSONObject: object)

        let reopened = try JSONDecoder().decode(CaptionCue.self, from: olderData)

        #expect(!reopened.isDraft)
    }

    @Test func olderTracksDecodeWithoutCaptionCues() throws {
        let track = TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        object.removeValue(forKey: "captionCues")
        let decoded = try JSONDecoder().decode(
            TimelineTrack.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.captionCues.isEmpty)
    }

    @Test func captionTrackAppearsBeforePictureAndSoundTracks() throws {
        var project = TrimatoProject()
        project.tracks = [
            TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo),
            TimelineTrack(name: "Primary Audio", kind: .audio, role: .primaryAudio)
        ]
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Hello")])
        #expect(project.orderedTimelineTracks.map(\.name) == ["Captions", "Primary Video", "Primary Audio"])
    }

    @Test func captionCuesAttachARealVideoOverlay() throws {
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 640, height: 360)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        try CaptionOverlayRenderer.apply(
            cues: [CaptionCue(start: ProjectTime(seconds: 1), end: ProjectTime(seconds: 2), text: "Hello")],
            to: composition,
            renderSize: composition.renderSize,
            duration: ProjectTime(seconds: 3)
        )
        #expect(composition.animationTool != nil)
    }

    @MainActor
    @Test func captionedPreviewUsesLiveSynchronizedLayersAndKeepsOfflineRenderingForExport() async throws {
        var definition = GeneratorDefinition()
        definition.kind = .black
        definition.width = 640
        definition.height = 360
        definition.duration = ProjectTime(seconds: 3)
        definition.frameRate = 30
        let asset = definition.assetRecord()
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 640, height: 360, frameRate: 30)
        project.media = [asset]
        _ = try project.append(asset: asset)
        try project.addCaptionCues([
            CaptionCue(start: ProjectTime(seconds: 1), end: ProjectTime(seconds: 2), text: "Hello")
        ])

        let preview = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [:],
            purpose: .preview
        )
        defer { for url in preview.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        #expect(preview.videoComposition?.animationTool == nil)
        let item = AVPlayerItem(asset: preview.composition)
        item.videoComposition = preview.videoComposition

        let export = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: [:],
            purpose: .finalExport
        )
        defer { for url in export.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        #expect(export.videoComposition?.animationTool != nil)

        let view = PlayerNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        view.playerLayer.player = AVPlayer(playerItem: item)
        view.configureCaptionPreview(
            cues: project.captionTrack?.captionCues ?? [],
            duration: project.duration,
            renderSize: CGSize(width: 640, height: 360)
        )
        let synchronizedLayer = try #require(
            view.layer?.sublayers?.first(where: { $0 is AVSynchronizedLayer }) as? AVSynchronizedLayer
        )
        let captionRoot = try #require(synchronizedLayer.sublayers?.first)
        let captionLayer = try #require(captionRoot.sublayers?.first)
        let animation = try #require(captionLayer.animation(forKey: "captionVisibility") as? CAKeyframeAnimation)
        #expect(animation.values?.allSatisfy { $0 is NSNumber } == true)
        #expect(animation.keyTimes?.allSatisfy { $0 is NSNumber } == true)

        // The original failure occurred only when Core Animation committed the live layer tree.
        CATransaction.begin()
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
    }
}
