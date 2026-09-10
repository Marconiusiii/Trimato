import AVFoundation
import Foundation

nonisolated enum VideoColorPolicy: String, Sendable {
    case sdr, hlg

    static func resolve(asset: AVAsset, preserveHDR: Bool) async throws -> Self {
        guard preserveHDR else { return .sdr }
        for track in try await asset.loadTracks(withMediaType: .video) {
            if track.hasMediaCharacteristic(.containsHDRVideo) { return .hlg }
            for description in try await track.load(.formatDescriptions) {
                let transfer = CMFormatDescriptionGetExtension(description,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                if transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ {
                    return .hlg
                }
            }
        }
        return .sdr
    }

    static func resolve(project: TrimatoProject, urls: [UUID: URL], preserveHDR: Bool) async throws -> Self {
        guard preserveHDR else { return .sdr }
        let ids = Set(project.tracks.filter { $0.kind == .video }.flatMap(\.clips).map(\.assetID))
        for id in ids {
            if let url = urls[id], try await resolve(asset: AVURLAsset(url: url), preserveHDR: true) == .hlg { return .hlg }
        }
        return .sdr
    }

    var properties: [String: String] {
        [AVVideoColorPrimariesKey: self == .hlg ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: self == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: self == .hlg ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    func apply(to composition: AVMutableVideoComposition) {
        composition.colorPrimaries = properties[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = properties[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = properties[AVVideoYCbCrMatrixKey]
        // The HEVC writer regenerates metadata from the finished frames.
        composition.perFrameHDRDisplayMetadataPolicy = .propagate
    }

    func validate(format: ExportFormat) throws {
        if self == .hlg, !format.isAudioOnly, !format.supportsHDR {
            throw ProjectExporter.ExportError.encodingFailed(
                "This project contains HDR video. Choose HEVC or ProRes to preserve HDR, or turn off Preserve HDR in Video Settings to export in SDR.")
        }
    }

    static func composition(for asset: AVAsset, policy: Self) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        policy.apply(to: composition)
        return composition
    }
}
