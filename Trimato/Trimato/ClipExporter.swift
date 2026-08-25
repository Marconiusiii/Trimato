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
    static func canPassthrough(asset: AVAsset, sourceContentType: UTType) -> Bool {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else { return false }
        return (try? passthroughFileType(
            for: sourceContentType,
            supportedFileTypes: session.supportedFileTypes
        )) != nil
    }

    static func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        sourceContentType: UTType,
        to outputURL: URL
    ) async throws {
        try await export(
            asset: asset,
            sourceRanges: [timeRange],
            sourceContentType: sourceContentType,
            to: outputURL
        )
    }

    static func export(
        asset: AVAsset,
        sourceRanges: [CMTimeRange],
        sourceContentType: UTType,
        to outputURL: URL
    ) async throws {
        guard !sourceRanges.isEmpty else { throw ClipExportError.unavailable }
        let exportAsset: AVAsset
        if sourceRanges.count == 1, let range = sourceRanges.first {
            exportAsset = asset
            return try await exportSingleRange(
                asset: exportAsset,
                timeRange: range,
                sourceContentType: sourceContentType,
                to: outputURL
            )
        } else {
            exportAsset = try await EditedCompositionBuilder.build(
                asset: asset,
                sourceRanges: sourceRanges
            )
        }
        let composedDuration = sourceRanges.reduce(.zero) { CMTimeAdd($0, $1.duration) }
        try await exportSingleRange(
            asset: exportAsset,
            timeRange: CMTimeRange(start: .zero, duration: composedDuration),
            sourceContentType: sourceContentType,
            to: outputURL
        )
    }

    static func export(
        asset: AVAsset,
        sourceRanges: [CMTimeRange],
        sourceContentType: UTType?,
        format: ExportFormat,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard !sourceRanges.isEmpty else { throw ClipExportError.unavailable }
        if format == .original {
            guard let sourceContentType else { throw ClipExportError.unsupportedFileType }
            try await export(
                asset: asset,
                sourceRanges: sourceRanges,
                sourceContentType: sourceContentType,
                to: outputURL
            )
            progress(1)
            return
        }

        let composition = try await EditedCompositionBuilder.build(
            asset: asset,
            sourceRanges: sourceRanges
        )
        if format == .wav {
            try await AudioOnlyExporter.exportWAV(
                asset: composition,
                audioMix: nil,
                timeRange: nil,
                to: outputURL,
                progress: progress
            )
            return
        }

        guard let preset = format.exportPreset, let fileType = format.fileType,
              let session = AVAssetExportSession(asset: composition, presetName: preset),
              session.supportedFileTypes.contains(fileType) else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        session.shouldOptimizeForNetworkUse = format == .h264MP4

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

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }
        do {
            try await session.export(to: temporaryURL, as: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProjectExporter.ExportError.encodingFailed(ProjectExporter.failureDetail(for: error))
        }
        try Task.checkCancellation()
        progress(1)

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    private static func exportSingleRange(
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
