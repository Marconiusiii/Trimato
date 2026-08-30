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
    case audioProcessingFailed(clip: String, track: String, detail: String)
    case audioInsertionFailed(clip: String, track: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "Add at least one clip before previewing or exporting."
        case .missingMedia(let name): "The media file for \(name) is offline."
        case .missingVideo(let name): "\(name) does not contain a usable video track."
        case .cannotCreateTrack: "Trimato could not create the project media tracks."
        case .unresolvedFormat: "Add a clip or choose custom project dimensions before previewing."
        case .audioProcessingFailed(let clip, let track, let detail):
            "Trimato could not process \(clip) on the \(track) track for project playback. \(detail)"
        case .audioInsertionFailed(let clip, let track, let detail):
            "Trimato processed \(clip), but could not add its audio to the \(track) track for project playback. \(detail)"
        }
    }

    static func failureDetail(for error: Error) -> String {
        if let commandError = error as? FFmpegCommandError,
           let diagnostic = ProjectTransitionRenderError.diagnosticSummary(for: commandError) {
            return diagnostic
        }
        let nsError = error as NSError
        if let reason = nsError.localizedFailureReason, isUseful(reason) {
            return reason
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if let reason = underlying.localizedFailureReason, isUseful(reason) {
                return reason
            }
            if isUseful(underlying.localizedDescription) {
                return underlying.localizedDescription
            }
        }
        if isUseful(nsError.localizedDescription) {
            return nsError.localizedDescription
        }
        return "The media framework reported \(nsError.domain) error \(nsError.code)."
    }

    private static func isUseful(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && !normalized.contains("operation could not be completed")
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
        let (project, mediaURLs, filteredURLs) = try await ClipFilterRenderer.prepare(project: project, urls: mediaURLs)
        let composition = AVMutableComposition()
        var primaryVideo: AVMutableCompositionTrack?
        var cutawayVideo: AVMutableCompositionTrack?
        var additionalVideoTracks: [(track: AVMutableCompositionTrack, transforms: [(ProjectTimeRange, CGAffineTransform)], source: TimelineTrack?)] = []
        var additionalAudioTracks: [(track: AVMutableCompositionTrack, source: TimelineTrack)] = []
        var transitionAudioTracks: [(track: AVMutableCompositionTrack, source: TimelineTrack)] = []

        let renderSize: CGSize? = {
            guard let width = project.format.width, let height = project.format.height,
                  width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }()
        let projectFrameRate = ProjectFormat.stableFrameRate(project.format.frameRate ?? 30)
        let progressReporter = progress.map {
            ProjectCompositionProgressReporter(
                jobCount: renderJobCount(project: project, hasRenderSize: renderSize != nil),
                progress: $0
            )
        }
        var assets: [UUID: AVURLAsset] = [:]
        var temporaryMediaURLs: [URL] = filteredURLs
        var shouldPreserveTemporaryMedia = false
        defer {
            if !shouldPreserveTemporaryMedia {
                for url in temporaryMediaURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        var primaryTransforms: [(ProjectTimeRange, CGAffineTransform)] = []
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
            let transform = try await displayTransform(for: video, renderSize: renderSize)
            var cutawayCursor = cutaway.start
            for segment in cutaway.segments {
                let range = segment.sourceRange.cmTimeRange
                try cutawayVideo.insertTimeRange(range, of: video, at: cutawayCursor.cmTime)
                cutawayTransforms.append((
                    ProjectTimeRange(start: cutawayCursor, duration: segment.duration),
                    transform
                ))
                cutawayCursor = cutawayCursor + segment.duration
            }
        }

        for timelineTrack in project.tracks {
            if timelineTrack.kind == .video {
                guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw ProjectCompositionError.cannotCreateTrack }
                var transforms: [(ProjectTimeRange, CGAffineTransform)] = []
                for clip in timelineTrack.sortedClips {
                    if project.cutaways.contains(where: { $0.id == clip.id }) { continue }
                    guard clip.visibleDuration.isPositive else { continue }
                    let record = try requireAsset(clip.assetID, in: project)
                    let asset = try await preparedAsset(
                        record, urls: mediaURLs, purpose: purpose, cache: &assets,
                        temporaryMediaURLs: &temporaryMediaURLs
                    )
                    guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                        // Older primary records can describe picture even when the
                        // resolved source contains only audio. Keep that audio usable.
                        if timelineTrack.role == .primaryVideo,
                           try await !asset.loadTracks(withMediaType: .audio).isEmpty { continue }
                        throw ProjectCompositionError.missingVideo(record.name)
                    }
                    let transform = try await displayTransform(for: source, renderSize: renderSize)
                    var destination = clip.visibleTimelineStart
                    for segment in clip.visibleSegments {
                        try compositionTrack.insertTimeRange(segment.sourceRange.cmTimeRange, of: source, at: destination.cmTime)
                        transforms.append((ProjectTimeRange(start: destination, duration: segment.duration), transform))
                        destination = destination + segment.duration
                    }
                }
                if transforms.isEmpty {
                    composition.removeTrack(compositionTrack)
                    continue
                }
                if timelineTrack.role == .primaryVideo {
                    primaryVideo = compositionTrack
                    primaryTransforms = transforms
                } else {
                    additionalVideoTracks.append((compositionTrack, transforms, timelineTrack))
                }
            } else {
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw ProjectCompositionError.cannotCreateTrack }
                for clip in timelineTrack.sortedClips {
                    guard clip.visibleDuration.isPositive else { continue }
                    let record = try requireAsset(clip.assetID, in: project)
                    let asset = try await preparedAsset(
                        record, urls: mediaURLs, purpose: purpose, cache: &assets,
                        temporaryMediaURLs: &temporaryMediaURLs
                    )
                    var source = try await asset.loadTracks(withMediaType: .audio).first
                    var renderedAudioAsset: AVURLAsset?
                    var usesRenderedAudio = false
                    if !clip.audioSettings.isNeutral, let sourceURL = mediaURLs[clip.assetID] {
                        let renderedURL: URL
                        do {
                            renderedURL = try await FFmpegTimelineEffectRenderer.renderAudio(
                                sourceURL: sourceURL,
                                segments: clip.segments,
                                settings: clip.audioSettings,
                                progress: progressReporter?.beginJob()
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw ProjectCompositionError.audioProcessingFailed(
                                clip: clip.displayName,
                                track: timelineTrack.name,
                                detail: ProjectCompositionError.failureDetail(for: error)
                            )
                        }
                        progressReporter?.completeJob()
                        temporaryMediaURLs.append(renderedURL)
                        let retainedAsset = AVURLAsset(url: renderedURL)
                        renderedAudioAsset = retainedAsset
                        source = try await retainedAsset.loadTracks(withMediaType: .audio).first
                        usesRenderedAudio = true
                    }
                    guard let source else { continue }
                    var destination = clip.visibleTimelineStart
                    if usesRenderedAudio {
                        let available = try await source.load(.timeRange)
                        let requested = CMTimeRange(
                            start: CMTimeAdd(available.start, clip.hiddenBeforeTimeline.cmTime),
                            duration: clip.visibleDuration.cmTime
                        )
                        let portion = CMTimeRangeGetIntersection(requested, otherRange: available)
                        if portion.isValid, !portion.isEmpty {
                            do {
                                try compositionTrack.insertTimeRange(portion, of: source, at: destination.cmTime)
                            } catch {
                                throw ProjectCompositionError.audioInsertionFailed(
                                    clip: clip.displayName,
                                    track: timelineTrack.name,
                                    detail: ProjectCompositionError.failureDetail(for: error)
                                )
                            }
                        }
                        withExtendedLifetime(renderedAudioAsset) {}
                        continue
                    }
                    for segment in clip.visibleSegments {
                        let available = try await source.load(.timeRange)
                        let portion = CMTimeRangeGetIntersection(segment.sourceRange.cmTimeRange, otherRange: available)
                        if portion.isValid, !portion.isEmpty {
                            let offset = CMTimeSubtract(portion.start, segment.sourceRange.start.cmTime)
                            do {
                                try compositionTrack.insertTimeRange(
                                    portion,
                                    of: source,
                                    at: CMTimeAdd(destination.cmTime, offset)
                                )
                            } catch {
                                throw ProjectCompositionError.audioInsertionFailed(
                                    clip: clip.displayName,
                                    track: timelineTrack.name,
                                    detail: ProjectCompositionError.failureDetail(for: error)
                                )
                            }
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
            let sourceRange = try await transitionSourceRange(
                for: source,
                requestedDuration: transition.duration,
                mediaDescription: "audio"
            )
            let start = max(trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2), .zero)
            try transitionTrack.insertTimeRange(sourceRange, of: source, at: start.cmTime)
            transitionAudioTracks.append((
                transitionTrack,
                track
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
                        frameRate: projectFrameRate,
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
                let renderedFrameRate = Double(try await source.load(.nominalFrameRate))
                guard abs(renderedFrameRate - projectFrameRate) <= 0.001 else {
                    throw ProjectTransitionRenderError(
                        transitionID: transition.id,
                        transitionName: transition.displayName,
                        diagnostics: "The rendered frame rate did not match the project frame rate."
                    )
                }
                let sourceRange = try await transitionSourceRange(
                    for: source,
                    requestedDuration: transition.duration,
                    mediaDescription: "video"
                )
                let start = max(trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2), .zero)
                try transitionTrack.insertTimeRange(sourceRange, of: source, at: start.cmTime)
                additionalVideoTracks.append((transitionTrack, [(
                    ProjectTimeRange(start: start, duration: transition.duration),
                    CGAffineTransform.identity
                )], nil))
                _ = renderSize
            }
        }

        let videoComposition: AVMutableVideoComposition?
        if primaryVideo != nil || cutawayVideo != nil || !additionalVideoTracks.isEmpty {
            guard let renderSize else { throw ProjectCompositionError.unresolvedFormat }
            let composition = AVMutableVideoComposition()
            composition.renderSize = renderSize
            composition.frameDuration = CMTime(
                seconds: 1 / projectFrameRate,
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
                primaryTimelineTrack: project.tracks.first(where: { $0.role == .primaryVideo }),
                timelineTracks: project.tracks
            )
            videoComposition = composition
        } else {
            videoComposition = nil
        }

        let sourceAudioCutaways = project.cutaways.filter { $0.audioMode == .sourceAudio }
        let audioMix: AVMutableAudioMix?
        if additionalAudioTracks.isEmpty && transitionAudioTracks.isEmpty {
            audioMix = nil
        } else {
            var parameters: [AVMutableAudioMixInputParameters] = []
            for item in additionalAudioTracks {
                let input = AVMutableAudioMixInputParameters(track: item.track)
                applyBaseAudioEnvelope(
                    duration: project.duration,
                    transitions: project.transitions.filter { $0.trackID == item.source.id },
                    on: item.source,
                    mutedRanges: item.source.isMuted
                        ? [ProjectTimeRange(start: .zero, duration: project.duration)]
                        : (item.source.role == .primaryAudio ? sourceAudioCutaways.map {
                            ProjectTimeRange(start: $0.start, duration: $0.duration)
                        } : []),
                    parameters: input
                )
                parameters.append(input)
            }
            for item in transitionAudioTracks {
                let input = AVMutableAudioMixInputParameters(track: item.track)
                input.setVolume(item.source.isMuted ? 0 : 1, at: .zero)
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

    private static func transitionSourceRange(
        for track: AVAssetTrack,
        requestedDuration: ProjectTime,
        mediaDescription: String
    ) async throws -> CMTimeRange {
        let available = try await track.load(.timeRange)
        let requested = requestedDuration.cmTime
        guard available.isValid,
              !available.isEmpty,
              CMTimeCompare(available.duration, requested) >= 0 else {
            throw ProjectTimelineError.transitionNotAvailable(
                "The rendered \(mediaDescription) transition was shorter than the requested duration."
            )
        }
        return CMTimeRange(start: available.start, duration: requested)
    }

    private static func renderJobCount(project: TrimatoProject, hasRenderSize: Bool) -> Int {
        let adjustedAudioClips = project.tracks
            .filter { $0.kind == .audio }
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
        return adjustedAudioClips + audioTransitions + videoTransitions
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
        if let generator = record.generator {
            let asset = AVURLAsset(url: try await GeneratorRenderer.ensure(generator))
            cache[record.id] = asset
            return asset
        }
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
        additionalTracks: [(track: AVMutableCompositionTrack, transforms: [(ProjectTimeRange, CGAffineTransform)], source: TimelineTrack?)],
        transitions: [TimelineTransition],
        primaryTimelineTrack: TimelineTrack?,
        timelineTracks: [TimelineTrack]
    ) -> [AVVideoCompositionInstructionProtocol] {
        var boundaries = [ProjectTime.zero, duration]
        boundaries.append(contentsOf: primaryTransforms.flatMap { [$0.0.start, $0.0.end] })
        boundaries.append(contentsOf: cutaways.flatMap { [$0.start, $0.end] })
        boundaries.append(contentsOf: additionalTracks.flatMap { $0.transforms.flatMap { [$0.0.start, $0.0.end] } })
        let sourceTracks = timelineTracks.filter { $0.kind == .video }
        for source in sourceTracks {
            for transition in transitions where transition.trackID == source.id {
                guard case .video(.fade) = transition.kind,
                      let id = transition.edge == .intro ? transition.trailingClipID : transition.leadingClipID,
                      let clip = source.clips.first(where: { $0.id == id }) else { continue }
                let fadeStart = transition.edge == .intro ? clip.timelineStart : clip.timelineEnd - transition.duration
                boundaries.append(contentsOf: [fadeStart, fadeStart + transition.duration])
            }
        }
        boundaries = Array(Set(boundaries.filter { $0 >= .zero && $0 <= duration })).sorted()

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
                applyVideoFades(to: primaryLayer, source: primaryTimelineTrack, transitions: transitions, start: start, end: end)
            }
            var layers: [AVVideoCompositionLayerInstruction] = []
            for item in additionalTracks.reversed() {
                guard let transform = item.transforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 else { continue }
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                layer.setTransform(transform, at: start.cmTime)
                applyVideoFades(to: layer, source: item.source, transitions: transitions, start: start, end: end)
                layers.append(layer)
            }
            if let cutawayTrack,
               let cutawayTransform = cutawayTransforms.first(where: { start >= $0.0.start && start < $0.0.end })?.1 {
                let cutawayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cutawayTrack)
                cutawayLayer.setTransform(cutawayTransform, at: start.cmTime)
                if let cutaway = cutaways.first(where: { start >= $0.start && start < $0.end }) {
                    let source = timelineTracks.first { $0.clips.contains { $0.id == cutaway.id } }
                    applyVideoFades(to: cutawayLayer, source: source, transitions: transitions, start: start, end: end)
                }
                layers.append(cutawayLayer)
            }
            layers.append(contentsOf: [primaryLayer].compactMap { $0 })
            instruction.layerInstructions = layers
            return instruction
        }
    }

    // Each instruction covers only one interval, including boundaries introduced by other tracks.
    // Continue the opacity envelope at the interval's actual position rather than restarting it.
    private static func applyVideoFades(
        to layer: AVMutableVideoCompositionLayerInstruction,
        source: TimelineTrack?, transitions: [TimelineTransition],
        start: ProjectTime, end: ProjectTime
    ) {
        guard let source else { return }
        for transition in transitions where transition.trackID == source.id {
            guard case .video(.fade) = transition.kind,
                  let id = transition.edge == .intro ? transition.trailingClipID : transition.leadingClipID,
                  let clip = source.clips.first(where: { $0.id == id }) else { continue }
            let fadeStart = transition.edge == .intro ? clip.timelineStart : clip.timelineEnd - transition.duration
            let fadeEnd = fadeStart + transition.duration
            guard start >= fadeStart, end <= fadeEnd, transition.duration.isPositive else { continue }
            let fractionStart = Float((start - fadeStart).seconds / transition.duration.seconds)
            let fractionEnd = Float((end - fadeStart).seconds / transition.duration.seconds)
            layer.setOpacityRamp(
                fromStartOpacity: transition.edge == .intro ? fractionStart : 1 - fractionStart,
                toEndOpacity: transition.edge == .intro ? fractionEnd : 1 - fractionEnd,
                timeRange: ProjectTimeRange(start: start, duration: end - start).cmTimeRange
            )
        }
    }

    private static func applyBaseAudioEnvelope(
        duration: ProjectTime,
        transitions: [TimelineTransition],
        on track: TimelineTrack,
        mutedRanges: [ProjectTimeRange],
        parameters: AVMutableAudioMixInputParameters
    ) {
        guard duration.isPositive else { return }
        let fadeRules = audioFadeRules(transitions, on: track)
        let betweenMutes = betweenTransitionMuteRanges(transitions, on: track)
        let allMutes = mutedRanges + betweenMutes
        var boundaries = [ProjectTime.zero, duration]
        boundaries.append(contentsOf: fadeRules.flatMap { [$0.range.start, $0.range.end] })
        boundaries.append(contentsOf: allMutes.flatMap { [$0.start, $0.end] })
        boundaries = Array(Set(boundaries.filter { $0 >= .zero && $0 <= duration })).sorted()

        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let range = ProjectTimeRange(start: start, duration: end - start)
            let isMuted = allMutes.contains { start >= $0.start && end <= $0.end }
            let activeFadeRules = fadeRules.filter {
                start >= $0.range.start && end <= $0.range.end
            }
            let startVolume = isMuted ? 0 : fadeVolume(at: start, rules: activeFadeRules)
            let endVolume = isMuted ? 0 : fadeVolume(at: end, rules: activeFadeRules)
            parameters.setVolumeRamp(
                fromStartVolume: startVolume,
                toEndVolume: endVolume,
                timeRange: range.cmTimeRange
            )
        }
    }

    private struct AudioFadeRule {
        let range: ProjectTimeRange
        let startVolume: Float
        let endVolume: Float
    }

    private static func audioFadeRules(
        _ transitions: [TimelineTransition],
        on track: TimelineTrack
    ) -> [AudioFadeRule] {
        transitions.compactMap { transition in
            guard case .audio(.fade) = transition.kind else { return nil }
            if transition.edge == .intro,
               let trailingID = transition.trailingClipID,
               let clip = track.clips.first(where: { $0.id == trailingID }) {
                return AudioFadeRule(
                    range: ProjectTimeRange(start: clip.timelineStart, duration: transition.duration),
                    startVolume: 0,
                    endVolume: 1
                )
            }
            if transition.edge == .outro,
               let leadingID = transition.leadingClipID,
               let clip = track.clips.first(where: { $0.id == leadingID }) {
                return AudioFadeRule(
                    range: ProjectTimeRange(start: clip.timelineEnd - transition.duration, duration: transition.duration),
                    startVolume: 1,
                    endVolume: 0
                )
            }
            return nil
        }
    }

    private static func betweenTransitionMuteRanges(
        _ transitions: [TimelineTransition],
        on track: TimelineTrack
    ) -> [ProjectTimeRange] {
        transitions.compactMap { transition in
            guard transition.edge == .between,
                  case .audio(let type) = transition.kind,
                  type != .fade,
                  let trailingID = transition.trailingClipID,
                  let trailing = track.clips.first(where: { $0.id == trailingID }) else { return nil }
            let start = max(
                trailing.timelineStart - ProjectTime(seconds: transition.duration.seconds / 2),
                .zero
            )
            return ProjectTimeRange(start: start, duration: transition.duration)
        }
    }

    private static func fadeVolume(at time: ProjectTime, rules: [AudioFadeRule]) -> Float {
        rules.reduce(Float(1)) { volume, rule in
            guard time >= rule.range.start, time <= rule.range.end else { return volume }
            let elapsed = (time - rule.range.start).seconds
            let fraction = min(max(elapsed / rule.range.duration.seconds, 0), 1)
            let value = rule.startVolume + Float(fraction) * (rule.endVolume - rule.startVolume)
            return min(volume, value)
        }
    }
}
