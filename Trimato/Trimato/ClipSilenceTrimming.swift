import AVFoundation
import Foundation

nonisolated struct SilenceTrimSettings: Equatable, Sendable {
    var thresholdDB = -40.0
    var minimumPause = 0.6
    var retainedPause = 0.15
}

nonisolated struct SilenceTrimPlan: Sendable {
    let sourceRanges: [CMTimeRange]
    let removedCount: Int
    let removedSeconds: Double
    let removedRanges: [CMTimeRange]

    func remap(_ time: CMTime) -> CMTime {
        let removed = removedRanges.reduce(0.0) { total, range in
            total + max(0, min(time.seconds, range.end.seconds) - range.start.seconds)
        }
        return CMTime(seconds: max(0, time.seconds - removed), preferredTimescale: 600_000)
    }
}

nonisolated enum SilenceTrimError: LocalizedError {
    case noAudio, invalidSettings, entirelySilent, changedClip, undoUnavailable
    var errorDescription: String? {
        switch self {
        case .noAudio: "This clip has no audio to analyze."
        case .invalidSettings: "Check Quiet level and the pause lengths. Keep this much of each pause must be less than Shortest pause to trim."
        case .entirelySilent: "The selection is entirely silent. No changes were applied."
        case .changedClip: "The clip changed. Analyze it again before applying silence trimming."
        case .undoUnavailable: "Undo is unavailable in this editing window. No changes were applied."
        }
    }
}

nonisolated enum ClipSilenceTrimmer {
    @concurrent
    static func analyze(url: URL, timeline: ClipEditTimeline, selection: CMTimeRange,
                        settings: SilenceTrimSettings, frameRate: Double) async throws -> SilenceTrimPlan {
        guard settings.thresholdDB.isFinite, (-90...0).contains(settings.thresholdDB),
              settings.minimumPause.isFinite, settings.minimumPause >= 0.05,
              settings.retainedPause.isFinite, settings.retainedPause >= 0,
              settings.retainedPause < settings.minimumPause else { throw SilenceTrimError.invalidSettings }
        let ranges = timeline.sourceRanges(in: selection)
        guard !ranges.isEmpty else { throw ClipEditError.invalidSelection }
        var filters: [String] = []
        for (index, range) in ranges.enumerated() {
            filters.append("[0:a:0]atrim=start=\(range.start.seconds):end=\(range.end.seconds),asetpts=PTS-STARTPTS[a\(index)]")
        }
        let inputs = ranges.indices.map { "[a\($0)]" }.joined()
        filters.append("\(inputs)concat=n=\(ranges.count):v=0:a=1,silencedetect=n=\(settings.thresholdDB)dB:d=\(settings.minimumPause)[out]")
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-i", url.path, "-filter_complex", filters.joined(separator: ";"),
            "-map", "[out]", "-vn", "-f", "null", "-"
        ])
        try Task.checkCancellation()
        return try plan(diagnostics: result.standardError, timeline: timeline, selection: selection,
                        retainedPause: settings.retainedPause, frameRate: frameRate)
    }

    static func plan(diagnostics: String, timeline: ClipEditTimeline, selection: CMTimeRange,
                     retainedPause: Double, frameRate: Double) throws -> SilenceTrimPlan {
        let duration = selection.duration.seconds
        var start: Double?
        var silences: [(Double, Double)] = []
        func value(_ line: String, after marker: String) -> Double? {
            guard let range = line.range(of: marker) else { return nil }
            return Double(line[range.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "|" }).first.map(String.init) ?? "")
        }
        for line in diagnostics.components(separatedBy: .newlines) {
            if let value = value(line, after: "silence_start:"), value.isFinite { start = max(0, value) }
            if let end = value(line, after: "silence_end:"), end.isFinite, let beginning = start {
                silences.append((beginning, min(end, duration))); start = nil
            }
        }
        if let start { silences.append((start, duration)) }
        if silences.contains(where: { $0.0 <= 0.000001 && $0.1 >= duration - 0.000001 }) {
            throw SilenceTrimError.entirelySilent
        }
        var updated = timeline
        var count = 0
        var removed = 0.0
        var removedRanges: [CMTimeRange] = []
        // Delete backwards so earlier edited-time coordinates remain valid.
        for silence in silences.reversed() {
            var beginning = selection.start.seconds + silence.0 + retainedPause / 2
            var end = selection.start.seconds + silence.1 - retainedPause / 2
            if frameRate > 0 {
                beginning = ceil(beginning * frameRate) / frameRate
                end = floor(end * frameRate) / frameRate
            }
            guard end > beginning else { continue }
            let range = CMTimeRange(start: CMTime(seconds: beginning, preferredTimescale: 600_000),
                end: CMTime(seconds: end, preferredTimescale: 600_000))
            try updated.delete(editedRange: range)
            count += 1; removed += range.duration.seconds
            removedRanges.append(range)
        }
        return SilenceTrimPlan(sourceRanges: updated.sourceRanges, removedCount: count, removedSeconds: removed, removedRanges: removedRanges)
    }
}
