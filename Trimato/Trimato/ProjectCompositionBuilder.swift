import AVFoundation
import Foundation

struct ProjectCompositionResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
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

struct ProjectTransitionRenderError: LocalizedError {
    let transitionID: UUID
    let transitionName: String
    let diagnostics: String?

    var errorDescription: String? {
        var message = "Trimato could not prepare the \(transitionName) transition. Remove the transition to restore project playback."
        if let diagnostics, !diagnostics.isEmpty {
            message += " \(diagnostics)"
        }
        return message
    }

    static func diagnosticSummary(for error: Error) -> String? {
        guard let commandError = error as? FFmpegCommandError else { return nil }
        let ignored = ["Conversion failed!", "Unknown error"]
        return commandError.diagnostics
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { line in
                !line.isEmpty && !ignored.contains(line) && !line.hasPrefix("frame=")
            }
    }
}

@MainActor
private final class ProjectCompositionProgressReporter {
    private let jobCount: Int
    private let progress: @MainActor @Sendable (Double) -> Void
    private var completedJobs = 0
    private var lastProgress = 0.0

    init(jobCount: Int, progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.jobCount = max(jobCount, 1)
        self.progress = progress
        progress(0)
    }

    func beginJob() -> @MainActor @Sendable (Double) -> Void {
        let completedAtStart = completedJobs
        return { [weak self] value in
            guard let self else { return }
            let bounded = min(max(value, 0), 1)
            let aggregate = ((Double(completedAtStart) + bounded) / Double(self.jobCount)) * 0.9
            self.report(aggregate)
        }
    }

    func completeJob() {
        completedJobs = min(completedJobs + 1, jobCount)
        report((Double(completedJobs) / Double(jobCount)) * 0.9)
    }

    func finishComposition() {
        report(0.9)
    }

    private func report(_ value: Double) {
        let monotonic = min(max(value, lastProgress), 0.9)
        guard monotonic > lastProgress || monotonic == 0 else { return }
        lastProgress = monotonic
        progress(monotonic)
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
        purpose: ProjectCompositionPurpose = .preview,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> ProjectCompositionResult {
        guard project.tracks.contains(where: { !$0.clips.isEmpty }) else { throw ProjectCompositionError.emptyTimeline }
        let composition = AVMutableComposition()
        var primaryVideo: AVMutableCompositionTrack?
        var primaryAudio: AVMutableCompositionTrack?
        var cutawayVideo: AVMutableCompositionTrack?
        var cutawayAudio: AVMutableCompositionTrack?
        var additionalVideoTracks: [(track: AVMutableCompositionTrack, transforms: [(ProjectTimeRange, CGAffineTransform)])] = []
        var additionalAudioTracks: [(track: AVMutableCompositionTrack, source: TimelineTrack)] = []
        var transitionAudioTracks: [(track: AVMutableCompositionTrack, range: ProjectTimeRange)] = []

        let renderSize: CGSize? = {
            guard let width = project.format.width, let height = project.format.height,
                  width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }()
        let progressReporter = progress.map {
            ProjectCompositionProgressReporter(
                jobCount: renderJobCount(project: project, hasRenderSize: renderSize != nil),
                progress: $0
            )
        }
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
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let primaryAudioClip = project.tracks.first(where: { $0.role == .primaryAudio })?.clips.first(where: {
                $0.id == clip.id || $0.linkedClipID == clip.id
            })
            var processedAudio: AVAssetTrack?
            if let primaryAudioClip, !primaryAudioClip.audioSettings.isNeutral,
               let sourceURL = mediaURLs[clip.assetID] {
                let renderedURL = try await FFmpegTimelineEffectRenderer.renderAudio(
                    sourceURL: sourceURL,
                    segments: clip.segments,
                    settings: primaryAudioClip.audioSettings,
                    progress: progressReporter?.beginJob()
                )
                progressReporter?.completeJob()
                temporaryMediaURLs.append(renderedURL)
                processedAudio = try await AVURLAsset(url: renderedURL).loadTracks(withMediaType: .audio).first
                if primaryAudio == nil {
                    primaryAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let processedAudio, let primaryAudio {
                    let range = try await processedAudio.load(.timeRange)
                    try primaryAudio.insertTimeRange(range, of: processedAudio, at: cursor.cmTime)
                }
            }
            guard video != nil || audio != nil else {
                throw ProjectCompositionError.missingMedia(assetRecord.name)
            }
            let transform: CGAffineTransform?
            if let video {
                guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
                transform = try await displayTransform(for: video, renderSize: renderSize)
                if primaryVideo == nil {
                    primaryVideo = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                guard primaryVideo != nil else { throw ProjectCompositionError.cannotCreateTrack }
            } else {
                transform = nil
            }
            for segment in clip.segments {
                let range = segment.sourceRange.cmTimeRange
                if let video, let primaryVideo {
                    try primaryVideo.insertTimeRange(range, of: video, at: cursor.cmTime)
                }
                if let audio, processedAudio == nil {
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
                if let transform {
                    primaryTransforms.append((
                        ProjectTimeRange(start: cursor, duration: segment.duration),
                        transform
                    ))
                }
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
            guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
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

        for timelineTrack in project.tracks where timelineTrack.role == .additional {
            if timelineTrack.kind == .video {
                guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw ProjectCompositionError.cannotCreateTrack }
                var transforms: [(ProjectTimeRange, CGAffineTransform)] = []
                for clip in timelineTrack.sortedClips {
                    if project.cutaways.contains(where: { $0.id == clip.id }) { continue }
                    let record = try requireAsset(clip.assetID, in: project)
                    let asset = try await preparedAsset(
                        record, urls: mediaURLs, purpose: purpose, cache: &assets,
                        temporaryMediaURLs: &temporaryMediaURLs
                    )
                    guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                        throw ProjectCompositionError.missingVideo(record.name)
                    }
                    let transform = try await displayTransform(for: source, renderSize: renderSize)
                    var destination = clip.timelineStart
                    for segment in clip.segments {
                        try compositionTrack.insertTimeRange(segment.sourceRange.cmTimeRange, of: source, at: destination.cmTime)
                        transforms.append((ProjectTimeRange(start: destination, duration: segment.duration), transform))
                        destination = destination + segment.duration
                    }
                }
                additionalVideoTracks.append((compositionTrack, transforms))
            } else {
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw ProjectCompositionError.cannotCreateTrack }
                for clip in timelineTrack.sortedClips {
                    if project.cutaways.contains(where: {
                        $0.audioMode == .sourceAudio && $0.assetID == clip.assetID &&
                            $0.start == clip.timelineStart && $0.segments == clip.segments
                    }) { continue }
                    let record = try requireAsset(clip.assetID, in: project)
                    let asset = try await preparedAsset(
                        record, urls: mediaURLs, purpose: purpose, cache: &assets,
                        temporaryMediaURLs: &temporaryMediaURLs
                    )
                    var source = try await asset.loadTracks(withMediaType: .audio).first
                    var usesRenderedAudio = false
                    if !clip.audioSettings.isNeutral, let sourceURL = mediaURLs[clip.assetID] {
                        let renderedURL = try await FFmpegTimelineEffectRenderer.renderAudio(
                            sourceURL: sourceURL,
                            segments: clip.segments,
                            settings: clip.audioSettings,
                            progress: progressReporter?.beginJob()
                        )
                        progressReporter?.completeJob()
                        temporaryMediaURLs.append(renderedURL)
                        source = try await AVURLAsset(url: renderedURL).loadTracks(withMediaType: .audio).first
                        usesRenderedAudio = true
                    }
                    guard let source else { continue }
                    var destination = clip.timelineStart
                    if usesRenderedAudio {
                        let range = try await source.load(.timeRange)
                        try compositionTrack.insertTimeRange(range, of: source, at: destination.cmTime)
                        continue
                    }
                    for segment in clip.segments {
                        let available = try await source.load(.timeRange)
                        let portion = CMTimeRangeGetIntersection(segment.sourceRange.cmTimeRange, otherRange: available)
                        if portion.isValid, !portion.isEmpty {
                            let offset = CMTimeSubtract(portion.start, segment.sourceRange.start.cmTime)
                            try compositionTrack.insertTimeRange(portion, of: source, at: CMTimeAdd(destination.cmTime, offset))
                        }
                        destination = destination + segment.duration
                    }
                }
                additionalAudioTracks.append((compositionTrack, timelineTrack))
            }
        }

        for transition in project.transitions {
            guard transition.edge == .between,
                  case .audio(let type) = transition.kind,
                  type != .fade,
                  let track = project.track(id: transition.trackID),
                  let leadingID = transition.leadingClipID,
                  let trailingID = transition.trailingClipID,
                  let leading = track.clips.first(where: { $0.id == leadingID }),
                  let trailing = track.clips.first(where: { $0.id == trailingID }),
                  let leadingURL = mediaURLs[leading.assetID],
                  let trailingURL = mediaURLs[trailing.assetID] else { continue }
            let renderedURL: URL
            do {
                renderedURL = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
                    leadingURL: leadingURL,
                    trailingURL: trailingURL,
                    projectReferenceURL: track.sortedClips.first.flatMap { mediaURLs[$0.assetID] },
                    leadingClip: leading,
                    trailingClip: trailing,
                    type: type,
                    duration: transition.duration,
                    progress: progressReporter?.beginJob()
                )
                progressReporter?.completeJob()
            } catch {
                throw ProjectTransitionRenderError(
                    transitionID: transition.id,
                    transitionName: transition.displayName,
                    diagnostics: ProjectTransitionRenderError.diagnosticSummary(for: error)
                )
            }
            temporaryMediaURLs.append(renderedURL)
            let renderedAsset = AVURLAsset(url: renderedURL)
            guard let source = try await renderedAsset.loadTracks(withMediaType: .audio).first,
                  let transitionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { throw ProjectCompositionError.cannotCreateTrack }
            let sourceRange = try await source.load(.timeRange)
            let start = max(trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2), .zero)
            try transitionTrack.insertTimeRange(sourceRange, of: source, at: start.cmTime)
            transitionAudioTracks.append((
                transitionTrack,
                ProjectTimeRange(start: start, duration: transition.duration)
            ))
        }

        if let renderSize, let width = project.format.width, let height = project.format.height {
            for transition in project.transitions {
                guard transition.edge == .between,
                      case .video(let type) = transition.kind,
                      type != .fade,
                      let track = project.track(id: transition.trackID),
                      let leadingID = transition.leadingClipID,
                      let trailingID = transition.trailingClipID,
                      let leading = track.clips.first(where: { $0.id == leadingID }),
                      let trailing = track.clips.first(where: { $0.id == trailingID }),
                      let leadingURL = mediaURLs[leading.assetID],
                      let trailingURL = mediaURLs[trailing.assetID] else { continue }
                let renderedURL: URL
                do {
                    renderedURL = try await FFmpegTimelineEffectRenderer.renderVideoTransition(
                        leadingURL: leadingURL,
                        trailingURL: trailingURL,
                        leadingClip: leading,
                        trailingClip: trailing,
                        type: type,
                        duration: transition.duration,
                        width: width,
                        height: height,
                        frameRate: max(project.format.frameRate ?? 30, 1),
                        progress: progressReporter?.beginJob()
                    )
                    progressReporter?.completeJob()
                } catch {
                    throw ProjectTransitionRenderError(
                        transitionID: transition.id,
                        transitionName: transition.displayName,
                        diagnostics: ProjectTransitionRenderError.diagnosticSummary(for: error)
                    )
                }
                temporaryMediaURLs.append(renderedURL)
                let renderedAsset = AVURLAsset(url: renderedURL)
                guard let source = try await renderedAsset.loadTracks(withMediaType: .video).first,
                      let transitionTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { throw ProjectCompositionError.cannotCreateTrack }
                let sourceRange = try await source.load(.timeRange)
                let start = max(trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2), .zero)
                try transitionTrack.insertTimeRange(sourceRange, of: source, at: start.cmTime)
                additionalVideoTracks.append((transitionTrack, [(
                    ProjectTimeRange(start: start, duration: transition.duration),
                    CGAffineTransform.identity
                )]))
                _ = renderSize
            }
        }

        let videoComposition: AVMutableVideoComposition?
        if primaryVideo != nil || cutawayVideo != nil || !additionalVideoTracks.isEmpty {
            guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
            let composition = AVMutableVideoComposition()
            composition.renderSize = renderSize
            composition.frameDuration = CMTime(
                seconds: 1 / max(project.format.frameRate ?? 30, 1),
                preferredTimescale: ProjectTime.defaultTimescale
            )
            composition.instructions = makeVideoInstructions(
                duration: project.duration,
                primaryTrack: primaryVideo,
                primaryTransforms: primaryTransforms,
                cutawayTrack: cutawayVideo,
                cutawayTransforms: cutawayTransforms,
                cutaways: project.cutaways,
                additionalTracks: additionalVideoTracks,
                transitions: project.transitions,
                primaryTimelineTrack: project.tracks.first(where: { $0.role == .primaryVideo })
            )
            videoComposition = composition
        } else {
            videoComposition = nil
        }

        let sourceAudioCutaways = project.cutaways.filter { $0.audioMode == .sourceAudio }
        let audioMix: AVMutableAudioMix?
        if primaryAudio == nil && cutawayAudio == nil && additionalAudioTracks.isEmpty && transitionAudioTracks.isEmpty {
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
                if let primaryTrack = project.tracks.first(where: { $0.role == .primaryAudio }) {
                    for clip in primaryTrack.clips {
                        applyAudioTransitions(
                            project.transitions.filter { $0.trackID == primaryTrack.id },
                            clip: clip,
                            volume: 1,
                            parameters: primaryParameters
                        )
                    }
                    muteBaseAudioDuringBetweenTransitions(
                        project.transitions.filter { $0.trackID == primaryTrack.id },
                        on: primaryTrack,
                        parameters: primaryParameters
                    )
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
            for item in additionalAudioTracks {
                let input = AVMutableAudioMixInputParameters(track: item.track)
                input.setVolume(0, at: .zero)
                for clip in item.source.sortedClips {
                    let volume: Float = 1
                    input.setVolume(volume, at: clip.timelineStart.cmTime)
                    input.setVolume(0, at: clip.timelineEnd.cmTime)
                    applyAudioTransitions(
                        project.transitions.filter { $0.trackID == item.source.id },
                        clip: clip,
                        volume: volume,
                        parameters: input
                    )
                }
                muteBaseAudioDuringBetweenTransitions(
                    project.transitions.filter { $0.trackID == item.source.id },
                    on: item.source,
                    parameters: input
                )
                parameters.append(input)
            }
            for item in transitionAudioTracks {
                let input = AVMutableAudioMixInputParameters(track: item.track)
                input.setVolume(1, at: item.range.start.cmTime)
                parameters.append(input)
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
        progressReporter?.finishComposition()
        shouldPreserveTemporaryMedia = true
        return result
    }

    private static func renderJobCount(project: TrimatoProject, hasRenderSize: Bool) -> Int {
        let primaryAudio = project.tracks.first(where: { $0.role == .primaryAudio })
        let adjustedPrimaryClips = project.primaryTimeline.filter { videoClip in
            primaryAudio?.clips.first(where: {
                $0.id == videoClip.id || $0.linkedClipID == videoClip.id
            })?.audioSettings.isNeutral == false
        }.count
        let adjustedAdditionalAudioClips = project.tracks
            .filter { $0.role == .additional && $0.kind == .audio }
            .flatMap(\.clips)
            .filter { !$0.audioSettings.isNeutral }
            .count
        let audioTransitions = project.transitions.filter {
            guard $0.edge == .between, case .audio(let type) = $0.kind else { return false }
            return type != .fade
        }.count
        let videoTransitions = hasRenderSize ? project.transitions.filter {
            guard $0.edge == .between, case .video(let type) = $0.kind else { return false }
            return type != .fade
        }.count : 0
        return adjustedPrimaryClips + adjustedAdditionalAudioClips + audioTransitions + videoTransitions
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
                fingerprint: fingerprint,
                hasVideo: record.hasVideo
            )
            let asset = AVURLAsset(url: proxyURL)
            cache[record.id] = asset
            return asset
        }
        var asset = AVURLAsset(url: url)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        if purpose == .finalExport,
           record.playbackMode == .cachedProxy || !isPlayable {
            let intermediateURL = try await ProjectRenderMediaManager.createIntermediate(
                sourceURL: url,
                duration: record.duration.seconds,
                width: record.naturalWidth,
                height: record.naturalHeight,
                hasVideo: record.hasVideo,
                hasAudio: record.hasAudio
            )
            temporaryMediaURLs.append(intermediateURL)
            asset = AVURLAsset(url: intermediateURL)
        } else if purpose == .preview, !isPlayable {
            let report = try await FFmpegMediaProbe.inspect(url: url)
            try FFmpegMediaProbe.validateForMP4Conversion(report)
            let proxyURL = try await ProxyMediaManager.createProxy(
                sourceURL: url,
                duration: report.duration,
                hasVideo: report.videoStream != nil,
                progress: { _ in }
            )
            temporaryMediaURLs.append(proxyURL)
            asset = AVURLAsset(url: proxyURL)
        }
        cache[record.id] = asset
        return asset
    }

    static func displayTransform(
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
        primaryTrack: AVCompositionTrack?,
        primaryTransforms: [(ProjectTimeRange, CGAffineTransform)],
        cutawayTrack: AVCompositionTrack?,
        cutawayTransforms: [(ProjectTimeRange, CGAffineTransform)],
        cutaways: [TimelineCutaway],
        additionalTracks: [(track: AVMutableCompositionTrack, transforms: [(ProjectTimeRange, CGAffineTransform)])],
        transitions: [TimelineTransition],
        primaryTimelineTrack: TimelineTrack?
    ) -> [AVVideoCompositionInstructionProtocol] {
        var boundaries = [ProjectTime.zero, duration]
        boundaries.append(contentsOf: primaryTransforms.flatMap { [$0.0.start, $0.0.end] })
        boundaries.append(contentsOf: cutaways.flatMap { [$0.start, $0.end] })
        boundaries.append(contentsOf: additionalTracks.flatMap { $0.transforms.flatMap { [$0.0.start, $0.0.end] } })
        if let primaryTimelineTrack {
            for transition in transitions where transition.trackID == primaryTimelineTrack.id {
                guard case .video(.fade) = transition.kind else { continue }
                if transition.edge == .intro,
                   let id = transition.trailingClipID,
                   let clip = primaryTimelineTrack.clips.first(where: { $0.id == id }) {
                    boundaries.append(contentsOf: [clip.timelineStart, clip.timelineStart + transition.duration])
                } else if transition.edge == .outro,
                          let id = transition.leadingClipID,
                          let clip = primaryTimelineTrack.clips.first(where: { $0.id == id }) {
                    boundaries.append(contentsOf: [clip.timelineEnd - transition.duration, clip.timelineEnd])
                }
            }
        }
        boundaries = Array(Set(boundaries)).sorted()

        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = ProjectTimeRange(start: start, duration: end - start).cmTimeRange
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

            let primaryLayer: AVMutableVideoCompositionLayerInstruction? = primaryTrack.map {
                AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
            }
            if let primaryLayer,
               let transform = primaryTransforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 {
                primaryLayer.setTransform(transform, at: start.cmTime)
                if let primaryTimelineTrack {
                    for transition in transitions where transition.trackID == primaryTimelineTrack.id {
                        guard case .video(.fade) = transition.kind else { continue }
                        if transition.edge == .intro,
                           let id = transition.trailingClipID,
                           let clip = primaryTimelineTrack.clips.first(where: { $0.id == id }),
                           start == clip.timelineStart {
                            primaryLayer.setOpacityRamp(
                                fromStartOpacity: 0,
                                toEndOpacity: 1,
                                timeRange: ProjectTimeRange(start: start, duration: transition.duration).cmTimeRange
                            )
                        } else if transition.edge == .outro,
                                  let id = transition.leadingClipID,
                                  let clip = primaryTimelineTrack.clips.first(where: { $0.id == id }),
                                  start == clip.timelineEnd - transition.duration {
                            primaryLayer.setOpacityRamp(
                                fromStartOpacity: 1,
                                toEndOpacity: 0,
                                timeRange: ProjectTimeRange(start: start, duration: transition.duration).cmTimeRange
                            )
                        }
                    }
                }
            }
            var layers: [AVVideoCompositionLayerInstruction] = []
            for item in additionalTracks.reversed() {
                guard let transform = item.transforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 else { continue }
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                layer.setTransform(transform, at: start.cmTime)
                layers.append(layer)
            }
            if let cutawayTrack,
               let cutawayTransform = cutawayTransforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 {
                let cutawayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cutawayTrack)
                cutawayLayer.setTransform(cutawayTransform, at: start.cmTime)
                layers.append(cutawayLayer)
            }
            layers.append(contentsOf: [primaryLayer].compactMap { $0 })
            instruction.layerInstructions = layers
            return instruction
        }
    }

    private static func applyAudioTransitions(
        _ transitions: [TimelineTransition],
        clip: TimelineClip,
        volume: Float,
        parameters: AVMutableAudioMixInputParameters
    ) {
        for transition in transitions {
            let range: ProjectTimeRange?
            if transition.edge == .intro, transition.trailingClipID == clip.id {
                range = ProjectTimeRange(start: clip.timelineStart, duration: transition.duration)
            } else if transition.edge == .outro, transition.leadingClipID == clip.id {
                range = ProjectTimeRange(start: clip.timelineEnd - transition.duration, duration: transition.duration)
            } else {
                range = nil
            }
            guard let range else { continue }
            let fadesIn = transition.trailingClipID == clip.id
            parameters.setVolumeRamp(
                fromStartVolume: fadesIn ? 0 : volume,
                toEndVolume: fadesIn ? volume : 0,
                timeRange: range.cmTimeRange
            )
        }
    }

    private static func muteBaseAudioDuringBetweenTransitions(
        _ transitions: [TimelineTransition],
        on track: TimelineTrack,
        parameters: AVMutableAudioMixInputParameters
    ) {
        for transition in transitions where transition.edge == .between {
            guard case .audio(let type) = transition.kind, type != .fade,
                  let trailingID = transition.trailingClipID,
                  let trailing = track.clips.first(where: { $0.id == trailingID }) else { continue }
            let start = max(
                trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2),
                .zero
            )
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 0,
                timeRange: ProjectTimeRange(start: start, duration: transition.duration).cmTimeRange
            )
            parameters.setVolume(1, at: (start + transition.duration).cmTime)
        }
    }
}
