import AppKit
import Foundation
@testable import Trimato

/// Pure project edits, serialization and Undo only. No application, media or playback.
@main struct TrackTimingCheck {
    static func segments(_ seconds: Double) -> [SourceSegment] {
        [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: seconds)))]
    }
    static func starts(_ project: TrimatoProject, _ ids: [UUID]) -> [ProjectTime] {
        ids.map { project.timelineClip(id: $0)!.timelineStart }
    }
    @MainActor static func main() throws {
        precondition(NSApp == nil)
        for purpose: RecordingPurpose? in [nil, .audioDescription, .voiceOver] {
            for kind: TimelineTrackKind in [.audio, .video] {
                var asset = MediaAssetRecord(name: "Fixture", originalPath: "/unused.mov",
                    duration: ProjectTime(seconds: 10), naturalWidth: kind == .video ? 320 : nil,
                    naturalHeight: kind == .video ? 180 : nil, frameRate: 30, hasAudio: true,
                    sourceEdit: segments(2))
                asset.recordingPurpose = purpose
                let clips = [10.0, 30, 60].map { start in
                    TimelineClip(assetID: asset.id, name: "At \(start)", segments: segments(2), timelineStart: ProjectTime(seconds: start))
                }
                let ids = clips.map(\.id)
                var baseline = TrimatoProject(name: "Absolute timing")
                let track = TimelineTrack(name: "Independent", kind: kind, clips: clips, recordingPurpose: purpose)
                baseline.media = [asset]; baseline.tracks = [track]
                let original = starts(baseline, ids)
                var value = baseline
                try value.updateTrackClip(id: ids[0], segments: segments(1))
                precondition(starts(value, ids) == original, "Shortening moved another clip")
                try value.updateTrackClip(id: ids[0], segments: segments(4))
                precondition(starts(value, ids) == original, "Lengthening moved another clip")
                let beforeOverlap = value
                do { try value.updateTrackClip(id: ids[0], segments: segments(25)); preconditionFailure("Overlap accepted") }
                catch { precondition(value == beforeOverlap, "Rejected edit changed the project") }
                try value.trimTrackClipEnd(id: ids[0], at: ProjectTime(seconds: 11))
                precondition(starts(value, ids) == original, "Trim shifted another clip")
                try value.removeTrackClip(id: ids[0])
                precondition(starts(value, Array(ids.dropFirst())) == Array(original.dropFirst()), "Delete rippled")
                value = baseline
                _ = try value.replaceRemainder(with: asset, segments: segments(1), at: ProjectTime(seconds: 10), onTrack: track.id)
                precondition(starts(value, Array(ids.dropFirst())) == Array(original.dropFirst()), "Replacement rippled")
                value = baseline
                _ = try value.insert(asset: asset, at: ProjectTime(seconds: 20), onTrack: track.id)
                precondition(starts(value, ids) == original, "Insertion rippled")
                let appended = try value.append(asset: asset, toTrack: track.id)
                precondition(value.timelineClip(id: appended)?.timelineStart == ProjectTime(seconds: 62))
                precondition(starts(value, ids) == original)
                value = baseline
                _ = try value.duplicateTrackClip(id: ids[0], after: ids[0])
                precondition(starts(value, ids) == original, "Paste rippled")
                value = baseline
                try value.moveTrackClip(id: ids[1], to: .playhead, targetID: ids[1], playhead: ProjectTime(seconds: 40))
                precondition(starts(value, ids) == [original[0], ProjectTime(seconds: 40), original[2]])
                try value.moveTrackClip(id: ids[1], to: .before, targetID: ids[2])
                precondition(value.timelineClip(id: ids[1])?.timelineStart == ProjectTime(seconds: 58))
                precondition(starts(value, [ids[0], ids[2]]) == [original[0], original[2]])
                value = baseline
                let other = value.createTrack(kind: kind)
                try value.moveTrackClip(id: ids[0], to: .playhead, targetID: ids[0], destinationTrackID: other, playhead: ProjectTime(seconds: 5))
                precondition(starts(value, Array(ids.dropFirst())) == Array(original.dropFirst()), "Cross-track move rippled source")
                // The real controller registers the toggle and packing as one Undo action.
                let controller = ProjectController(document: ProjectDocument(project: baseline))
                let undo = UndoManager(); undo.groupsByEvent = false
                controller.installUndoManager(undo)
                undo.beginUndoGrouping()
                try controller.setTrackMagnetic(id: track.id, enabled: true)
                undo.endUndoGrouping()
                let packed = controller.project
                precondition(starts(packed, ids) == [0, 2, 4].map { ProjectTime(seconds: Double($0)) })
                precondition(packed.track(id: track.id)!.isMagnetic)
                undo.undo(); precondition(controller.project == baseline, "Undo failed to restore exact original positions")
                undo.redo(); precondition(controller.project == packed)
                undo.beginUndoGrouping()
                try controller.updateClipDraft(.timelineClip(ids[0]), segments: segments(1), audio: nil, filters: [])
                undo.endUndoGrouping()
                let edited = controller.project
                precondition(starts(edited, ids) == [0, 1, 3].map { ProjectTime(seconds: Double($0)) })
                undo.undo(); precondition(controller.project == packed)
                undo.undo(); precondition(controller.project == baseline)
                undo.redo(); precondition(controller.project == packed)
                undo.redo(); precondition(controller.project == edited)
                let movement = ProjectController(document: ProjectDocument(project: packed))
                movement.activeTimelineTrackID = track.id
                movement.beginClipMovement(id: ids[0])
                movement.focusTimelineElement(.clip(ids[2]))
                movement.moveFocusedTimelineClip(id: ids[2], by: 1)
                movement.finishClipMovement()
                precondition(movement.project.track(id: track.id)!.sortedClips.map(\.id) == [ids[1], ids[0], ids[2]], "Magnetic arrow movement lost the lifted clip")
                precondition(!movement.canMoveClip(to: .playhead, targetID: ids[0]))
                let placement = ProjectController(document: ProjectDocument(project: baseline))
                placement.activeTimelineTrackID = track.id
                placement.timelinePlayhead = ProjectTime(seconds: 40)
                placement.focusTimelineElement(.clip(ids[1]))
                precondition(placement.canMoveClip(to: .playhead, targetID: ids[1]))
                placement.moveClip(to: .playhead, targetID: ids[1])
                precondition(starts(placement.project, ids) == [original[0], ProjectTime(seconds: 40), original[2]])
                var replacement = packed
                let replacementID = try replacement.replaceRemainder(with: asset, segments: segments(4), at: .zero, onTrack: track.id)
                precondition(replacement.timelineClip(id: replacementID)?.timelineStart == .zero)
                precondition(starts(replacement, Array(ids.dropFirst())) == [4, 6].map { ProjectTime(seconds: Double($0)) })
                var splitInsertion = packed
                _ = try splitInsertion.insert(asset: asset, segments: segments(1), at: ProjectTime(seconds: 1), onTrack: track.id)
                let ordered = splitInsertion.track(id: track.id)!.sortedClips
                precondition(zip(ordered, ordered.dropFirst()).allSatisfy { $0.timelineEnd == $1.timelineStart })
                var magnetic = packed
                try magnetic.updateTrackClip(id: ids[0], segments: segments(1))
                precondition(starts(magnetic, ids) == [0, 1, 3].map { ProjectTime(seconds: Double($0)) })
                try magnetic.setTrackMagnetic(id: track.id, enabled: false)
                let frozen = starts(magnetic, ids)
                try magnetic.removeTrackClip(id: ids[0])
                precondition(starts(magnetic, Array(ids.dropFirst())) == Array(frozen.dropFirst()))
                let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(packed))
                precondition(decoded.track(id: track.id)!.isMagnetic && starts(decoded, ids) == starts(packed, ids))
                // A pre-setting project retains every stored start and opens nonmagnetic.
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as! [String: Any]
                json.removeValue(forKey: "magnetic")
                let oldTrack = try JSONDecoder().decode(TimelineTrack.self, from: JSONSerialization.data(withJSONObject: json))
                precondition(!oldTrack.isMagnetic && oldTrack.clips == clips)
                print("PASS: \(kind.rawValue), \(purpose?.rawValue ?? "ordinary"): absolute edits, Playhead, magnetic packing, Undo/Redo and persistence")
            }
        }
        var show = TrimatoProject(name: "Whole project timing")
        let picture = MediaAssetRecord(name: "Picture", originalPath: "/unused.mov", duration: ProjectTime(seconds: 120),
            naturalWidth: 320, naturalHeight: 180, frameRate: 30, hasAudio: true, sourceEdit: segments(120))
        show.media = [picture]
        let primary = try show.append(asset: picture)
        var recordings: [UUID] = []
        for purpose: RecordingPurpose in [.audioDescription, .voiceOver] {
            for start in [10.0, 30, 60] {
                var source = MediaAssetRecord(name: purpose.title, originalPath: "/unused.wav", duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: segments(2))
                source.recordingPurpose = purpose
                recordings.append(show.putRecording(source, at: ProjectTime(seconds: start)))
            }
        }
        let cues = [10.0, 30, 60].map { CaptionCue(start: ProjectTime(seconds: $0), end: ProjectTime(seconds: $0 + 2), text: "Caption") }
        try show.addCaptionCues(cues)
        for var cue in cues { cue.id = UUID(); cue.isDescription = true; try show.putDescription(cue) }
        let recordingStarts = starts(show, recordings)
        let captions = show.tracks.filter { $0.kind == .captions }
        try show.updateTimelineClip(id: primary, segments: segments(90))
        precondition(starts(show, recordings) == recordingStarts && show.tracks.filter { $0.kind == .captions } == captions)
        try show.removeClip(id: primary)
        precondition(starts(show, recordings) == recordingStarts && show.tracks.filter { $0.kind == .captions } == captions)
        var changedCue = cues[0]; changedCue.end = ProjectTime(seconds: 13)
        try show.updateCaptionCue(changedCue)
        precondition(Array(show.captionTrack!.sortedCaptionCues.dropFirst()) == Array(cues.dropFirst()))
        try show.removeCaptionCue(id: changedCue.id)
        precondition(show.captionTrack!.sortedCaptionCues == Array(cues.dropFirst()))
        let descriptions = show.descriptionTranscriptTrack!.sortedCaptionCues
        var description = descriptions[0]; description.text = "Revised description"; description.end = ProjectTime(seconds: 14)
        try show.putDescription(description)
        precondition(Array(show.descriptionTranscriptTrack!.sortedCaptionCues.dropFirst()) == Array(descriptions.dropFirst()))
        try show.removeCaptionCue(id: description.id)
        precondition(show.descriptionTranscriptTrack!.sortedCaptionCues == Array(descriptions.dropFirst()))
        let oldDescriptionTrack = show.tracks.first { $0.recordingPurpose == .audioDescription }!
        try show.setTrackMagnetic(id: oldDescriptionTrack.id, enabled: true)
        var take = MediaAssetRecord(name: "New description", originalPath: "/unused.wav", duration: ProjectTime(seconds: 2), hasAudio: true, sourceEdit: segments(2))
        take.recordingPurpose = .audioDescription
        let takeID = show.putRecording(take, at: ProjectTime(seconds: 45))
        precondition(show.timelineClip(id: takeID)?.timelineStart == ProjectTime(seconds: 45))
        precondition(show.tracks.first { $0.clips.contains { $0.id == takeID } }?.isMagnetic == false)
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(show))
        precondition(reopened.tracks == show.tracks, "Save/reopen changed timed content")
        print("PASS: primary edits preserve recordings, captions and transcripts; cue edits stay independent; new recordings remain absolute")
        var overlays = TrimatoProject(name: "Overlay compatibility")
        overlays.media = [picture]
        _ = try overlays.append(asset: picture)
        let overlay1 = try overlays.addCutaway(asset: picture, segments: segments(2), at: ProjectTime(seconds: 10), audioMode: .sourceAudio)
        let overlay2 = try overlays.addCutaway(asset: picture, segments: segments(2), at: ProjectTime(seconds: 30), audioMode: .sourceAudio)
        let overlayTrack = overlays.tracks.first { $0.clips.contains { $0.id == overlay1 } }!.id
        try overlays.setTrackMagnetic(id: overlayTrack, enabled: true)
        precondition(overlays.cutaways.first { $0.id == overlay2 }!.start == ProjectTime(seconds: 2))
        try overlays.updateTrackClip(id: overlay1, segments: segments(1))
        precondition(overlays.cutaways.first { $0.id == overlay2 }!.start == ProjectTime(seconds: 1))
        try overlays.removeTrackClip(id: overlay1)
        precondition(overlays.timelineClip(id: overlay2)?.timelineStart == .zero)
        let reopenedOverlays = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(overlays))
        precondition(reopenedOverlays.timelineClip(id: overlay1) == nil)
        precondition(reopenedOverlays.timelineClip(id: overlay2)?.timelineStart == .zero)
        print("PASS: legacy overlays and linked audio keep magnetic timing through edits, removal and reopening")
        precondition(TimelineTrack(name: "Primary", kind: .video, role: .primaryVideo).isMagnetic)
        precondition(TimelineTrack(name: "Primary", kind: .audio, role: .primaryAudio).isMagnetic)
        precondition(!TimelineTrack(name: "Captions", kind: .captions, magnetic: true).isMagnetic)
        precondition(NSApp == nil)
    }
}
