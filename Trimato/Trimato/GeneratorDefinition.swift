import Foundation

nonisolated enum GeneratorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, solidColor, gradient, silence
    var id: Self { self }
    var title: String {
        switch self {
        case .black: "Black"
        case .solidColor: "Solid Color"
        case .gradient: "Static Gradient"
        case .silence: "Silence"
        }
    }
    var description: String {
        switch self {
        case .black: "A full frame of black with no audio."
        case .solidColor: "One color fills the entire frame, with no audio."
        case .gradient: "Two colors blend in a fixed direction. The image does not move and has no audio."
        case .silence: "An audio clip containing no sound."
        }
    }
    var trackKind: TimelineTrackKind { self == .silence ? .audio : .video }
}

nonisolated enum GeneratorColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, white, red, green, blue, yellow, cyan, magenta, gray
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

nonisolated enum GradientDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftToRight, topToBottom
    var id: Self { self }
    var title: String { self == .leftToRight ? "Left to Right" : "Top to Bottom" }
}

nonisolated enum GeneratorChannels: String, Codable, CaseIterable, Identifiable, Sendable {
    case mono, stereo
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

nonisolated struct GeneratorDefinition: Codable, Hashable, Sendable {
    var kind: GeneratorKind = .black
    var color: GeneratorColor = .black
    var secondColor: GeneratorColor = .white
    var direction: GradientDirection = .leftToRight
    var channels: GeneratorChannels = .stereo
    var duration = ProjectTime(seconds: 5)
    var width = 1920
    var height = 1080
    var frameRate = 30.0

    func validate() throws {
        guard duration.seconds.isFinite, duration.isPositive, duration.seconds <= 86_400,
              width >= 2, height >= 2, width <= 8192, height <= 8192,
              frameRate.isFinite, frameRate > 0, frameRate <= 240 else {
            throw MediaSourceError.unreadable("Choose a duration greater than zero and no more than 24 hours, and a supported project video format.")
        }
    }

    var sourceFilter: String {
        switch kind {
        case .black, .solidColor:
            return "color=c=\(kind == .black ? "black" : color.rawValue):s=\(width)x\(height):r=\(frameRate)"
        case .gradient:
            let x = direction == .leftToRight ? width - 1 : 0
            let y = direction == .topToBottom ? height - 1 : 0
            return "gradients=s=\(width)x\(height):r=\(frameRate):c0=\(color.rawValue):c1=\(secondColor.rawValue):n=2:x0=0:y0=0:x1=\(x):y1=\(y):speed=0:seed=0"
        case .silence:
            return "anullsrc=r=48000:cl=\(channels.rawValue)"
        }
    }

    func assetRecord() -> MediaAssetRecord {
        MediaAssetRecord(
            name: kind.title, originalPath: "", duration: duration,
            naturalWidth: kind == .silence ? nil : width,
            naturalHeight: kind == .silence ? nil : height,
            frameRate: kind == .silence ? nil : frameRate,
            hasAudio: kind == .silence,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: duration))],
            playbackMode: .nativePassthrough, generator: self
        )
    }
}
