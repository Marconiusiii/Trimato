import Foundation

nonisolated enum GeneratorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, solidColor, gradient, silence, text
    var id: Self { self }
    var title: String {
        switch self {
        case .black: "Black"
        case .solidColor: "Solid Color"
        case .gradient: "Static Gradient"
        case .silence: "Silence"
        case .text: "Text"
        }
    }
    var description: String {
        switch self {
        case .black: "A full frame of black with no audio."
        case .solidColor: "One color fills the entire frame, with no audio."
        case .gradient: "Two colors blend in a fixed direction. The image does not move and has no audio."
        case .silence: "An audio clip containing no sound."
        case .text: "Editable titles, lower thirds, captions, and subtitles, on black or over underlying video."
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
    // Optional so existing generator definitions decode without migration.
    var text: TextGeneratorSettings?
    var textSettings: TextGeneratorSettings {
        get { text ?? TextGeneratorSettings() }
        set { text = newValue }
    }
    var hasAlpha: Bool { kind == .text && textSettings.background == .transparent }

    func validate() throws {
        guard duration.seconds.isFinite, duration.isPositive, duration.seconds <= 86_400,
              width >= 2, height >= 2, width <= 8192, height <= 8192,
              frameRate.isFinite, frameRate > 0, frameRate <= 240 else {
            throw MediaSourceError.unreadable("Choose a duration greater than zero and no more than 24 hours, and a supported project video format.")
        }
        if kind == .text { try textSettings.validate() }
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
        case .text:
            // Text uses a native rendered image, not a lavfi source.
            return ""
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

/// Generator sources have their own stable names, independent of timeline copies.
nonisolated enum GeneratorSourceNaming {
    static func nextName(base: String, usedNames: [String]) -> String {
        let used = Set(usedNames.map { $0.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var ordinal = 0
        while used.contains("\(base) \(TimelineClip.letterLabel(for: ordinal))".lowercased()) {
            ordinal += 1
        }
        return "\(base) \(TimelineClip.letterLabel(for: ordinal))"
    }

    static func usedNames(in project: TrimatoProject) -> [String] {
        project.media.map(\.name) + project.tracks.flatMap(\.clips).map(\.displayName)
            + project.primaryTimeline.map(\.displayName) + project.cutaways.map(\.displayName)
    }

    /// Older projects saved each generated source with its unsuffixed kind title.
    /// Preserve all other source names and every explicit timeline customName.
    static func normalize(in project: inout TrimatoProject) {
        let original = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        var reserved = project.media.filter { $0.generator?.kind.title != $0.name }.map(\.name)
        reserved += project.tracks.flatMap(\.clips).compactMap(\.customName)
        reserved += project.primaryTimeline.compactMap(\.customName) + project.cutaways.compactMap(\.customName)
        var names: [UUID: String] = [:]
        for index in project.media.indices {
            guard let generator = project.media[index].generator else { continue }
            if project.media[index].name == generator.kind.title {
                project.media[index].name = nextName(base: generator.kind.title, usedNames: reserved)
                reserved.append(project.media[index].name)
            }
            names[project.media[index].id] = project.media[index].name
        }
        var instances: [UUID: Set<UUID>] = [:]
        for clip in project.tracks.flatMap(\.clips) + project.primaryTimeline {
            instances[clip.assetID, default: []].insert(clip.id)
        }
        for clip in project.cutaways { instances[clip.assetID, default: []].insert(clip.id) }
        func renamed(_ clip: TimelineClip) -> TimelineClip {
            guard clip.customName == nil, let name = names[clip.assetID],
                  clip.name == original[clip.assetID]?.name else { return clip }
            var clip = clip
            clip.name = name
            if instances[clip.assetID]?.count == 1 { clip.labelOrdinal = nil }
            return clip
        }
        for track in project.tracks.indices {
            project.tracks[track].clips = project.tracks[track].clips.map(renamed)
        }
        project.primaryTimeline = project.primaryTimeline.map(renamed)
        for index in project.cutaways.indices {
            let clip = project.cutaways[index]
            guard clip.customName == nil, let name = names[clip.assetID],
                  clip.name == original[clip.assetID]?.name else { continue }
            project.cutaways[index].name = name
            if instances[clip.assetID]?.count == 1 { project.cutaways[index].labelOrdinal = nil }
        }
    }
}
