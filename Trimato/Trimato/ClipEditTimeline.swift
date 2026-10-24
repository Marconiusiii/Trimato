import CoreMedia
import Foundation

nonisolated enum ClipEditError: LocalizedError, Equatable, Sendable {
    case invalidSelection
    case entireClip
    case nothingToTrim

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Set an In marker earlier than the Out marker."
        case .entireClip:
            return "The entire clip cannot be deleted."
        case .nothingToTrim:
            return "There is nothing to trim at the current playhead position."
        }
    }
}

nonisolated struct ClipEditTimeline: Equatable, Sendable {
    struct EditPoint: Equatable, Sendable, Identifiable {
        let index: Int
        let time: CMTime
        let inTime: CMTime
        let outTime: CMTime
        let precedingStart: CMTime
        let followingEnd: CMTime
        var id: Int { index }
        var name: String { "Edit Point \(index + 1)" }
    }

    private(set) var sourceRanges: [CMTimeRange]

    init(sourceDuration: CMTime) {
        sourceRanges = sourceDuration.isValid && CMTimeCompare(sourceDuration, .zero) > 0
            ? [CMTimeRange(start: .zero, duration: sourceDuration)]
            : []
    }

    init(sourceRanges: [CMTimeRange]) {
        self.sourceRanges = sourceRanges.filter {
            $0.isValid && CMTimeCompare($0.duration, .zero) > 0
        }
    }

    var duration: CMTime {
        sourceRanges.reduce(.zero) { CMTimeAdd($0, $1.duration) }
    }

    var editPoints: [EditPoint] {
        var position = CMTime.zero
        return sourceRanges.indices.dropLast().map { index in
            let preceding = sourceRanges[index]
            let following = sourceRanges[index + 1]
            position = CMTimeAdd(position, preceding.duration)
            return EditPoint(index: index, time: position, inTime: preceding.end,
                outTime: following.start, precedingStart: preceding.start, followingEnd: following.end)
        }
    }

    func adjustingEditPoint(_ index: Int, inTime: CMTime, outTime: CMTime) throws -> ClipEditTimeline {
        guard let point = editPoints.first(where: { $0.index == index }),
              inTime.isNumeric, outTime.isNumeric,
              CMTimeCompare(inTime, point.precedingStart) > 0,
              CMTimeCompare(inTime, outTime) < 0,
              CMTimeCompare(outTime, point.followingEnd) < 0 else {
            throw ClipEditError.invalidSelection
        }
        var ranges = sourceRanges
        ranges[index] = CMTimeRange(start: point.precedingStart, end: inTime)
        ranges[index + 1] = CMTimeRange(start: outTime, end: point.followingEnd)
        return ClipEditTimeline(sourceRanges: ranges)
    }

    mutating func delete(editedRange: CMTimeRange) throws {
        guard editedRange.isValid,
              CMTimeCompare(editedRange.duration, .zero) > 0,
              CMTimeCompare(editedRange.start, .zero) >= 0,
              CMTimeCompare(editedRange.end, duration) <= 0 else {
            throw ClipEditError.invalidSelection
        }
        guard CMTimeCompare(editedRange.start, .zero) > 0 ||
                CMTimeCompare(editedRange.end, duration) < 0 else {
            throw ClipEditError.entireClip
        }

        let retainedBefore = sourceRanges(in: CMTimeRange(start: .zero, end: editedRange.start))
        let retainedAfter = sourceRanges(in: CMTimeRange(start: editedRange.end, end: duration))
        sourceRanges = retainedBefore + retainedAfter
    }

    func sourceRanges(in editedRange: CMTimeRange? = nil) -> [CMTimeRange] {
        let requested = editedRange ?? CMTimeRange(start: .zero, duration: duration)
        guard requested.isValid, CMTimeCompare(requested.duration, .zero) > 0 else { return [] }

        var result: [CMTimeRange] = []
        var editedCursor = CMTime.zero

        for sourceRange in sourceRanges {
            let editedSegment = CMTimeRange(start: editedCursor, duration: sourceRange.duration)
            let overlap = CMTimeRangeGetIntersection(editedSegment, otherRange: requested)
            if overlap.isValid, !overlap.isEmpty, CMTimeCompare(overlap.duration, .zero) > 0 {
                let sourceOffset = CMTimeSubtract(overlap.start, editedSegment.start)
                result.append(CMTimeRange(
                    start: CMTimeAdd(sourceRange.start, sourceOffset),
                    duration: overlap.duration
                ))
            }
            editedCursor = editedSegment.end
        }
        return result
    }
}
