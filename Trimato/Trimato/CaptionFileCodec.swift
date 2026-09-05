import Foundation

nonisolated enum CaptionFileCodec {
    static func decode(data: Data, format: CaptionFileFormat) throws -> [CaptionCue] {
        guard let source = decodedString(data) else { throw CaptionFileError.unreadableText }
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
        let cues = try format == .subRip ? decodeSubRip(normalized) : decodeWebVTT(normalized)
        guard !cues.isEmpty else { throw CaptionFileError.noCues }
        return cues.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    static func encode(_ cues: [CaptionCue], format: CaptionFileFormat) throws -> Data {
        let sorted = try cues.map { try $0.validated() }.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        let body: String
        if format == .subRip {
            body = sorted.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n")
        } else {
            body = sorted.map { cue in
                let identifier = cue.identifier.map { "\($0)\n" } ?? ""
                let settings = cue.webVTTSettings.map { " \($0)" } ?? ""
                return "\(identifier)\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\(settings)\n\(cue.text)"
            }.joined(separator: "\n\n")
        }
        let result = (format == .webVTT ? "WEBVTT\n\n" : "") + body + (body.isEmpty ? "" : "\n")
        return Data(result.utf8)
    }

    static func encodePlainText(_ cues: [CaptionCue], projectTitle: String) throws -> Data {
        let sorted = try cues.map { try $0.validated() }.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        let paragraphs = sorted.map { cue in
            cue.text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        let title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = paragraphs.joined(separator: "\n\n")
        let result = title + (body.isEmpty ? "" : "\n\n\(body)") + "\n"
        return Data(result.utf8)
    }

    static func cues(_ cues: [CaptionCue], within range: ProjectTimeRange?) -> [CaptionCue] {
        guard let range else { return cues }
        return cues.compactMap { cue in
            let start = max(cue.start, range.start)
            let end = min(cue.end, range.end)
            guard end > start else { return nil }
            var shifted = cue
            shifted.start = start - range.start
            shifted.end = end - range.start
            return shifted
        }
    }

    private static func decodedString(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSubRip(_ source: String) throws -> [CaptionCue] {
        try splitBlocks(source).enumerated().compactMap { offset, block in
            var lines = block.components(separatedBy: "\n")
            guard !lines.isEmpty else { return nil }
            if Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil { lines.removeFirst() }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                throw CaptionFileError.malformedCue(offset + 1, "The timing line is missing.")
            }
            let range = try parseTiming(lines[timingIndex], cueNumber: offset + 1, webVTT: false)
            let text = visibleCaptionText(lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
            return try CaptionCue(start: range.start, end: range.end, text: text).validated()
        }
    }

    private static func decodeWebVTT(_ source: String) throws -> [CaptionCue] {
        var blocks = splitBlocks(source)
        guard let header = blocks.first,
              header.components(separatedBy: "\n").first?.hasPrefix("WEBVTT") == true else {
            throw CaptionFileError.malformedCue(1, "The WEBVTT header is missing.")
        }
        blocks.removeFirst()
        var cueNumber = 0
        var cues: [CaptionCue] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            if first == "STYLE" || first == "REGION" || first.hasPrefix("NOTE") { continue }
            cueNumber += 1
            let timingIndex = first.contains("-->") ? 0 : 1
            guard lines.indices.contains(timingIndex), lines[timingIndex].contains("-->") else {
                throw CaptionFileError.malformedCue(cueNumber, "The timing line is missing.")
            }
            let parsed = try parseWebVTTTiming(lines[timingIndex], cueNumber: cueNumber)
            let rawText = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = timingIndex == 1 ? first.trimmingCharacters(in: .whitespaces) : nil
            cues.append(try CaptionCue(
                start: parsed.start,
                end: parsed.end,
                text: visibleCaptionText(rawText),
                identifier: identifier?.isEmpty == false ? identifier : nil,
                webVTTSettings: parsed.settings
            ).validated())
        }
        return cues
    }

    private static func splitBlocks(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\\n[ \\t]*\\n", with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseTiming(_ line: String, cueNumber: Int, webVTT: Bool) throws -> (start: ProjectTime, end: ProjectTime) {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces), webVTT: webVTT),
              let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces), webVTT: webVTT) else {
            throw CaptionFileError.malformedCue(cueNumber, "The timestamps are invalid.")
        }
        return (start, end)
    }

    private static func parseWebVTTTiming(_ line: String, cueNumber: Int) throws -> (start: ProjectTime, end: ProjectTime, settings: String?) {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { throw CaptionFileError.malformedCue(cueNumber, "The timing separator is invalid.") }
        let remainder = parts[1].trimmingCharacters(in: .whitespaces)
        let endParts = remainder.split(whereSeparator: { $0.isWhitespace })
        guard let endText = endParts.first,
              let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces), webVTT: true),
              let end = parseTimestamp(String(endText), webVTT: true) else {
            throw CaptionFileError.malformedCue(cueNumber, "The timestamps are invalid.")
        }
        let settings = endParts.dropFirst().joined(separator: " ")
        return (start, end, settings.isEmpty ? nil : settings)
    }

    private static func parseTimestamp(_ value: String, webVTT: Bool) -> ProjectTime? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              webVTT || parts.count == 3,
              let seconds = Double(parts.last ?? ""), seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours: Int
        if parts.count == 3 {
            guard let parsedHours = Int(parts[0]), parsedHours >= 0 else { return nil }
            hours = parsedHours
        } else { hours = 0 }
        return ProjectTime(seconds: Double(hours * 3_600 + minutes * 60) + seconds)
    }

    private static func timestamp(_ time: ProjectTime, separator: String) -> String {
        let milliseconds = max(Int((time.seconds * 1_000).rounded()), 0)
        return String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000,
                      (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60,
                      separator, milliseconds % 1_000)
    }

    private static func visibleCaptionText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&lrm;": "\u{200e}", "&rlm;": "\u{200f}", "&nbsp;": "\u{a0}"] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
