import AVFoundation
import Foundation

struct ProxyMediaManager {
    private static func cacheDirectory() throws -> URL {
        let cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("com.marconius.trimato/MediaProxies", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }

    static func proxyURL(for sourceURL: URL) throws -> URL {
        try cacheDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    static func cachedProxyURL(for cacheKey: UUID) throws -> URL {
        try cacheDirectory().appendingPathComponent(cacheKey.uuidString).appendingPathExtension("mp4")
    }

    static func existingCachedProxyURL(for cacheKey: UUID) -> URL? {
        guard let url = try? cachedProxyURL(for: cacheKey),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func arguments(
        sourceURL: URL,
        outputURL: URL,
        useVideoToolbox: Bool = true
    ) -> [String] {
        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
            "-vf", "scale='min(1280,iw)':-2",
            "-fps_mode", "passthrough",
        ]
        if useVideoToolbox {
            result += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-tag:v", "avc1"]
        } else {
            result += ["-c:v", "mpeg4", "-q:v", "5", "-tag:v", "mp4v"]
        }
        result += [
            "-c:a", "aac", "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            outputURL.path
        ]
        return result
    }

    static func createProxy(
        sourceURL: URL,
        duration: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputURL = try proxyURL(for: sourceURL)
        return try await createProxy(
            sourceURL: sourceURL,
            duration: duration,
            outputURL: outputURL,
            progress: progress
        )
    }

    static func createCachedProxy(
        sourceURL: URL,
        duration: Double,
        cacheKey: UUID,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputURL = try cachedProxyURL(for: cacheKey)
        return try await createProxy(
            sourceURL: sourceURL,
            duration: duration,
            outputURL: outputURL,
            progress: progress
        )
    }

    private static func createProxy(
        sourceURL: URL,
        duration: Double,
        outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            do {
                _ = try await FFmpegRunner.run(
                    tool: .ffmpeg,
                    arguments: arguments(sourceURL: sourceURL, outputURL: outputURL),
                    progress: progress,
                    expectedDuration: duration
                )
            } catch let error as FFmpegCommandError where error.isVideoToolboxUnavailable {
                try Task.checkCancellation()
                _ = try await FFmpegRunner.run(
                    tool: .ffmpeg,
                    arguments: arguments(
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        useVideoToolbox: false
                    ),
                    progress: progress,
                    expectedDuration: duration
                )
            }
            try Task.checkCancellation()
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    nonisolated static func removeProxy(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeCachedProxy(for cacheKey: UUID?) {
        guard let cacheKey else { return }
        removeProxy(at: try? cachedProxyURL(for: cacheKey))
    }
}
