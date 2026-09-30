import AVFoundation

enum EditedCompositionBuilder {
    static func audioAsset(asset: AVAsset, sourceRanges: [CMTimeRange]) async throws -> AVAsset {
        if let spatial = try await SpatialAudioPlan.clip(asset: asset, ranges: sourceRanges) {
            return try await spatial.movie(includeSourceVideo: false).0
        }
        let composition = AVMutableComposition()
        try await insertFirstTrack(of: .audio, from: asset, sourceRanges: sourceRanges, into: composition)
        let duration = sourceRanges.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
        if composition.duration < duration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                duration: CMTimeSubtract(duration, composition.duration)))
        }
        return composition
    }

    static func playbackAsset(asset: AVAsset, sourceRanges: [CMTimeRange], includeVideo: Bool = true) async throws -> AVAsset {
        if let spatial = try await SpatialAudioPlan.clip(asset: asset, ranges: sourceRanges) {
            return try await spatial.movie(includeSourceVideo: includeVideo).0
        }
        if !includeVideo { return try await audioAsset(asset: asset, sourceRanges: sourceRanges) }
        return try await build(asset: asset, sourceRanges: sourceRanges)
    }

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

        func lowerBound(_ time: CMTime) -> Int {
            var lower = 0
            var upper = sourceTimestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if CMTimeCompare(sourceTimestamps[middle], time) < 0 { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }

        for range in sourceRanges {
            for timestamp in sourceTimestamps[lowerBound(range.start)..<lowerBound(range.end)] {
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
        let selected = mediaType == .audio
            ? try await AudioProcessingFormat.selectedTrack(in: asset)
            : try await asset.loadTracks(withMediaType: mediaType).first
        guard let sourceTrack = selected,
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
