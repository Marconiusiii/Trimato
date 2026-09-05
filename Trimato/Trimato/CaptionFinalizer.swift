import Foundation

nonisolated struct CaptionFinalizationIssue: Equatable, Identifiable, Sendable {
    let cueID: UUID
    let captionNumber: Int
    let text: String
    let markedStart: ProjectTime
    let markedEnd: ProjectTime
    let requiredDuration: Double?
    let availableDuration: Double
    let message: String

    var id: UUID { cueID }

    var displayName: String {
        let firstLine = text.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? "Caption \(captionNumber)" : "Caption: \(firstLine)"
    }
}

nonisolated struct CaptionFinalizationResult: Equatable, Sendable {
    let cues: [CaptionCue]
    let finalizedPassages: Int
    let createdCues: Int
    let issues: [CaptionFinalizationIssue]

    var changed: Bool { finalizedPassages > 0 }
}

nonisolated enum CaptionFinalizer {
    private struct Word: Equatable {
        let text: String
        let hardBreakBefore: Bool
    }

    private struct Segment {
        let range: Range<Int>
        let text: String
    }

    private struct Path {
        let cost: Int
        let segments: [Segment]
    }

    private struct PathKey: Hashable {
        let wordEnd: Int
        let segmentCount: Int
    }

    private enum FinalizeOutcome {
        case success([CaptionCue])
        case failure(message: String, requiredDuration: Double?, availableDuration: Double)
    }

    private static let targetWordsPerMinute = 160.0
    private static let minimumFramesPerCue = 40.0
    private static let maximumSecondsPerCue = 6.0
    private static let maximumWordsPerCue = 50

    static func finalize(
        cues: [CaptionCue],
        projectDuration: ProjectTime,
        width: Int,
        height: Int,
        frameRate: Double
    ) -> CaptionFinalizationResult {
        let sorted = cues.sorted(by: cueOrder)
        let rate = max(frameRate.isFinite ? frameRate : 30, 1)
        var output: [CaptionCue] = []
        var issues: [CaptionFinalizationIssue] = []
        var finalizedPassages = 0
        var createdCues = 0

        for (index, cue) in sorted.enumerated() {
            guard cue.isDraft else {
                output.append(cue)
                continue
            }
            let nextStart = sorted.dropFirst(index + 1).map(\.start).min() ?? projectDuration
            switch finalize(
                cue,
                nextStart: nextStart,
                projectDuration: projectDuration,
                width: width,
                height: height,
                frameRate: rate
            ) {
            case .success(let finalized):
                output.append(contentsOf: finalized)
                finalizedPassages += 1
                createdCues += finalized.count
            case .failure(let message, let requiredDuration, let availableDuration):
                output.append(cue)
                issues.append(CaptionFinalizationIssue(
                    cueID: cue.id,
                    captionNumber: index + 1,
                    text: cue.text,
                    markedStart: cue.start,
                    markedEnd: cue.end,
                    requiredDuration: requiredDuration,
                    availableDuration: availableDuration,
                    message: message
                ))
            }
        }

        return CaptionFinalizationResult(
            cues: output.sorted(by: cueOrder),
            finalizedPassages: finalizedPassages,
            createdCues: createdCues,
            issues: issues
        )
    }

    private static func finalize(
        _ cue: CaptionCue,
        nextStart: ProjectTime,
        projectDuration: ProjectTime,
        width: Int,
        height: Int,
        frameRate: Double
    ) -> FinalizeOutcome {
        let words = words(in: cue.text)
        let availableEnd = min(nextStart.seconds, projectDuration.seconds)
        let availableDuration = max(availableEnd - cue.start.seconds, 0)
        guard !words.isEmpty else {
            return .failure(
                message: "Enter caption text.",
                requiredDuration: nil,
                availableDuration: availableDuration
            )
        }
        let originalDuration = cue.duration.seconds
        let requiredReadingDuration = Double(words.count) * 60 / targetWordsPerMinute
        let minimumSegmentCount = max(
            Int(ceil(max(originalDuration, requiredReadingDuration) / maximumSecondsPerCue)),
            1
        )
        guard let segments = segments(
            for: words,
            minimumCount: minimumSegmentCount,
            width: width,
            height: height
        ) else {
            return .failure(
                message: "The text cannot be divided into captions of two lines or fewer.",
                requiredDuration: nil,
                availableDuration: availableDuration
            )
        }

        let requiredMinimumDuration = Double(segments.count) * minimumFramesPerCue / frameRate
        let unsnappedDuration = max(originalDuration, requiredReadingDuration, requiredMinimumDuration)
        let usedDuration = ceil(unsnappedDuration * frameRate - 0.000_001) / frameRate
        let requestedEnd = cue.start.seconds + usedDuration
        guard requestedEnd <= availableEnd + 0.000_001 else {
            return .failure(
                message: "The text needs more display time before the next caption or the end of the project.",
                requiredDuration: usedDuration,
                availableDuration: availableDuration
            )
        }
        guard usedDuration <= Double(segments.count) * maximumSecondsPerCue + 0.000_001 else {
            return .failure(
                message: "The passage needs to be divided into more captions.",
                requiredDuration: usedDuration,
                availableDuration: availableDuration
            )
        }
        guard let durations = distributedDurations(
            weights: segments.map { Double($0.range.count) },
            total: usedDuration,
            minimum: minimumFramesPerCue / frameRate,
            maximum: maximumSecondsPerCue
        ) else {
            return .failure(
                message: "The passage cannot be divided into readable caption durations.",
                requiredDuration: usedDuration,
                availableDuration: availableDuration
            )
        }

        var finalized: [CaptionCue] = []
        var start = cue.start.seconds
        for index in segments.indices {
            let end = index == segments.indices.last
                ? cue.start.seconds + usedDuration
                : snapped(start + durations[index], relativeTo: cue.start.seconds, frameRate: frameRate)
            finalized.append(CaptionCue(
                id: index == segments.indices.first ? cue.id : UUID(),
                start: ProjectTime(seconds: start),
                end: ProjectTime(seconds: end),
                text: segments[index].text,
                isDraft: false
            ))
            start = end
        }
        return .success(finalized)
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var startsNewLine = false
        for line in text.components(separatedBy: .newlines) {
            let lineWords = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (index, word) in lineWords.enumerated() {
                result.append(Word(text: word, hardBreakBefore: startsNewLine && index == 0))
            }
            if !lineWords.isEmpty || !result.isEmpty { startsNewLine = true }
        }
        return result
    }

    private static func segments(
        for words: [Word],
        minimumCount: Int,
        width: Int,
        height: Int
    ) -> [Segment]? {
        var paths = [PathKey: Path]()
        paths[PathKey(wordEnd: 0, segmentCount: 0)] = Path(cost: 0, segments: [])
        guard !words.isEmpty else { return nil }

        for start in words.indices {
            let startingPaths = paths.filter { $0.key.wordEnd == start }
            guard !startingPaths.isEmpty else { continue }
            let lastEnd = min(words.count, start + maximumWordsPerCue)
            for (_, path) in startingPaths {
                for end in (start + 1)...lastEnd {
                    let range = start..<end
                    guard let text = formattedText(for: words, range: range, width: width, height: height) else {
                        if words[range].filter(\.hardBreakBefore).count > 1 { break }
                        continue
                    }
                    let candidate = Segment(range: range, text: text)
                    let count = path.segments.count + 1
                    let key = PathKey(wordEnd: end, segmentCount: count)
                    let cost = path.cost + 1_000 + boundaryPenalty(words: words, end: end)
                    if paths[key] == nil || cost < paths[key]!.cost {
                        paths[key] = Path(cost: cost, segments: path.segments + [candidate])
                    }
                }
            }
        }
        return paths
            .filter { $0.key.wordEnd == words.count && $0.key.segmentCount >= minimumCount }
            .map(\.value)
            .min(by: { $0.cost < $1.cost })?
            .segments
    }

    private static func formattedText(
        for words: [Word],
        range: Range<Int>,
        width: Int,
        height: Int
    ) -> String? {
        let manualBreaks = range.dropFirst().filter { words[$0].hardBreakBefore }
        guard manualBreaks.count <= 1 else { return nil }
        if let split = manualBreaks.first {
            let text = joined(words, range.lowerBound..<split) + "\n" + joined(words, split..<range.upperBound)
            return fits(text, width: width, height: height, maximumLines: 2) ? text : nil
        }

        let plain = joined(words, range)
        if fits(plain, width: width, height: height, maximumLines: 1) { return plain }
        guard range.count > 1 else { return nil }

        var best: (text: String, score: Int)?
        for split in (range.lowerBound + 1)..<range.upperBound {
            let first = joined(words, range.lowerBound..<split)
            let second = joined(words, split..<range.upperBound)
            let text = first + "\n" + second
            guard fits(text, width: width, height: height, maximumLines: 2) else { continue }
            let imbalance = abs(first.count - second.count)
            let topHeavyPenalty = max(first.count - second.count, 0)
            let score = boundaryPenalty(words: words, end: split) * 10 + imbalance + topHeavyPenalty
            if best == nil || score < best!.score { best = (text, score) }
        }
        return best?.text
    }

    private static func joined(_ words: [Word], _ range: Range<Int>) -> String {
        words[range].map(\.text).joined(separator: " ")
    }

    private static func fits(_ text: String, width: Int, height: Int, maximumLines: Int) -> Bool {
        var definition = GeneratorDefinition()
        definition.kind = .text
        definition.width = max(width, 2)
        definition.height = max(height, 2)
        definition.textSettings.apply(.caption)
        definition.textSettings.text = text
        guard let layout = try? TextGeneratorRenderer.layout(definition) else { return false }
        return layout.fits && layout.lineCount <= maximumLines
    }

    private static func boundaryPenalty(words: [Word], end: Int) -> Int {
        guard end < words.count else { return 0 }
        let last = words[end - 1].text
        if words[end].hardBreakBefore { return 0 }
        if last.last.map({ ".!?".contains($0) }) == true { return 0 }
        if last.last.map({ ",;:".contains($0) }) == true { return 6 }
        let next = words[end].text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if ["and", "but", "or", "because", "so", "if", "when", "while", "for", "from", "to", "with"].contains(next) {
            return 10
        }
        return 30
    }

    private static func distributedDurations(
        weights: [Double],
        total: Double,
        minimum: Double,
        maximum: Double
    ) -> [Double]? {
        guard !weights.isEmpty,
              total + 0.000_001 >= minimum * Double(weights.count),
              total <= maximum * Double(weights.count) + 0.000_001 else { return nil }
        var result = Array(repeating: 0.0, count: weights.count)
        var remaining = Set(weights.indices)
        var remainingTime = total
        while !remaining.isEmpty {
            let weightTotal = remaining.reduce(0) { $0 + max(weights[$1], 1) }
            if let index = remaining.first(where: {
                remainingTime * max(weights[$0], 1) / weightTotal < minimum
            }) {
                result[index] = minimum
                remainingTime -= minimum
                remaining.remove(index)
            } else if let index = remaining.first(where: {
                remainingTime * max(weights[$0], 1) / weightTotal > maximum
            }) {
                result[index] = maximum
                remainingTime -= maximum
                remaining.remove(index)
            } else {
                for index in remaining {
                let share = remainingTime * max(weights[index], 1) / weightTotal
                    result[index] = share
                }
                remaining.removeAll()
            }
        }
        return result
    }

    private static func snapped(_ time: Double, relativeTo origin: Double, frameRate: Double) -> Double {
        origin + ((time - origin) * frameRate).rounded() / frameRate
    }

    private static func cueOrder(_ lhs: CaptionCue, _ rhs: CaptionCue) -> Bool {
        if lhs.start == rhs.start { return lhs.end < rhs.end }
        return lhs.start < rhs.start
    }
}
