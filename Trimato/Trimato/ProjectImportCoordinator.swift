import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ProjectImportCoordinator {
    private static let explicitlySupportedExtensions: Set<String> = [
        "mkv", "webm", "ts", "mts", "m2ts", "vob", "wmv", "flv",
    ]

    struct PlaybackPreparation: Sendable {
        var mode: ProjectMediaPlaybackMode
        var cacheKey: UUID?
        var fingerprint: SourceMediaFingerprint
    }

    static func importableMediaURLs(in selectedURL: URL) throws -> [URL] {
        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            return isSupportedMedia(selectedURL) ? [selectedURL] : []
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: selectedURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: Set(keys))
            guard resourceValues.isRegularFile == true,
                  resourceValues.isHidden != true,
                  isSupportedMedia(url, contentType: resourceValues.contentType) else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func importAsset(at url: URL) async throws -> MediaAssetRecord {
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
            preferredCacheKey: nil
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

    static func preparePlayback(
        at url: URL,
        preferredCacheKey: UUID?
    ) async throws -> PlaybackPreparation {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let metadata = try await metadata(for: url)
        return try await preparePlayback(
            at: url,
            metadata: metadata,
            preferredCacheKey: preferredCacheKey
        )
    }

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
        preferredCacheKey: UUID?
    ) async throws -> PlaybackPreparation {
        let fingerprint = try MediaCacheManager.sourceFingerprint(for: url)
        let cacheKey = metadata.playbackMode == .cachedProxy ? preferredCacheKey ?? UUID() : nil
        if let cacheKey {
            _ = try await MediaCacheManager.shared.ensureProxy(
                sourceURL: url,
                duration: metadata.duration,
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                hasVideo: metadata.hasVideo
            )
        }
        return PlaybackPreparation(
            mode: metadata.playbackMode,
            cacheKey: cacheKey,
            fingerprint: fingerprint
        )
    }

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
                      ClipExporter.canPassthrough(asset: asset, sourceContentType: contentType) {
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

    private static func isSupportedMedia(_ url: URL, contentType: UTType? = nil) -> Bool {
        if explicitlySupportedExtensions.contains(url.pathExtension.lowercased()) { return true }
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true
    }
}
