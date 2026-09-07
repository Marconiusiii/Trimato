import Foundation

nonisolated struct RecordingPreviewRange: Equatable {
    let start: Double
    let end: Double?

    init(start: Double, end: Double, bounded: Bool) {
        self.start = start
        self.end = bounded ? end : nil
    }

    func position(resuming time: Double?) -> Double {
        guard let time, time.isFinite else { return start }
        if let end, time >= end { return start }
        return max(start, time)
    }
}
