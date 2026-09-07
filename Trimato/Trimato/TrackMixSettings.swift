import Foundation

nonisolated enum TrackChannelRouting: String, Codable, CaseIterable, Identifiable, Sendable {
    case both, left, right, swap
    var id: Self { self }
    var title: String {
        switch self {
        case .both: "Both channels"
        case .left: "Left channel only"
        case .right: "Right channel only"
        case .swap: "Swap left and right"
        }
    }
}

nonisolated struct TrackMixSettings: Codable, Hashable, Sendable {
    var volumeDB: Double = 0
    var pan: Double = 0
    var balance: Double = 0
    var width: Double = 1
    var routing: TrackChannelRouting = .both
    static let neutral = Self()

    var normalized: Self {
        var value = self
        value.volumeDB = Self.bounded(volumeDB, -60...12, fallback: 0)
        value.pan = Self.bounded(pan, -1...1, fallback: 0)
        value.balance = Self.bounded(balance, -1...1, fallback: 0)
        value.width = Self.bounded(width, 0...2, fallback: 1)
        return value
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    func matrix(masterDB: Double = 0, silent: Bool = false) -> StereoMixMatrix {
        guard !silent else { return .silent }
        let value = normalized
        let gain = pow(10, (value.volumeDB + Self.bounded(masterDB, -60...12, fallback: 0)) / 20)
        func transform(_ left: Double, _ right: Double) -> (Double, Double) {
            var l = left, r = right
            switch value.routing {
            case .both: break
            case .left: r = l
            case .right: l = r
            case .swap: swap(&l, &r)
            }
            let mid = (l + r) / 2, side = (l - r) / 2 * value.width
            l = mid + side; r = mid - side
            // Move stereo material toward either side while preserving both input channels.
            let angle = (value.pan + 1) * Double.pi / 4
            if value.pan < 0 {
                l = (l - r * value.pan) / (1 - value.pan) * sqrt(2) * cos(angle)
                r *= sqrt(2) * sin(angle)
            } else if value.pan > 0 {
                r = (r + l * value.pan) / (1 + value.pan) * sqrt(2) * sin(angle)
                l *= sqrt(2) * cos(angle)
            }
            l *= 1 - max(value.balance, 0)
            r *= 1 + min(value.balance, 0)
            return (l * gain, r * gain)
        }
        let a = transform(1, 0), b = transform(0, 1)
        return StereoMixMatrix(ll: a.0, lr: b.0, rl: a.1, rr: b.1)
    }
}

nonisolated struct StereoMixMatrix: Equatable, Sendable {
    var ll: Double = 1, lr: Double = 0, rl: Double = 0, rr: Double = 1
    static let silent = Self(ll: 0, lr: 0, rl: 0, rr: 0)
    func apply(left: Double, right: Double) -> (Double, Double) {
        (left * ll + right * lr, left * rl + right * rr)
    }
}
