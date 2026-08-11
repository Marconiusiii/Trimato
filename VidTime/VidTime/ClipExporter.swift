import AVFoundation
import UniformTypeIdentifiers

enum ClipExportError: LocalizedError, Equatable {
    case unavailable
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This video cannot be exported without converting it."
        case .unsupportedFileType:
            return "The selected output file type is not supported for this video."
        }
    }
}

struct ClipExporter {
    static func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        sourceContentType: UTType,
        to outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ClipExportError.unavailable
        }

        let requestedType = try passthroughFileType(
            for: sourceContentType,
            supportedFileTypes: session.supportedFileTypes
        )

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

    static func passthroughFileType(
        for sourceContentType: UTType,
        supportedFileTypes: [AVFileType]
    ) throws -> AVFileType {
        let sourceFileType = AVFileType(rawValue: sourceContentType.identifier)
        guard supportedFileTypes.contains(sourceFileType) else {
            throw ClipExportError.unsupportedFileType
        }
        return sourceFileType
    }
}
