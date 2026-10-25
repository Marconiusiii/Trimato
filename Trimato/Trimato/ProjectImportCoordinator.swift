import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ProjectImportCoordinator {
    nonisolated struct PlaybackPreparation: Sendable {
        var mode: ProjectMediaPlaybackMode
        var cacheKey: UUID?
        var fingerprint: SourceMediaFingerprint
    }

    nonisolated struct Discovery: Sendable {
        let selectedURL: URL
        let isDirectory: Bool
        let media: [URL]
        let captions: [URL]
    }

    /// Discover both kinds of input in one walk, away from the interface executor.
    @concurrent
    static func discover(_ selectedURL: URL) async throws -> Discovery {
        try discoverSynchronously(selectedURL)
    }

    nonisolated private static func discoverSynchronously(_ selectedURL: URL) throws -> Discovery {
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDirectory = values.isDirectory == true
        var media: [URL] = []
        var captions: [URL] = []
        func classify(_ url: URL, contentType: UTType? = nil) {
            if isCaptionFile(url) { captions.append(url) }
            else if MediaSelection.isSupportedMedia(url, contentType: contentType) { media.append(url) }
        }
        if !isDirectory { classify(selectedURL) }
        else if values.isPackage != true, selectedURL.pathExtension.lowercased() != "trimato" {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .contentTypeKey]
            var enumerationError: Error?
            let enumerator = FileManager.default.enumerator(at: selectedURL,
                includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in enumerationError = error; return false })
            if let enumerator {
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    let resource = try url.resourceValues(forKeys: Set(keys))
                    if resource.isRegularFile == true, resource.isHidden != true {
                        classify(url, contentType: resource.contentType)
                    }
                }
            }
            if let enumerationError { throw enumerationError }
        }
        try Task.checkCancellation()
        return Discovery(selectedURL: selectedURL, isDirectory: isDirectory,
            media: media.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            captions: captions.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    nonisolated static func importableMediaURLs(in selectedURL: URL) throws -> [URL] {
        try discoverSynchronously(selectedURL).media
    }

    nonisolated static func importableCaptionURLs(in selectedURL: URL) throws -> [URL] {
        try discoverSynchronously(selectedURL).captions
    }

    @concurrent
    static func importCaptionCues(at url: URL) async throws -> [CaptionCue] {
        guard let format = CaptionFileFormat.format(for: url) else {
            throw CaptionFileError.unsupportedFormat
        }
        return try CaptionFileCodec.decode(data: Data(contentsOf: url), format: format)
    }

    @concurrent
    static func importAsset(
        at url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> MediaAssetRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let metadata = try await metadata(for: url)
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )
        let projectDuration = ProjectTime(seconds: metadata.duration)
        let preparation = try await preparePlayback(
            at: url,
            metadata: metadata,
            preferredCacheKey: nil,
            progress: progress
        )

        return MediaAssetRecord(
            name: url.deletingPathExtension().lastPathComponent,
            originalPath: url.path,
            bookmarkData: bookmark,
            duration: projectDuration,
            naturalWidth: metadata.width,
            naturalHeight: metadata.height,
            frameRate: metadata.frameRate,
            hasAudio: metadata.hasAudio,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: projectDuration
            ))],
            playbackMode: preparation.mode,
            proxyCacheKey: preparation.cacheKey,
            sourceFingerprint: preparation.fingerprint
        )
    }

    /// Bound concurrent preparation so folder imports overlap metadata I/O without spawning a task per file.
    @concurrent
    static func importAssets(
        at urls: [URL],
        progress: @escaping @MainActor @Sendable (Int, Double) -> Void,
        completed: @escaping @MainActor @Sendable (Int, Result<MediaAssetRecord, Error>) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: (Int, Result<MediaAssetRecord, Error>).self) { group in
            var next = 0
            func add(_ index: Int) {
                let url = urls[index]
                group.addTask {
                    try Task.checkCancellation()
                    await progress(index, 0)
                    do {
                        let asset = try await importAsset(at: url, progress: { progress(index, $0) })
                        try Task.checkCancellation()
                        return (index, .success(asset))
                    } catch is CancellationError { throw CancellationError() }
                    catch { return (index, .failure(error)) }
                }
            }
            while next < min(4, urls.count) { add(next); next += 1 }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                await completed(index, result)
                if next < urls.count { add(next); next += 1 }
            }
        }
    }

    static func preparePlayback(
        at url: URL,
        preferredCacheKey: UUID?,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> PlaybackPreparation {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let metadata = try await metadata(for: url)
        return try await preparePlayback(
            at: url,
            metadata: metadata,
            preferredCacheKey: preferredCacheKey,
            progress: progress
        )
    }

    @concurrent
    private static func preparePlayback(
        at url: URL,
        metadata: (
            duration: Double,
            width: Int?,
            height: Int?,
            frameRate: Double?,
            hasVideo: Bool,
            hasAudio: Bool,
            playbackMode: ProjectMediaPlaybackMode
        ),
        preferredCacheKey: UUID?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PlaybackPreparation {
        let fingerprint = try MediaCacheManager.sourceFingerprint(for: url)
        let cacheKey = metadata.playbackMode == .cachedProxy ? preferredCacheKey ?? UUID() : nil
        if let cacheKey {
            _ = try await MediaCacheManager.shared.ensureProxy(
                sourceURL: url,
                duration: metadata.duration,
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                hasVideo: metadata.hasVideo,
                progress: progress
            )
        } else {
            await progress(1)
        }
        return PlaybackPreparation(
            mode: metadata.playbackMode,
            cacheKey: cacheKey,
            fingerprint: fingerprint
        )
    }

    @concurrent
    private static func metadata(for url: URL) async throws -> (
        duration: Double,
        width: Int?,
        height: Int?,
        frameRate: Double?,
        hasVideo: Bool,
        hasAudio: Bool,
        playbackMode: ProjectMediaPlaybackMode
    ) {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration),
           duration.isValid, duration.isNumeric, duration > .zero {
            let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
            let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
            if videoTrack != nil || hasAudio {
                let displayedSize: CGSize?
                let frameRate: Float?
                if let videoTrack {
                    let naturalSize = try await videoTrack.load(.naturalSize)
                    let transform = try await videoTrack.load(.preferredTransform)
                    displayedSize = naturalSize.applying(transform)
                    frameRate = try await videoTrack.load(.nominalFrameRate)
                } else {
                    displayedSize = nil
                    frameRate = nil
                }
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            let playbackMode: ProjectMediaPlaybackMode
            if !isPlayable {
                playbackMode = .cachedProxy
            } else if let contentType,
                      await ClipExporter.canPassthrough(asset: asset, sourceContentType: contentType) {
                playbackMode = .nativePassthrough
            } else {
                playbackMode = .nativeMP4Export
            }
            return (
                duration.seconds,
                displayedSize.map { Int(abs($0.width.rounded())) },
                displayedSize.map { Int(abs($0.height.rounded())) },
                frameRate.flatMap { $0 > 0 ? Double($0) : nil },
                videoTrack != nil,
                hasAudio,
                playbackMode
            )
            }
        }

        let report = try await FFmpegMediaProbe.inspect(url: url)
        try FFmpegMediaProbe.validateForMP4Conversion(report)
        guard report.duration.isFinite, report.duration > 0 else {
            throw MediaSourceError.unreadable("The selected media does not have a usable duration.")
        }
        return (
            report.duration,
            report.videoStream?.width,
            report.videoStream?.height,
            report.frameRate,
            report.videoStream != nil,
            report.hasAudio,
            .cachedProxy
        )
    }

    static func resolveURL(for asset: MediaAssetRecord) -> URL? {
        if let bookmarkData = asset.bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard FileManager.default.fileExists(atPath: asset.originalPath) else { return nil }
        return URL(fileURLWithPath: asset.originalPath)
    }

    nonisolated static func isCaptionFile(_ url: URL) -> Bool {
        CaptionFileFormat.format(for: url) != nil
    }
}
