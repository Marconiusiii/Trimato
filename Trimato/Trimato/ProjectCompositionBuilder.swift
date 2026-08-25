import AVFoundation
import Foundation

struct ProjectCompositionResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let temporaryMediaURLs: [URL]
}

nonisolated enum ProjectCompositionPurpose: Equatable, Sendable {
    case preview
    case finalExport
}

nonisolated enum ProjectCompositionMediaSelection: Equatable, Sendable {
    case original
    case playbackProxy
}

enum ProjectCompositionError: LocalizedError {
    case emptyTimeline
    case missingMedia(String)
    case missingVideo(String)
    case cannotCreateTrack
    case unresolvedFormat

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "Add at least one clip before previewing or exporting."
        case .missingMedia(let name): "The media file for \(name) is offline."
        case .missingVideo(let name): "\(name) does not contain a usable video track."
        case .cannotCreateTrack: "Trimato could not create the project media tracks."
        case .unresolvedFormat: "Add a clip or choose custom project dimensions before previewing."
        }
    }
}

enum ProjectCompositionBuilder {
    nonisolated static func mediaSelection(
        for record: MediaAssetRecord,
        purpose: ProjectCompositionPurpose
    ) -> ProjectCompositionMediaSelection {
        purpose == .preview && record.playbackMode == .cachedProxy
            ? .playbackProxy
            : .original
    }

    static func build(
        project: TrimatoProject,
        mediaURLs: [UUID: URL],
        purpose: ProjectCompositionPurpose = .preview
    ) async throws -> ProjectCompositionResult {
        guard !project.primaryTimeline.isEmpty else { throw ProjectCompositionError.emptyTimeline }
        guard let width = project.format.width, let height = project.format.height,
              width > 0, height > 0 else {
            throw ProjectCompositionError.unresolvedFormat
        }

        let composition = AVMutableComposition()
        guard let primaryVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProjectCompositionError.cannotCreateTrack
        }
        var primaryAudio: AVMutableCompositionTrack?
        var cutawayVideo: AVMutableCompositionTrack?
        var cutawayAudio: AVMutableCompositionTrack?

        let renderSize = CGSize(width: width, height: height)
        var assets: [UUID: AVURLAsset] = [:]
        var temporaryMediaURLs: [URL] = []
        var shouldPreserveTemporaryMedia = false
        defer {
            if !shouldPreserveTemporaryMedia {
                for url in temporaryMediaURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        var primaryTransforms: [(ProjectTimeRange, CGAffineTransform)] = []
        var cursor = ProjectTime.zero

        for clip in project.primaryTimeline {
            let assetRecord = try requireAsset(clip.assetID, in: project)
            let asset = try await preparedAsset(
                assetRecord,
                urls: mediaURLs,
                purpose: purpose,
                cache: &assets,
                temporaryMediaURLs: &temporaryMediaURLs
            )
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProjectCompositionError.missingVideo(assetRecord.name)
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let transform = try await displayTransform(for: video, renderSize: renderSize)
            for segment in clip.segments {
                let range = segment.sourceRange.cmTimeRange
                try primaryVideo.insertTimeRange(range, of: video, at: cursor.cmTime)
                if let audio {
                    let available = try await audio.load(.timeRange)
                    let portion = CMTimeRangeGetIntersection(range, otherRange: available)
                    if portion.isValid, !portion.isEmpty {
                        if primaryAudio == nil {
                            primaryAudio = composition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                            )
                        }
                        guard let primaryAudio else { throw ProjectCompositionError.cannotCreateTrack }
                        let sourceOffset = CMTimeSubtract(portion.start, range.start)
                        try primaryAudio.insertTimeRange(
                            portion,
                            of: audio,
                            at: CMTimeAdd(cursor.cmTime, sourceOffset)
                        )
                    }
                }
                primaryTransforms.append((
                    ProjectTimeRange(start: cursor, duration: segment.duration),
                    transform
                ))
                cursor = cursor + segment.duration
            }
        }

        var cutawayTransforms: [(ProjectTimeRange, CGAffineTransform)] = []
        for cutaway in project.cutaways {
            let assetRecord = try requireAsset(cutaway.assetID, in: project)
            let asset = try await preparedAsset(
                assetRecord,
                urls: mediaURLs,
                purpose: purpose,
                cache: &assets,
                temporaryMediaURLs: &temporaryMediaURLs
            )
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProjectCompositionError.missingVideo(assetRecord.name)
            }
            if cutawayVideo == nil {
                cutawayVideo = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            }
            guard let cutawayVideo else { throw ProjectCompositionError.cannotCreateTrack }
            let audio = cutaway.audioMode == .sourceAudio
                ? try await asset.loadTracks(withMediaType: .audio).first
                : nil
            let transform = try await displayTransform(for: video, renderSize: renderSize)
            var cutawayCursor = cutaway.start
            for segment in cutaway.segments {
                let range = segment.sourceRange.cmTimeRange
                try cutawayVideo.insertTimeRange(range, of: video, at: cutawayCursor.cmTime)
                if let audio {
                    let available = try await audio.load(.timeRange)
                    let portion = CMTimeRangeGetIntersection(range, otherRange: available)
                    if portion.isValid, !portion.isEmpty {
                        if cutawayAudio == nil {
                            cutawayAudio = composition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                            )
                        }
                        guard let cutawayAudio else { throw ProjectCompositionError.cannotCreateTrack }
                        let sourceOffset = CMTimeSubtract(portion.start, range.start)
                        try cutawayAudio.insertTimeRange(
                            portion,
                            of: audio,
                            at: CMTimeAdd(cutawayCursor.cmTime, sourceOffset)
                        )
                    }
                }
                cutawayTransforms.append((
                    ProjectTimeRange(start: cutawayCursor, duration: segment.duration),
                    transform
                ))
                cutawayCursor = cutawayCursor + segment.duration
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            seconds: 1 / max(project.format.frameRate ?? 30, 1),
            preferredTimescale: ProjectTime.defaultTimescale
        )
        videoComposition.instructions = makeVideoInstructions(
            duration: project.duration,
            primaryTrack: primaryVideo,
            primaryTransforms: primaryTransforms,
            cutawayTrack: cutawayVideo,
            cutawayTransforms: cutawayTransforms,
            cutaways: project.cutaways
        )

        let sourceAudioCutaways = project.cutaways.filter { $0.audioMode == .sourceAudio }
        let audioMix: AVMutableAudioMix?
        if sourceAudioCutaways.isEmpty || (primaryAudio == nil && cutawayAudio == nil) {
            audioMix = nil
        } else {
            var parameters: [AVMutableAudioMixInputParameters] = []
            if let primaryAudio {
                let primaryParameters = AVMutableAudioMixInputParameters(track: primaryAudio)
                primaryParameters.setVolume(1, at: .zero)
                for cutaway in sourceAudioCutaways {
                    primaryParameters.setVolume(0, at: cutaway.start.cmTime)
                    primaryParameters.setVolume(1, at: cutaway.end.cmTime)
                }
                parameters.append(primaryParameters)
            }
            if let cutawayAudio {
                let cutawayParameters = AVMutableAudioMixInputParameters(track: cutawayAudio)
                cutawayParameters.setVolume(0, at: .zero)
                for cutaway in sourceAudioCutaways {
                    cutawayParameters.setVolume(1, at: cutaway.start.cmTime)
                    cutawayParameters.setVolume(0, at: cutaway.end.cmTime)
                }
                parameters.append(cutawayParameters)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }

        let result = ProjectCompositionResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            temporaryMediaURLs: temporaryMediaURLs
        )
        shouldPreserveTemporaryMedia = true
        return result
    }

    private static func requireAsset(_ id: UUID, in project: TrimatoProject) throws -> MediaAssetRecord {
        guard let asset = project.asset(id: id) else {
            throw ProjectCompositionError.missingMedia("an unknown clip")
        }
        return asset
    }

    private static func preparedAsset(
        _ record: MediaAssetRecord,
        urls: [UUID: URL],
        purpose: ProjectCompositionPurpose,
        cache: inout [UUID: AVURLAsset],
        temporaryMediaURLs: inout [URL]
    ) async throws -> AVURLAsset {
        if let cached = cache[record.id] { return cached }
        guard let url = urls[record.id] else { throw ProjectCompositionError.missingMedia(record.name) }
        if mediaSelection(for: record, purpose: purpose) == .playbackProxy,
           let cacheKey = record.proxyCacheKey {
            let fingerprint = try MediaCacheManager.sourceFingerprint(for: url)
            let proxyURL = try await MediaCacheManager.shared.ensureProxy(
                sourceURL: url,
                duration: record.duration.seconds,
                cacheKey: cacheKey,
                fingerprint: fingerprint
            )
            let asset = AVURLAsset(url: proxyURL)
            cache[record.id] = asset
            return asset
        }
        var asset = AVURLAsset(url: url)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if purpose == .finalExport,
           record.playbackMode == .cachedProxy || !isPlayable || videoTracks.isEmpty {
            let intermediateURL = try await ProjectRenderMediaManager.createIntermediate(
                sourceURL: url,
                duration: record.duration.seconds,
                width: record.naturalWidth,
                height: record.naturalHeight,
                hasAudio: record.hasAudio
            )
            temporaryMediaURLs.append(intermediateURL)
            asset = AVURLAsset(url: intermediateURL)
        } else if purpose == .preview, !isPlayable || videoTracks.isEmpty {
            let report = try await FFmpegMediaProbe.inspect(url: url)
            try FFmpegMediaProbe.validateForMP4Conversion(report)
            let proxyURL = try await ProxyMediaManager.createProxy(
                sourceURL: url,
                duration: report.duration,
                progress: { _ in }
            )
            temporaryMediaURLs.append(proxyURL)
            asset = AVURLAsset(url: proxyURL)
        }
        cache[record.id] = asset
        return asset
    }

    private static func displayTransform(
        for track: AVAssetTrack,
        renderSize: CGSize
    ) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let orientedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let scale = min(
            renderSize.width / max(orientedSize.width, 1),
            renderSize.height / max(orientedSize.height, 1)
        )
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let offsetX = (renderSize.width - scaledSize.width) / 2
        let offsetY = (renderSize.height - scaledSize.height) / 2
        return preferred
            .translatedBy(x: -transformed.minX, y: -transformed.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: offsetX / max(scale, 0.000_1), y: offsetY / max(scale, 0.000_1))
    }

    private static func makeVideoInstructions(
        duration: ProjectTime,
        primaryTrack: AVCompositionTrack,
        primaryTransforms: [(ProjectTimeRange, CGAffineTransform)],
        cutawayTrack: AVCompositionTrack?,
        cutawayTransforms: [(ProjectTimeRange, CGAffineTransform)],
        cutaways: [TimelineCutaway]
    ) -> [AVVideoCompositionInstructionProtocol] {
        var boundaries = [ProjectTime.zero, duration]
        boundaries.append(contentsOf: primaryTransforms.flatMap { [$0.0.start, $0.0.end] })
        boundaries.append(contentsOf: cutaways.flatMap { [$0.start, $0.end] })
        boundaries = Array(Set(boundaries)).sorted()

        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = ProjectTimeRange(start: start, duration: end - start).cmTimeRange

            let primaryLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: primaryTrack)
            if let transform = primaryTransforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 {
                primaryLayer.setTransform(transform, at: start.cmTime)
            }
            if let cutawayTrack,
               let cutawayTransform = cutawayTransforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 {
                let cutawayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cutawayTrack)
                cutawayLayer.setTransform(cutawayTransform, at: start.cmTime)
                instruction.layerInstructions = [cutawayLayer, primaryLayer]
            } else {
                instruction.layerInstructions = [primaryLayer]
            }
            return instruction
        }
    }
}
