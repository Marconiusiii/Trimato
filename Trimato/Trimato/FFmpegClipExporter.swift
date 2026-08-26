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
        format: ExportFormat = .h264MP4,
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
                "-t", String(format: "%.6f", duration)
            ]
            if !format.isAudioOnly { result += ["-map", "0:v:0"] }
            if hasAudio { result += ["-map", "0:a:0?"] }
            result += ["-sn", "-dn"]
            result += encodingArguments(format: format, useVideoToolbox: useVideoToolbox, hasAudio: hasAudio)
            if format.supportsFastStart { result += ["-movflags", "+faststart"] }
            result += ["-progress", "pipe:1", "-nostats", outputURL.path]
            return result
        }

        var filters: [String] = []
        var concatInputs = ""
        for (index, range) in sourceRanges.enumerated() {
            let start = max(CMTimeGetSeconds(range.start), 0)
            let duration = max(CMTimeGetSeconds(range.duration), 0)
            if !format.isAudioOnly {
                filters.append(
                    "[0:v:0]trim=start=\(self.format(start)):duration=\(self.format(duration))," +
                    "setpts=PTS-STARTPTS[v\(index)]"
                )
                concatInputs += "[v\(index)]"
            }
            if hasAudio {
                filters.append(
                    "[0:a:0]atrim=start=\(self.format(start)):duration=\(self.format(duration))," +
                    "asetpts=PTS-STARTPTS[a\(index)]"
                )
                concatInputs += "[a\(index)]"
            }
        }
        let hasVideo = !format.isAudioOnly
        filters.append("\(concatInputs)concat=n=\(sourceRanges.count):v=\(hasVideo ? 1 : 0):a=\(hasAudio ? 1 : 0)" +
            (hasVideo ? "[v]" : "") + (hasAudio ? "[a]" : ""))

        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-filter_complex", filters.joined(separator: ";")
        ]
        if hasVideo { result += ["-map", "[v]"] }
        if hasAudio { result += ["-map", "[a]"] }
        result += ["-sn", "-dn"]
        result += encodingArguments(format: format, useVideoToolbox: useVideoToolbox, hasAudio: hasAudio)
        if format.supportsFastStart { result += ["-movflags", "+faststart"] }
        result += ["-progress", "pipe:1", "-nostats", outputURL.path]
        return result
    }

    private static func encodingArguments(
        format: ExportFormat,
        useVideoToolbox: Bool,
        hasAudio: Bool
    ) -> [String] {
        switch format {
        case .h264MP4, .h264QuickTime:
            var result = useVideoToolbox
                ? ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
                : ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "mp4v"]
            if hasAudio { result += ["-c:a", "aac"] }
            return result
        case .hevcMP4, .hevcMovie:
            var result = ["-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-tag:v", "hvc1"]
            if hasAudio { result += ["-c:a", "aac"] }
            return result
        case .proRes422LT, .proRes422, .proRes422HQ:
            let profile = format == .proRes422LT ? "1" : format == .proRes422 ? "2" : "3"
            var result = ["-c:v", "prores_ks", "-profile:v", profile, "-pix_fmt", "yuv422p10le"]
            if hasAudio { result += ["-c:a", "pcm_s16le"] }
            return result
        case .m4a:
            return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .m4aAppleLossless:
            return ["-vn", "-c:a", "alac"]
        case .flac:
            return ["-vn", "-c:a", "flac"]
        case .wav:
            return ["-vn", "-c:a", "pcm_s16le"]
        case .wav24:
            return ["-vn", "-c:a", "pcm_s24le"]
        case .original:
            return []
        }
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
        format: ExportFormat = .h264MP4,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        if format.isAudioOnly && !hasAudio {
            throw ProjectExporter.ExportError.noAudio
        }
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
            .appendingPathExtension(format.fileExtension)
        let duration = sourceRanges.reduce(0) { $0 + max(CMTimeGetSeconds($1.duration), 0) }

        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    sourceRanges: sourceRanges,
                    hasAudio: hasAudio,
                    outputURL: temporaryURL,
                    format: format
                ),
                progress: progress,
                expectedDuration: duration
            )
        } catch let error as FFmpegCommandError
            where error.isVideoToolboxUnavailable && (format == .h264MP4 || format == .h264QuickTime) {
            try Task.checkCancellation()
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    sourceRanges: sourceRanges,
                    hasAudio: hasAudio,
                    outputURL: temporaryURL,
                    format: format,
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
