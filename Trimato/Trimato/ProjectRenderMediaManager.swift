import Foundation

nonisolated enum ProjectRenderMediaError: LocalizedError {
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            "There is not enough available disk space to prepare the original media for final export."
        }
    }
}

nonisolated enum ProjectRenderMediaManager {
    static func arguments(
        sourceURL: URL,
        outputURL: URL,
        hasVideo: Bool = true,
        hasAudio: Bool
    ) -> [String] {
        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path
        ]
        if hasVideo { result += ["-map", "0:v:0"] }
        if hasAudio { result += ["-map", "0:a:0?"] }
        result += ["-sn", "-dn"]
        if hasVideo {
            result += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]
        } else {
            result += ["-vn"]
        }
        if hasAudio { result += ["-c:a", "pcm_f32le"] }
        result += ["-progress", "pipe:1", "-nostats", outputURL.path]
        return result
    }

    @concurrent
    static func createIntermediate(
        sourceURL: URL,
        duration: Double,
        width: Int?,
        height: Int?,
        hasVideo: Bool = true,
        hasAudio: Bool
    ) async throws -> URL {
        let directory = try TemporaryMediaSession.directory(named: "TrimatoRenderIntermediates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await FFmpegMediaProbe.inspect(url: sourceURL)
        try requireAvailableSpace(
            in: directory,
            duration: duration,
            width: width,
            height: height,
            hasVideo: hasVideo,
            sampleRate: Double(report.audioStream?.sampleRate ?? "") ?? 48_000,
            channels: report.audioStream?.channels ?? 2, frameRate: report.frameRate ?? 30
        )
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    hasVideo: hasVideo,
                    hasAudio: hasAudio
                ),
                expectedDuration: duration
            )
            try Task.checkCancellation()
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func requireAvailableSpace(
        in directory: URL,
        duration: Double,
        width: Int?,
        height: Int?,
        hasVideo: Bool,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        frameRate: Double = 30,
        hasAlpha: Bool = false
    ) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let estimate = try estimatedBytes(duration: duration, width: width, height: height,
            hasVideo: hasVideo, sampleRate: sampleRate, channels: channels, frameRate: frameRate, hasAlpha: hasAlpha)
        let (required, overflow) = MediaCacheManager.minimumAvailableByteCount.addingReportingOverflow(estimate)
        guard !overflow else { throw ProjectRenderMediaError.insufficientDiskSpace }
        guard available >= required else { throw ProjectRenderMediaError.insufficientDiskSpace }
    }
    static func estimatedBytes(duration: Double, width: Int?, height: Int?, hasVideo: Bool,
                               sampleRate: Double = 48_000, channels: Int = 2,
                               frameRate: Double = 30, hasAlpha: Bool = false) throws -> Int64 {
        guard duration.isFinite, duration > 0, sampleRate.isFinite, sampleRate > 0,
              channels > 0, frameRate.isFinite, frameRate > 0,
              !hasVideo || ((width ?? 1920) > 0 && (height ?? 1080) > 0) else {
            throw ProjectRenderMediaError.insufficientDiskSpace
        }
        let audioRate = sampleRate * Double(channels) * 4
        let pixels = Double(width ?? 1920) * Double(height ?? 1080)
        let videoRate = hasVideo ? 30_000_000 * max(pixels / (1920 * 1080), 0.25)
            * max(frameRate / 30, 1) * (hasAlpha ? 2 : 1) : 0
        let estimate = max(duration, 1) * (audioRate + videoRate) * 1.1
        guard estimate.isFinite, estimate < Double(Int64.max) else {
            throw ProjectRenderMediaError.insufficientDiskSpace
        }
        return Int64(estimate.rounded(.up))
    }

}
