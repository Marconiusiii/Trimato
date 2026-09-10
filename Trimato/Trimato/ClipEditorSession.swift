import Foundation

nonisolated struct ClipEditorOpeningConfiguration: Equatable, Sendable {
    var playbackSegments: [SourceSegment]?
    var inMarker: ProjectTime?
    var outMarker: ProjectTime?

    static func make(
        segments: [SourceSegment],
        sourceDuration: ProjectTime
    ) throws -> ClipEditorOpeningConfiguration {
        guard sourceDuration.isPositive,
              segments.allSatisfy({ $0.sourceRange.isValid && $0.sourceRange.end <= sourceDuration }) else {
            throw MediaSourceError.unreadable("The saved clip edit contains a range outside the source media. Reopen the original file to recover the full clip.")
        }
        let usable = segments
        guard usable.count == 1, let segment = usable.first,
              segment.sourceRange.start >= .zero,
              segment.sourceRange.end <= sourceDuration else {
            let editedDuration = usable.reduce(.zero) { $0 + $1.duration }
            return ClipEditorOpeningConfiguration(
                playbackSegments: usable,
                inMarker: editedDuration.isPositive ? .zero : nil,
                outMarker: editedDuration.isPositive ? editedDuration : nil
            )
        }
        return ClipEditorOpeningConfiguration(
            playbackSegments: nil,
            inMarker: segment.sourceRange.start,
            outMarker: segment.sourceRange.end
        )
    }
}

nonisolated struct ClipEditorDraft: Equatable, Sendable {
    private(set) var baselineSegments: [SourceSegment]
    private(set) var segments: [SourceSegment]

    init(segments: [SourceSegment]) {
        baselineSegments = segments
        self.segments = segments
    }

    var hasChanges: Bool {
        Self.ranges(in: baselineSegments) != Self.ranges(in: segments)
    }

    mutating func replace(with segments: [SourceSegment]) {
        self.segments = segments
    }

    mutating func commit() {
        baselineSegments = segments
    }

    mutating func discard() {
        segments = baselineSegments
    }

    private static func ranges(in segments: [SourceSegment]) -> [ProjectTimeRange] {
        segments.map(\.sourceRange)
    }
}
