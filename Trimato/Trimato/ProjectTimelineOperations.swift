import Foundation

enum ProjectTimelineError: LocalizedError, Equatable {
    case emptyIncomingClip
    case invalidPlayhead
    case clipNotFound
    case cannotSplitAtBoundary
    case cutawayDoesNotFit
    case cutawayOverlap

    var errorDescription: String? {
        switch self {
        case .emptyIncomingClip: "The edited clip does not contain any media."
        case .invalidPlayhead: "The timeline playhead is outside the project."
        case .clipNotFound: "The selected timeline clip is no longer available."
        case .cannotSplitAtBoundary: "Move the playhead inside a clip before splitting it."
        case .cutawayDoesNotFit: "The cutaway extends beyond the end of the project."
        case .cutawayOverlap: "Another cutaway already occupies that position."
        }
    }
}

extension TrimatoProject {
    mutating func append(asset: MediaAssetRecord, segments: [SourceSegment]? = nil) throws -> UUID {
        let clip = try makeTimelineClip(asset: asset, segments: segments)
        primaryTimeline.append(clip)
        resolveAutomaticFormat(from: asset)
        return clip.id
    }

    mutating func insert(asset: MediaAssetRecord, segments: [SourceSegment]? = nil, at playhead: ProjectTime) throws -> UUID {
        let incoming = try makeTimelineClip(asset: asset, segments: segments)
        let destination = try timelineDestination(at: playhead, allowsEnd: true)
        if let destination, destination.offset > .zero, destination.offset < destination.clip.duration {
            let halves = try split(destination.clip, at: destination.offset)
            primaryTimeline.replaceSubrange(destination.index...destination.index, with: [halves.0, incoming, halves.1])
        } else if let destination {
            let insertionIndex = destination.offset == destination.clip.duration
                ? destination.index + 1
                : destination.index
            primaryTimeline.insert(incoming, at: insertionIndex)
        } else {
            primaryTimeline.append(incoming)
        }
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    mutating func replaceClipRemainder(
        with asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime
    ) throws -> UUID {
        let incoming = try makeTimelineClip(asset: asset, segments: segments)
        guard let destination = try timelineDestination(at: playhead, allowsEnd: true) else {
            primaryTimeline.append(incoming)
            resolveAutomaticFormat(from: asset)
            return incoming.id
        }

        if destination.offset <= .zero {
            primaryTimeline[destination.index] = incoming
        } else if destination.offset >= destination.clip.duration {
            primaryTimeline.insert(incoming, at: destination.index + 1)
        } else {
            let left = try split(destination.clip, at: destination.offset).0
            primaryTimeline.replaceSubrange(destination.index...destination.index, with: [left, incoming])
        }
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    mutating func addCutaway(
        asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime,
        audioMode: CutawayAudioMode
    ) throws -> UUID {
        let selectedSegments = (segments ?? asset.sourceEdit).filter { $0.duration.isPositive }
        guard !selectedSegments.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        let cutaway = TimelineCutaway(
            assetID: asset.id,
            name: asset.name,
            start: playhead,
            segments: selectedSegments,
            audioMode: audioMode
        )
        guard playhead >= .zero, cutaway.end <= duration else {
            throw ProjectTimelineError.cutawayDoesNotFit
        }
        guard !cutaways.contains(where: { existing in
            cutaway.start < existing.end && existing.start < cutaway.end
        }) else {
            throw ProjectTimelineError.cutawayOverlap
        }
        cutaways.append(cutaway)
        cutaways.sort { $0.start < $1.start }
        return cutaway.id
    }

    mutating func splitClip(id: UUID, atTimelineTime playhead: ProjectTime) throws -> UUID {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }),
              let start = startTime(of: id) else {
            throw ProjectTimelineError.clipNotFound
        }
        let offset = playhead - start
        let halves = try split(primaryTimeline[index], at: offset)
        primaryTimeline.replaceSubrange(index...index, with: [halves.0, halves.1])
        return halves.1.id
    }

    mutating func updateTimelineClip(id: UUID, segments: [SourceSegment]) throws {
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline[index].segments = selected
        guard cutaways.allSatisfy({ $0.end <= duration }) else {
            throw ProjectTimelineError.cutawayDoesNotFit
        }
    }

    mutating func updateCutaway(id: UUID, segments: [SourceSegment]) throws {
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let index = cutaways.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let updatedEnd = cutaways[index].start + selected.reduce(.zero) { $0 + $1.duration }
        guard updatedEnd <= duration else { throw ProjectTimelineError.cutawayDoesNotFit }
        guard !cutaways.contains(where: { other in
            other.id != id && cutaways[index].start < other.end && other.start < updatedEnd
        }) else { throw ProjectTimelineError.cutawayOverlap }
        cutaways[index].segments = selected
    }

    mutating func removeClip(id: UUID) throws {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline.remove(at: index)
    }

    mutating func moveClip(id: UUID, to destination: Int) throws {
        guard let source = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let clip = primaryTimeline.remove(at: source)
        let bounded = min(max(destination, 0), primaryTimeline.count)
        primaryTimeline.insert(clip, at: bounded)
    }

    private mutating func resolveAutomaticFormat(from asset: MediaAssetRecord) {
        guard format.mode == .automatic, !format.isResolved,
              let width = asset.naturalWidth, let height = asset.naturalHeight else { return }
        format.width = width
        format.height = height
        format.frameRate = asset.frameRate ?? 30
    }

    private func makeTimelineClip(asset: MediaAssetRecord, segments: [SourceSegment]?) throws -> TimelineClip {
        let selected = (segments ?? asset.sourceEdit).filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        return TimelineClip(assetID: asset.id, name: asset.name, segments: selected)
    }

    private func timelineDestination(
        at playhead: ProjectTime,
        allowsEnd: Bool
    ) throws -> (index: Int, clip: TimelineClip, offset: ProjectTime)? {
        guard playhead >= .zero, playhead < duration || (allowsEnd && playhead == duration) else {
            throw ProjectTimelineError.invalidPlayhead
        }
        var cursor = ProjectTime.zero
        for (index, clip) in primaryTimeline.enumerated() {
            let end = cursor + clip.duration
            if playhead < end || (playhead == end && index == primaryTimeline.count - 1) {
                return (index, clip, playhead - cursor)
            }
            cursor = end
        }
        return nil
    }

    private func split(_ clip: TimelineClip, at offset: ProjectTime) throws -> (TimelineClip, TimelineClip) {
        guard offset > .zero, offset < clip.duration else {
            throw ProjectTimelineError.cannotSplitAtBoundary
        }
        var leftSegments: [SourceSegment] = []
        var rightSegments: [SourceSegment] = []
        var remaining = offset

        for segment in clip.segments {
            if remaining <= .zero {
                rightSegments.append(segment)
            } else if remaining >= segment.duration {
                leftSegments.append(segment)
                remaining = remaining - segment.duration
            } else {
                leftSegments.append(SourceSegment(sourceRange: ProjectTimeRange(
                    start: segment.sourceRange.start,
                    duration: remaining
                )))
                rightSegments.append(SourceSegment(sourceRange: ProjectTimeRange(
                    start: segment.sourceRange.start + remaining,
                    duration: segment.duration - remaining
                )))
                remaining = .zero
            }
        }
        guard !leftSegments.isEmpty, !rightSegments.isEmpty else {
            throw ProjectTimelineError.cannotSplitAtBoundary
        }
        return (
            TimelineClip(assetID: clip.assetID, name: clip.name, segments: leftSegments),
            TimelineClip(assetID: clip.assetID, name: clip.name, segments: rightSegments)
        )
    }
}
