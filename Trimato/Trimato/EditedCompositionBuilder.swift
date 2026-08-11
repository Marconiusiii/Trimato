import AVFoundation

enum EditedCompositionBuilder {
    static func build(asset: AVAsset, sourceRanges: [CMTimeRange]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        try await insertFirstTrack(
            of: .video,
            from: asset,
            sourceRanges: sourceRanges,
            into: composition
        )
        try await insertFirstTrack(
            of: .audio,
            from: asset,
            sourceRanges: sourceRanges,
            into: composition
        )
        return composition
    }

    static func editedFrameTimestamps(
        sourceTimestamps: [CMTime],
        sourceRanges: [CMTimeRange]
    ) -> [CMTime] {
        var result: [CMTime] = []
        var editedCursor = CMTime.zero

        for range in sourceRanges {
            for timestamp in sourceTimestamps where
                CMTimeCompare(timestamp, range.start) >= 0 &&
                CMTimeCompare(timestamp, range.end) < 0 {
                result.append(CMTimeAdd(editedCursor, CMTimeSubtract(timestamp, range.start)))
            }
            editedCursor = CMTimeAdd(editedCursor, range.duration)
        }
        return result
    }

    private static func insertFirstTrack(
        of mediaType: AVMediaType,
        from asset: AVAsset,
        sourceRanges: [CMTimeRange],
        into composition: AVMutableComposition
    ) async throws {
        guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { return }

        let availableRange = try await sourceTrack.load(.timeRange)
        var editedCursor = CMTime.zero
        for range in sourceRanges {
            let availablePortion = CMTimeRangeGetIntersection(range, otherRange: availableRange)
            if availablePortion.isValid, !availablePortion.isEmpty {
                let sourceOffset = CMTimeSubtract(availablePortion.start, range.start)
                try compositionTrack.insertTimeRange(
                    availablePortion,
                    of: sourceTrack,
                    at: CMTimeAdd(editedCursor, sourceOffset)
                )
            }
            editedCursor = CMTimeAdd(editedCursor, range.duration)
        }

        if mediaType == .video {
            compositionTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
        }
    }
}
