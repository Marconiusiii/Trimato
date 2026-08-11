import AVFoundation
import Foundation

struct FFmpegClipExporter {
    static func arguments(
        sourceURL: URL,
        timeRange: CMTimeRange,
        outputURL: URL,
        useVideoToolbox: Bool = true
    ) -> [String] {
        arguments(
            sourceURL: sourceURL,
            sourceRanges: [timeRange],
            hasAudio: true,
            outputURL: outputURL,
            useVideoToolbox: useVideoToolbox
        )
    }

    static func arguments(
        sourceURL: URL,
        sourceRanges: [CMTimeRange],
        hasAudio: Bool,
        outputURL: URL,
        useVideoToolbox: Bool = true
    ) -> [String] {
        guard sourceRanges.count != 1 else {
            let timeRange = sourceRanges[0]
            let start = max(CMTimeGetSeconds(timeRange.start), 0)
            let duration = max(CMTimeGetSeconds(timeRange.duration), 0)
            var result = [
                "-hide_banner", "-nostdin", "-y",
                "-i", sourceURL.path,
                "-ss", String(format: "%.6f", start),
                "-t", String(format: "%.6f", duration),
                "-map", "0:v:0"
            ]
            if hasAudio { result += ["-map", "0:a:0?"] }
            result += ["-sn", "-dn"]
            result += encodingArguments(useVideoToolbox: useVideoToolbox, hasAudio: hasAudio)
            result += [
                "-movflags", "+faststart",
                "-progress", "pipe:1", "-nostats",
                outputURL.path
            ]
            return result
        }

        var filters: [String] = []
        var concatInputs = ""
        for (index, range) in sourceRanges.enumerated() {
            let start = max(CMTimeGetSeconds(range.start), 0)
            let duration = max(CMTimeGetSeconds(range.duration), 0)
            filters.append(
                "[0:v:0]trim=start=\(format(start)):duration=\(format(duration))," +
                "setpts=PTS-STARTPTS[v\(index)]"
            )
            concatInputs += "[v\(index)]"
            if hasAudio {
                filters.append(
                    "[0:a:0]atrim=start=\(format(start)):duration=\(format(duration))," +
                    "asetpts=PTS-STARTPTS[a\(index)]"
                )
                concatInputs += "[a\(index)]"
            }
        }
        filters.append(
            "\(concatInputs)concat=n=\(sourceRanges.count):v=1:a=\(hasAudio ? 1 : 0)" +
            (hasAudio ? "[v][a]" : "[v]")
        )

        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[v]"
        ]
        if hasAudio { result += ["-map", "[a]"] }
        result += ["-sn", "-dn"]
        result += encodingArguments(useVideoToolbox: useVideoToolbox, hasAudio: hasAudio)
        result += [
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            outputURL.path
        ]
        return result
    }

    private static func encodingArguments(useVideoToolbox: Bool, hasAudio: Bool) -> [String] {
        var result: [String]
        if useVideoToolbox {
            result = ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
        } else {
            result = ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "mp4v"]
        }
        if hasAudio { result += ["-c:a", "aac"] }
        return result
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.6f", seconds)
    }

    static func export(
        sourceURL: URL,
        timeRange: CMTimeRange,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        try await export(
            sourceURL: sourceURL,
            sourceRanges: [timeRange],
            hasAudio: true,
            to: outputURL,
            progress: progress
        )
    }

    static func export(
        sourceURL: URL,
        sourceRanges: [CMTimeRange],
        hasAudio: Bool,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: outputURL,
            create: true
        )
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        let temporaryURL = replacementDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let duration = sourceRanges.reduce(0) { $0 + max(CMTimeGetSeconds($1.duration), 0) }

        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    sourceRanges: sourceRanges,
                    hasAudio: hasAudio,
                    outputURL: temporaryURL
                ),
                progress: progress,
                expectedDuration: duration
            )
        } catch let error as FFmpegCommandError where error.isVideoToolboxUnavailable {
            try Task.checkCancellation()
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    sourceRanges: sourceRanges,
                    hasAudio: hasAudio,
                    outputURL: temporaryURL,
                    useVideoToolbox: false
                ),
                progress: progress,
                expectedDuration: duration
            )
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}
