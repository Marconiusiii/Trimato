import AVFoundation
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
}
