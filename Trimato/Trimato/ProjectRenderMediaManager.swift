import Foundation

enum ProjectRenderMediaError: LocalizedError {
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            "There is not enough available disk space to prepare the original media for final export."
        }
    }
}

enum ProjectRenderMediaManager {
    static func arguments(
        sourceURL: URL,
        outputURL: URL,
        hasAudio: Bool
    ) -> [String] {
        var result = [
            "-hide_banner", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0"
        ]
        if hasAudio { result += ["-map", "0:a:0?"] }
        result += [
            "-sn", "-dn",
            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"
        ]
        if hasAudio { result += ["-c:a", "pcm_s16le"] }
        result += ["-progress", "pipe:1", "-nostats", outputURL.path]
        return result
    }

    static func createIntermediate(
        sourceURL: URL,
        duration: Double,
        width: Int?,
        height: Int?,
        hasAudio: Bool
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoRenderIntermediates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeAbandonedIntermediates(in: directory)
        try requireAvailableSpace(
            in: directory,
            duration: duration,
            width: width,
            height: height
        )
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments(sourceURL: sourceURL, outputURL: outputURL, hasAudio: hasAudio),
                expectedDuration: duration
            )
            try Task.checkCancellation()
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func removeAbandonedIntermediates(in directory: URL) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "mov" {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private static func requireAvailableSpace(
        in directory: URL,
        duration: Double,
        width: Int?,
        height: Int?
    ) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let pixels = Double(max((width ?? 1_920) * (height ?? 1_080), 1))
        let resolutionScale = max(pixels / Double(1_920 * 1_080), 0.25)
        let estimatedIntermediate = Int64(max(duration, 1) * 30_000_000 * resolutionScale)
        let required = MediaCacheManager.minimumAvailableByteCount + estimatedIntermediate
        guard available >= required else { throw ProjectRenderMediaError.insufficientDiskSpace }
    }
}
