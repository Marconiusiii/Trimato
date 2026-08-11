import AVFoundation

enum ClipExportError: LocalizedError {
    case unavailable
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This video cannot be exported with the selected quality preset."
        case .unsupportedFileType:
            return "The selected output file type is not supported for this video."
        }
    }
}

struct ClipExporter {
    static func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        to outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ClipExportError.unavailable
        }

        let requestedType: AVFileType = outputURL.pathExtension.lowercased() == "mp4"
            ? .mp4
            : .mov
        guard session.supportedFileTypes.contains(requestedType) else {
            throw ClipExportError.unsupportedFileType
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
            .appendingPathExtension(outputURL.pathExtension)

        session.timeRange = timeRange
        try await session.export(to: temporaryURL, as: requestedType)

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}
