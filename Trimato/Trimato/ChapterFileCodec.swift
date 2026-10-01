import Foundation

/// YouTube reads chapter timestamps from the video's description, in whole seconds.
nonisolated enum ChapterFileCodec {
    struct ValidationError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static func encode(markers: [TimelineMarker], duration: ProjectTime,
                       within range: ProjectTimeRange? = nil) throws -> Data {
        let interval = range ?? ProjectTimeRange(start: .zero, duration: duration)
        guard interval.isValid, interval.end <= duration else {
            throw ValidationError(message: "Set a valid export In and Out range, or clear both points.")
        }
        let chapters = markers.filter { $0.type == .chapter }.sorted {
            $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time
        }
        var selected = chapters.filter { $0.time >= interval.start && $0.time < interval.end }
        // An export beginning inside a chapter starts with that chapter's title.
        if selected.first?.time != interval.start,
           let active = chapters.last(where: { $0.time < interval.start }) {
            var first = active
            first.time = interval.start
            selected.insert(first, at: 0)
        }
        guard selected.first?.time == interval.start else {
            throw ValidationError(message: "Add a Chapter at the beginning of the exported range, or turn off Export YouTube Chapters.")
        }
        guard selected.count >= 3 else {
            throw ValidationError(message: "Add at least three Chapters in the exported range, or turn off Export YouTube Chapters.")
        }
        let seconds = selected.map { Int(($0.time - interval.start).seconds.rounded(.down)) }
        let end = interval.duration.seconds
        for index in seconds.indices {
            let next = index + 1 < seconds.count ? Double(seconds[index + 1]) : end
            guard next - Double(seconds[index]) >= 10 else {
                throw ValidationError(message: "Space Chapters at least 10 seconds apart and leave at least 10 seconds after the last Chapter, or turn off Export YouTube Chapters.")
            }
        }
        let lines = try zip(selected, seconds).map { chapter, second in
            let title = chapter.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !title.isEmpty else {
                throw ValidationError(message: "Give every exported Chapter a title, or turn off Export YouTube Chapters.")
            }
            return "\(timestamp(second)) \(title)"
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func timestamp(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
