import AVFoundation
import Foundation

struct FFmpegClipExporter {
    static func arguments(
        sourceURL: URL,
        timeRange: CMTimeRange,
        outputURL: URL,
        useVideoToolbox: Bool = true
    ) -> [String] {
        let start = max(CMTimeGetSeconds(timeRange.start), 0)
        let duration = max(CMTimeGetSeconds(timeRange.duration), 0)
        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-ss", String(format: "%.6f", start),
            "-t", String(format: "%.6f", duration),
            "-map", "0:v:0", "-map", "0:a:0?",
            "-sn", "-dn"
        ]
        if useVideoToolbox {
            result += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
        } else {
            result += ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "mp4v"]
        }
        result += [
            "-c:a", "aac",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            outputURL.path
        ]
        return result
    }

    static func export(
        sourceURL: URL,
        timeRange: CMTimeRange,
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
        let duration = CMTimeGetSeconds(timeRange.duration)

        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(sourceURL: sourceURL, timeRange: timeRange, outputURL: temporaryURL),
                progress: progress,
                expectedDuration: duration
            )
        } catch let error as FFmpegCommandError where error.isVideoToolboxUnavailable {
            try Task.checkCancellation()
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    timeRange: timeRange,
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
