import AVFoundation
import UniformTypeIdentifiers

struct MediaSource {
    enum Mode: Equatable {
        case nativePassthrough
        case nativePlaybackMP4Export
        case proxyPlaybackMP4Export

        var exportFileType: UTType {
            switch self {
            case .nativePassthrough:
                return .data
            case .nativePlaybackMP4Export, .proxyPlaybackMP4Export:
                return .mpeg4Movie
            }
        }
    }

    let originalURL: URL
    let playbackURL: URL
    let originalAsset: AVURLAsset
    let playbackAsset: AVURLAsset
    let contentType: UTType?
    let mode: Mode
    let frameTimestamps: [CMTime]

    var usesProxy: Bool { mode == .proxyPlaybackMP4Export }

    static func native(
        url: URL,
        asset: AVURLAsset,
        contentType: UTType?,
        mode: Mode,
        frameTimestamps: [CMTime] = []
    ) -> MediaSource {
        MediaSource(
            originalURL: url,
            playbackURL: url,
            originalAsset: asset,
            playbackAsset: asset,
            contentType: contentType,
            mode: mode,
            frameTimestamps: frameTimestamps
        )
    }
}

enum MediaSourceError: LocalizedError, Equatable {
    case bundledToolsMissing
    case noVideoTrack
    case protectedContent
    case unsupportedHDR
    case unsupportedAlpha
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .bundledToolsMissing:
            return "The bundled FFmpeg tools are missing from this copy of vidTime."
        case .noVideoTrack:
            return "The selected file does not contain a video track."
        case .protectedContent:
            return "Protected or DRM-encrypted video cannot be opened."
        case .unsupportedHDR:
            return "This HDR video would require color conversion that vidTime does not yet perform safely."
        case .unsupportedAlpha:
            return "This video has transparency, which cannot be preserved in an H.264 MP4 export."
        case .unreadable(let detail):
            return detail.isEmpty ? "The selected video could not be read." : detail
        }
    }
}
