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
                "Trimato cannot create this export as \(format)."
            case .noAudio:
                "The selected export does not contain audio."
            case .encodingFailed(let detail):
                "Trimato could not create the selected file. \(detail)"
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

        if format.isAudioOnly {
            try await AudioOnlyExporter.export(
                asset: result.composition,
                audioMix: result.audioMix,
                timeRange: validatedRange?.cmTimeRange,
                format: format,
                to: outputURL,
                progress: progress
            )
            return
        }

        guard project.hasTimelineVideo, result.videoComposition != nil else {
            throw ExportError.incompatibleFormat(format.title)
        }

        if format.requiresCustomVideoWriter {
            try await CustomMovieExporter.export(
                asset: result.composition,
                videoComposition: result.videoComposition,
                audioMix: result.audioMix,
                timeRange: validatedRange?.cmTimeRange,
                format: format,
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
        if let reason = nsError.localizedFailureReason, isUsefulFailureDetail(reason) {
            return reason
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if let reason = underlying.localizedFailureReason, isUsefulFailureDetail(reason) {
                return reason
            }
            if isUsefulFailureDetail(underlying.localizedDescription) {
                return underlying.localizedDescription
            }
        }
        if isUsefulFailureDetail(nsError.localizedDescription) {
            return nsError.localizedDescription
        }
        return "The media encoder stopped before it could finish the file."
    }

    nonisolated static func userFacingMessage(for error: Error) -> String {
        if error is ExportError || error is ClipExportError {
            return error.localizedDescription
        }
        let detail: String
        if error is FFmpegCommandError {
            detail = "The media encoder stopped before it could finish the file."
        } else {
            detail = failureDetail(for: error)
        }
        return ExportError.encodingFailed(detail).localizedDescription
    }

    private nonisolated static func isUsefulFailureDetail(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return !normalized.contains("operation could not be completed")
            && !normalized.contains("osstatus error")
            && !normalized.contains("error code")
            && !normalized.contains("code=")
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

enum CustomMovieExporter {
    static func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        timeRange: CMTimeRange?,
        format: ExportFormat,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let videoCodec: AVVideoCodecType
        switch format {
        case .proRes422LT: videoCodec = .proRes422LT
        case .proRes422HQ: videoCodec = .proRes422HQ
        default: throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let firstVideoTrack = videoTracks.first else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await firstVideoTrack.load(.naturalSize)
        let preferredTransform = try await firstVideoTrack.load(.preferredTransform)
        let renderSize = videoComposition?.renderSize ?? naturalSize

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

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        videoOutput.videoComposition = videoComposition
        guard reader.canAdd(videoOutput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        reader.add(videoOutput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audioOutput: AVAssetReaderAudioMixOutput?
        if audioTracks.isEmpty {
            audioOutput = nil
        } else {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: audioSettings)
            output.audioMix = audioMix
            guard reader.canAdd(output) else {
                throw ProjectExporter.ExportError.incompatibleFormat(format.title)
            }
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: max(Int(renderSize.width.rounded()), 1),
            AVVideoHeightKey: max(Int(renderSize.height.rounded()), 1),
        ])
        if videoComposition == nil { videoInput.transform = preferredTransform }
        guard writer.canAdd(videoInput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard writer.canAdd(input) else {
                throw ProjectExporter.ExportError.incompatibleFormat(format.title)
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting(), reader.startReading() else {
            let underlying = writer.error ?? reader.error
            throw ProjectExporter.ExportError.encodingFailed(
                underlying.map(ProjectExporter.failureDetail(for:))
                    ?? "The movie encoder could not start."
            )
        }
        let sessionStart = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sessionStart)
        let exportDuration: CMTime
        if let timeRange {
            exportDuration = timeRange.duration
        } else {
            exportDuration = try await asset.load(.duration)
        }
        let duration = max(CMTimeGetSeconds(exportDuration), 0.001)
        var videoFinished = false
        var audioFinished = audioOutput == nil

        while !videoFinished || !audioFinished {
            try Task.checkCancellation()
            var appendedSample = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    guard videoInput.append(sample) else {
                        throw ProjectExporter.ExportError.encodingFailed(
                            writer.error.map(ProjectExporter.failureDetail(for:))
                                ?? "The movie encoder stopped writing video."
                        )
                    }
                    let elapsed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        - CMTimeGetSeconds(sessionStart)
                    progress(min(max(elapsed / duration, 0), 1))
                    appendedSample = true
                } else {
                    videoInput.markAsFinished()
                    videoFinished = true
                }
            }
            if !audioFinished, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        throw ProjectExporter.ExportError.encodingFailed(
                            writer.error.map(ProjectExporter.failureDetail(for:))
                                ?? "The movie encoder stopped writing audio."
                        )
                    }
                    appendedSample = true
                } else {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
            }
            if !appendedSample && (!videoFinished || !audioFinished) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        if reader.status == .failed {
            throw ProjectExporter.ExportError.encodingFailed(
                reader.error.map(ProjectExporter.failureDetail(for:))
                    ?? "The project media could not be read."
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProjectExporter.ExportError.encodingFailed(
                writer.error.map(ProjectExporter.failureDetail(for:))
                    ?? "The movie file could not be completed."
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

enum AudioOnlyExporter {
    static func export(
        asset: AVAsset,
        audioMix: AVAudioMix?,
        timeRange: CMTimeRange?,
        format: ExportFormat,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard format.isAudioOnly else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        if format == .flac {
            try await exportFLAC(
                asset: asset,
                audioMix: audioMix,
                timeRange: timeRange,
                to: outputURL,
                progress: progress
            )
            return
        }
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
            .appendingPathExtension(format.fileExtension)

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let pcmBitDepth = format == .wav ? 16 : 24
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: pcmBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        readerOutput.audioMix = audioMix
        guard reader.canAdd(readerOutput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        reader.add(readerOutput)

        let writerFileType: AVFileType
        let writerSettings: [String: Any]
        switch format {
        case .wav:
            writerFileType = .wav
            writerSettings = pcmSettings
        case .wav24:
            writerFileType = .wav
            writerSettings = pcmSettings
        case .m4a:
            writerFileType = .m4a
            writerSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
        case .m4aAppleLossless:
            writerFileType = .m4a
            writerSettings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 24,
            ]
        case .flac:
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        default:
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: writerFileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        guard writer.canAdd(writerInput) else {
            throw ProjectExporter.ExportError.incompatibleFormat(format.title)
        }
        writer.add(writerInput)

        guard writer.startWriting(), reader.startReading() else {
            let underlyingError = writer.error ?? reader.error
            throw ProjectExporter.ExportError.encodingFailed(
                underlyingError.map(ProjectExporter.failureDetail(for:))
                    ?? "The audio encoder could not start."
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
                    writer.error.map(ProjectExporter.failureDetail(for:))
                        ?? "The audio encoder stopped writing."
                )
            }
            let elapsed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                - CMTimeGetSeconds(timeRange?.start ?? .zero)
            progress(min(max(elapsed / duration, 0), 1))
        }
        try Task.checkCancellation()
        if reader.status == .failed {
            throw ProjectExporter.ExportError.encodingFailed(
                reader.error.map(ProjectExporter.failureDetail(for:))
                    ?? "The audio could not be read."
            )
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProjectExporter.ExportError.encodingFailed(
                writer.error.map(ProjectExporter.failureDetail(for:))
                    ?? "The audio file could not be completed."
            )
        }
        progress(1)

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    private static func exportFLAC(
        asset: AVAsset,
        audioMix: AVAudioMix?,
        timeRange: CMTimeRange?,
        to outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let temporaryWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trimato-FLAC-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryWAV) }

        try await export(
            asset: asset,
            audioMix: audioMix,
            timeRange: timeRange,
            format: .wav24,
            to: temporaryWAV,
            progress: { progress($0 * 0.7) }
        )
        let renderedAsset = AVURLAsset(url: temporaryWAV)
        let renderedDuration = try await renderedAsset.load(.duration)
        try await FFmpegClipExporter.export(
            sourceURL: temporaryWAV,
            sourceRanges: [CMTimeRange(start: .zero, duration: renderedDuration)],
            hasAudio: true,
            format: .flac,
            to: outputURL,
            progress: { progress(0.7 + ($0 * 0.3)) }
        )
    }
}
