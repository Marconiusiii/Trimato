import AVFoundation

/// Read compressed sample timing near the playhead without decoding a whole movie.
/// Map source timestamps into the edited timeline without depending on compressed composition preroll.
actor FrameWindowIndex {
    private let asset: AVAsset
    private let duration: CMTime
    private let sourceRanges: [CMTimeRange]
    private let editedEnds: [CMTime]
    private var windows: [(CMTimeRange, [CMTime])] = []

    init(asset: AVAsset, duration: CMTime, sourceRanges: [CMTimeRange]? = nil) {
        self.asset = asset; self.duration = duration
        let ranges = sourceRanges ?? [CMTimeRange(start: .zero, duration: duration)]
        self.sourceRanges = ranges
        var cursor = CMTime.zero
        self.editedEnds = ranges.map { range in cursor = cursor + range.duration; return cursor }
    }

    func target(from time: CMTime, forward: Bool, count: Int) async throws -> CMTime {
        try Task.checkCancellation()
        let count = max(count, 1)
        for (range, timestamps) in windows where time >= range.start && time <= range.end {
            if let target = Self.target(in: timestamps, from: time, forward: forward, count: count) { return target }
        }
        var span = max(2, Double(count) / 12)
        while true {
            try Task.checkCancellation()
            let start = max(0, time.seconds - (forward ? 1 : span))
            let end = min(duration.seconds, time.seconds + (forward ? span : 1))
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000_000),
                                    end: CMTime(seconds: end, preferredTimescale: 1_000_000))
            let timestamps: [CMTime]
            if let window = windows.first(where: { CMTimeRangeContainsTimeRange($0.0, otherRange: range) }) {
                timestamps = window.1
            } else {
                timestamps = try await readWindow(range)
                windows.insert((range, timestamps), at: 0)
                // Keep bounded working data rather than the complete source frame list.
                if windows.count > 3 { windows.removeLast() }
            }
            if let target = Self.target(in: timestamps, from: time, forward: forward, count: count) { return target }
            if forward && end >= duration.seconds { return duration }
            if !forward && start <= 0 { return .zero }
            span *= 2
        }
    }

    private func readWindow(_ window: CMTimeRange) async throws -> [CMTime] {
        guard let first = FrameTimestampSearch.firstAfter(window.start, in: editedEnds) else { return [] }
        var cursor = first == 0 ? .zero : editedEnds[first - 1]
        var result: [CMTime] = []
        for source in sourceRanges[first...] {
            try Task.checkCancellation()
            let edited = CMTimeRange(start: cursor, duration: source.duration)
            let overlap = CMTimeRangeGetIntersection(window, otherRange: edited)
            if overlap.isValid, overlap.duration > .zero {
                let requested = CMTimeRange(start: source.start + (overlap.start - cursor), duration: overlap.duration)
                let timestamps = try await Self.read(asset: asset, range: requested)
                result += timestamps.map { cursor + ($0 - source.start) }
            }
            cursor = cursor + source.duration
            if cursor >= window.end { break }
        }
        return result
    }

    private static func target(in timestamps: [CMTime], from time: CMTime, forward: Bool, count: Int) -> CMTime? {
        if forward, let first = FrameTimestampSearch.firstAfter(time, in: timestamps),
           count <= timestamps.count - first { return timestamps[first + count - 1] }
        if !forward, let last = FrameTimestampSearch.lastBefore(time, in: timestamps),
           count <= last + 1 { return timestamps[last - count + 1] }
        return nil
    }

    @concurrent
    static func read(asset: AVAsset, range: CMTimeRange) async throws -> [CMTime] {
        try Task.checkCancellation()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaSourceError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        var output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if !reader.canAdd(output) {
            // Composition tracks may require decoded samples. Only decode this timing window.
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaSourceError.unreadable("The clip's video frames could not be read.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.emptyFrameIndex }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Reader outputs can include zero-sample end or discontinuity markers.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            // A compressed buffer can contain more than one sample.
            var needed = 0
            let status = CMSampleBufferGetOutputSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
            guard status == noErr || status == kCMSampleBufferError_ArrayTooSmall else { throw MediaSourceError.unreadable("The clip's video frames could not be read.") }
            var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
            guard CMSampleBufferGetOutputSampleTimingInfoArray(sample, entryCount: needed, arrayToFill: &timings, entriesNeededOut: &needed) == noErr else {
                throw MediaSourceError.unreadable("The clip's video frames could not be read.")
            }
            for timing in timings {
                let time = timing.presentationTimeStamp
                if time.isNumeric, CMTimeRangeContainsTime(range, time: time) { timestamps.append(time) }
            }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? AnalysisError.emptyFrameIndex }
        timestamps.sort { CMTimeCompare($0, $1) < 0 }
        var unique: [CMTime] = []
        for time in timestamps where unique.last.map({ CMTimeCompare($0, time) != 0 }) ?? true { unique.append(time) }
        return unique
    }
}
