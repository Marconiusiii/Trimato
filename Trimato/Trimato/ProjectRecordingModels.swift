import Foundation
import AVFoundation

nonisolated enum RecordingPurpose: String, Codable, Sendable {
    case voiceOver, audioDescription, descriptionTranscript
    var title: String {
        switch self {
        case .voiceOver: "Voice Over"
        case .audioDescription: "Audio Description"
        case .descriptionTranscript: "Description Transcript"
        }
    }
    var toolTitle: String { self == .voiceOver ? "Voicer" : "Describer" }
}

nonisolated struct DescriptionDucking: Codable, Equatable, Sendable {
    var decibels = -5.0
    var fadeSeconds = 0.25
    var volume: Float { Float(pow(10, min(0, max(-60, decibels)) / 20)) }

    func ranges(in project: TrimatoProject) -> [ProjectTimeRange] {
        var result: [ProjectTimeRange] = project.tracks.filter { $0.kind == .audio && !$0.isMuted }.flatMap { track in
            track.clips.compactMap { clip in
                guard project.asset(id: clip.assetID)?.recordingPurpose == .audioDescription,
                      clip.visibleTimelineEnd > clip.visibleTimelineStart else { return nil }
                return ProjectTimeRange(start: clip.visibleTimelineStart, duration: clip.visibleTimelineEnd - clip.visibleTimelineStart)
            }
        }
        for transition in project.transitions {
            guard transition.edge == .between, case .audio(let kind) = transition.kind, kind != .fade,
                  let track = project.track(id: transition.trackID), !track.isMuted,
                  let trailingID = transition.trailingClipID,
                  let trailing = track.clips.first(where: { $0.id == trailingID }),
                  [transition.leadingClipID, transition.trailingClipID].compactMap({ $0 }).contains(where: {
                      project.timelineClip(id: $0).flatMap { project.asset(id: $0.assetID) }?.recordingPurpose == .audioDescription
                  }) else { continue }
            result.append(ProjectTimeRange(start: max(.zero, trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2)), duration: transition.duration))
        }
        return result
    }

    func boundaries(for ranges: [ProjectTimeRange]) -> [ProjectTime] {
        let fade = ProjectTime(seconds: max(0.01, fadeSeconds))
        return ranges.flatMap { [max(.zero, $0.start - fade), $0.start, $0.end, $0.end + fade] }
    }

    func volume(at time: ProjectTime, ranges: [ProjectTimeRange]) -> Float {
        let fade = max(0.01, fadeSeconds)
        return ranges.reduce(Float(1)) { result, range in
            let t = time.seconds
            let start = range.start.seconds
            let end = range.end.seconds
            let level: Float
            if t >= start && t <= end { level = volume }
            else if t < start && t > start - fade {
                let fadeStart = max(0, start - fade)
                level = 1 + (volume - 1) * Float((t - fadeStart) / max(0.001, start - fadeStart))
            } else if t > end && t < end + fade {
                level = volume + (1 - volume) * Float((t - end) / fade)
            } else { level = 1 }
            return min(result, level)
        }
    }
}

extension TrimatoProject {
    var descriptionTranscriptTrack: TimelineTrack? {
        tracks.first { $0.recordingPurpose == .descriptionTranscript }
    }

    mutating func putDescription(_ cue: CaptionCue) throws {
        var cue = try cue.validated()
        cue.isDraft = false
        cue.isDescription = true
        if let index = tracks.firstIndex(where: { $0.recordingPurpose == .descriptionTranscript }) {
            if let cueIndex = tracks[index].captionCues.firstIndex(where: { $0.id == cue.id }) {
                tracks[index].captionCues[cueIndex] = cue
            } else { tracks[index].captionCues.append(cue) }
        } else {
            var track = TimelineTrack(name: "Description Transcript", kind: .captions)
            track.recordingPurpose = .descriptionTranscript
            track.captionCues = [cue]
            tracks.append(track)
        }
    }

    @discardableResult
    mutating func putRecording(_ asset: MediaAssetRecord, at start: ProjectTime) -> UUID {
        media.append(asset)
        let purpose = asset.recordingPurpose ?? .voiceOver
        let index: Int
        if let existing = tracks.firstIndex(where: { track in
            track.kind == .audio && track.recordingPurpose == purpose && !track.clips.contains {
                max($0.timelineStart, start) < min($0.timelineEnd, start + asset.editedDuration)
            }
        }) {
            index = existing
        } else {
            let count = tracks.filter { $0.recordingPurpose == purpose }.count
            var track = TimelineTrack(name: count == 0 ? purpose.title : "\(purpose.title) \(count + 1)", kind: .audio)
            track.recordingPurpose = purpose
            tracks.append(track)
            index = tracks.count - 1
        }
        var clip = TimelineClip(assetID: asset.id, name: asset.name, segments: asset.sourceEdit)
        clip.timelineStart = start
        clip.isIndependentAudio = true
        tracks[index].clips.append(clip)
        return clip.id
    }
}

@MainActor
enum RecordingTakeProcessor {
    static func prepare(url: URL, duration: Double, available: Double?, speedUp: Bool, trim: Bool) async throws -> (url: URL, duration: Double) {
        guard duration.isFinite, duration > 0 else { throw AudioCaptureError.message("The recording is empty.") }
        guard let available else { return (url, duration) }
        guard available.isFinite, available > 0 else { throw AudioCaptureError.message("Set the Out point after the In point.") }
        guard duration > available else { return (url, duration) }
        guard speedUp || trim else { return (url, duration) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-take-\(UUID()).wav")
        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", url.path]
        if speedUp {
            var ratio = duration / available
            var filters: [String] = []
            while ratio > 2 { filters.append("atempo=2"); ratio /= 2 }
            filters.append("atempo=\(ratio)")
            arguments += ["-af", filters.joined(separator: ",")]
        }
        arguments += ["-t", "\(available)", "-c:a", "pcm_s24le", output.path]
        do {
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, expectedDuration: available)
            try Task.checkCancellation()
            let length = try await AVURLAsset(url: output).load(.duration).seconds
            guard length.isFinite, length > 0 else { throw AudioCaptureError.message("The adjusted recording is empty.") }
            return (output, min(available, length))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
