import CoreMedia

/// Search presentation timestamps without walking every preceding video frame.
nonisolated enum FrameTimestampSearch {
    static func firstAfter(_ time: CMTime, in timestamps: [CMTime]) -> Int? {
        let index = boundary(time, in: timestamps, inclusive: true)
        return index < timestamps.count ? index : nil
    }

    static func lastBefore(_ time: CMTime, in timestamps: [CMTime]) -> Int? {
        let index = boundary(time, in: timestamps, inclusive: false)
        return index > 0 ? index - 1 : nil
    }

    private static func boundary(_ time: CMTime, in timestamps: [CMTime], inclusive: Bool) -> Int {
        var low = 0
        var high = timestamps.count
        while low < high {
            let middle = low + (high - low) / 2
            let comparison = CMTimeCompare(timestamps[middle], time)
            if comparison < 0 || (inclusive && comparison == 0) { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}
