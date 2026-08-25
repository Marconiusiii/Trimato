import AVFoundation
import Foundation

enum ProjectExporter {
    enum ExportError: LocalizedError {
        case incompatibleFormat(String)
        case noAudio
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .incompatibleFormat(let format):
                "This project cannot be exported as \(format)."
            case .noAudio:
                "The selected export does not contain audio."
            case .encodingFailed(let detail):
                "Trimato could not encode the project. \(detail)"
            }
        }
    }

    enum ExportRangeError: LocalizedError, Equatable {
        case invalidRange

        var errorDescription: String? {
            "Set both In and Out, with In earlier than Out and within the project duration, or clear both markers."
        }
    }

    static func export(
        project: TrimatoProject,
        mediaURLs: [UUID: URL],
        timeRange: ProjectTimeRange? = nil,
        format: ExportFormat = .h264MP4,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let result = try await ProjectCompositionBuilder.build(
            project: project,
            mediaURLs: mediaURLs,
            purpose: .finalExport
        )
        defer {
            for url in result.temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        }
        let validatedRange = try validatedTimeRange(timeRange, projectDuration: project.duration)

        if format == .wav {
            try await AudioOnlyExporter.exportWAV(
                asset: result.composition,
                audioMix: result.audioMix,
                timeRange: validatedRange?.cmTimeRange,
                to: outputURL,
                progress: progress
            )
            return
        }

        guard let preset = format.exportPreset, let fileType = format.fileType,
              let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
            throw ExportError.incompatibleFormat(format.title)
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw ExportError.incompatibleFormat(format.title)
        }
        if !format.isAudioOnly {
            session.videoComposition = result.videoComposition
        }
        session.audioMix = result.audioMix
        session.shouldOptimizeForNetworkUse = format == .h264MP4
        if let validatedRange {
            session.timeRange = validatedRange.cmTimeRange
        }

        let temporaryDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: outputURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryURL = temporaryDirectory
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
            throw ExportError.encodingFailed(Self.failureDetail(for: error))
        }
        try Task.checkCancellation()
        progress(1)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    nonisolated static func failureDetail(for error: Error) -> String {
        let nsError = error as NSError
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            return reason
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if let reason = underlying.localizedFailureReason, !reason.isEmpty {
                return reason
            }
            if underlying.localizedDescription != "The operation could not be completed." {
                return underlying.localizedDescription
            }
        }
        if nsError.localizedDescription != "The operation could not be completed." {
            return nsError.localizedDescription
        }
        return "The media encoder reported error \(nsError.code)."
    }

    nonisolated static func validatedTimeRange(
        _ timeRange: ProjectTimeRange?,
        projectDuration: ProjectTime
    ) throws -> ProjectTimeRange? {
        guard let timeRange else { return nil }
        guard timeRange.isValid, timeRange.end <= projectDuration else {
            throw ExportRangeError.invalidRange
        }
        return timeRange
    }
}

enum AudioOnlyExporter {
    static func exportWAV(
        asset: AVAsset,
        audioMix: AVAudioMix?,
        timeRange: CMTimeRange?,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProjectExporter.ExportError.noAudio }

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
            .appendingPathExtension("wav")

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        readerOutput.audioMix = audioMix
        guard reader.canAdd(readerOutput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(ExportFormat.wav.title)
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        guard writer.canAdd(writerInput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(ExportFormat.wav.title)
        }
        writer.add(writerInput)

        guard writer.startWriting(), reader.startReading() else {
            throw ProjectExporter.ExportError.encodingFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The audio encoder could not start."
            )
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let exportDuration: CMTime
        if let timeRange {
            exportDuration = timeRange.duration
        } else {
            exportDuration = try await asset.load(.duration)
        }
        let duration = max(CMTimeGetSeconds(exportDuration), 0.001)
        while reader.status == .reading {
            try Task.checkCancellation()
            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            guard writerInput.append(sample) else {
                throw ProjectExporter.ExportError.encodingFailed(
                    writer.error?.localizedDescription ?? "The audio encoder stopped writing."
                )
            }
            let elapsed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                - CMTimeGetSeconds(timeRange?.start ?? .zero)
            progress(min(max(elapsed / duration, 0), 1))
        }
        try Task.checkCancellation()
        if reader.status == .failed {
            throw ProjectExporter.ExportError.encodingFailed(
                reader.error?.localizedDescription ?? "The project audio could not be read."
            )
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProjectExporter.ExportError.encodingFailed(
                writer.error?.localizedDescription ?? "The audio file could not be completed."
            )
        }
        progress(1)

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}
