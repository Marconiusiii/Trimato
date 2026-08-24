import AVFoundation
import Foundation

enum ProjectExporter {
    static func export(
        project: TrimatoProject,
        mediaURLs: [UUID: URL],
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: mediaURLs)
        defer {
            for url in result.temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        }
        guard let session = AVAssetExportSession(
            asset: result.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ClipExportError.unavailable
        }
        session.videoComposition = result.videoComposition
        session.audioMix = result.audioMix
        session.shouldOptimizeForNetworkUse = true

        let temporaryDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: outputURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }
        try await session.export(to: temporaryURL, as: .mp4)
        try Task.checkCancellation()
        progress(1)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}
