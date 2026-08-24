import CoreMedia
import Foundation

nonisolated struct ProjectTime: Codable, Hashable, Comparable, Sendable {
    static let defaultTimescale: Int32 = 600_000
    static let zero = ProjectTime(value: 0, timescale: defaultTimescale)

    var value: Int64
    var timescale: Int32

    init(value: Int64, timescale: Int32) {
        if timescale > 0 {
            self.value = value
            self.timescale = timescale
        } else {
            self.value = 0
            self.timescale = Self.defaultTimescale
        }
    }

    init(seconds: Double, timescale: Int32 = defaultTimescale) {
        self.init(CMTime(seconds: seconds.isFinite ? seconds : 0, preferredTimescale: timescale))
    }

    init(_ time: CMTime) {
        let normalized = time.isValid && time.isNumeric
            ? time.convertScale(Self.defaultTimescale, method: .roundHalfAwayFromZero)
            : .zero
        value = normalized.value
        timescale = normalized.timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { CMTimeGetSeconds(cmTime) }
    var isPositive: Bool { self > .zero }

    static func < (lhs: ProjectTime, rhs: ProjectTime) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0
    }

    static func + (lhs: ProjectTime, rhs: ProjectTime) -> ProjectTime {
        ProjectTime(CMTimeAdd(lhs.cmTime, rhs.cmTime))
    }

    static func - (lhs: ProjectTime, rhs: ProjectTime) -> ProjectTime {
        ProjectTime(CMTimeSubtract(lhs.cmTime, rhs.cmTime))
    }
}

nonisolated struct ProjectTimeRange: Codable, Hashable, Sendable {
    var start: ProjectTime
    var duration: ProjectTime

    var end: ProjectTime { start + duration }
    var isValid: Bool { start >= .zero && duration.isPositive }

    init(start: ProjectTime, duration: ProjectTime) {
        self.start = start
        self.duration = duration
    }

    init(_ range: CMTimeRange) {
        start = ProjectTime(range.start)
        duration = ProjectTime(range.duration)
    }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }
}
