import AVFoundation
import CryptoKit
import Foundation

// Definitions are saved in the project; these files are disposable playback media.
enum GeneratorRenderer {
    static func cacheURL(for definition: GeneratorDefinition) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data: try encoder.encode(definition)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trimato/Generators-v1", isDirectory: true)
            .appendingPathComponent(hash).appendingPathExtension(definition.kind == .silence ? "wav" : "mov")
    }

    static func ensure(_ definition: GeneratorDefinition, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        try definition.validate()
        let destination = try cacheURL(for: definition)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectRenderMediaManager.requireAvailableSpace(in: destination.deletingLastPathComponent(), duration: definition.duration.seconds, width: definition.width, height: definition.height, hasVideo: definition.kind != .silence)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = ["-hide_banner", "-y", "-f", "lavfi", "-i", definition.sourceFilter, "-t", String(definition.duration.seconds)]
        if definition.kind == .silence {
            arguments += ["-c:a", "pcm_s16le"]
        } else {
            arguments += ["-an", "-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le"]
        }
        arguments += ["-progress", "pipe:1", "-nostats", temporary.path]
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, progress: progress, expectedDuration: definition.duration.seconds)
        try Task.checkCancellation()
        let asset = AVURLAsset(url: temporary)
        guard try await asset.load(.isPlayable) else { throw MediaSourceError.unreadable("The generator could not be prepared for playback.") }
        // Concurrent windows may have finished the same definition while this render was waiting.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
