import AVFoundation
import CoreImage
import Foundation

/// Native color management keeps HDR filters in extended linear light until encoding.
nonisolated enum HDRVideoRenderer {
    @concurrent
    static func render(source: URL, filters: [ClipFilter] = [], policy: VideoColorPolicy = .hlg,
                       progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        let original = AVURLAsset(url: source)
        guard let track = try await original.loadTracks(withMediaType: .video).first else { throw ClipExportError.unavailable }
        let hasAlpha = track.hasMediaCharacteristic(.containsAlphaChannel)
        let asset = AVMutableComposition()
        guard let video = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipExportError.unavailable
        }
        try video.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        video.preferredTransform = try await track.load(.preferredTransform)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                                          .workingFormat: CIFormat.RGBAh])
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            var image = request.sourceImage
            for filter in filters { image = apply(filter, to: image) }
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            request.finish(with: image, context: context)
        })
        let size = try await track.load(.naturalSize).applying(video.preferredTransform)
        let extent = CGRect(x: 0, y: 0, width: abs(size.width), height: abs(size.height))
        let geometry = filters.reduce(CIImage(color: .black).cropped(to: extent)) { applyGeometry($1, to: $0) }
        composition.renderSize = geometry.extent.size
        policy.apply(to: composition)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-hdr-\(UUID()).mov")
        do {
            try await CustomMovieExporter.export(asset: asset, videoComposition: composition, audioMix: nil,
                timeRange: nil, format: .proRes422HQ, to: output, progress: { progress?($0) }, preserveAlpha: hasAlpha)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func apply(_ filter: ClipFilter, to image: CIImage) -> CIImage {
        switch filter.kind {
        case .brightnessContrast:
            return image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: filter.value("brightness"),
                                                                       kCIInputContrastKey: filter.value("contrast")])
        case .colorAdjustment:
            let saturated = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: filter.value("saturation")])
            return saturated.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + filter.value("warmth") * 0.3, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 + filter.value("tint") * 0.3, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - filter.value("warmth") * 0.3, w: 0)])
        case .blackAndWhite:
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .sharpen:
            return image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2,
                kCIInputIntensityKey: filter.value("amount")]).cropped(to: image.extent)
        case .videoNoise:
            return image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": filter.value("amount") * 0.01,
                kCIInputSharpnessKey: 0]).cropped(to: image.extent)
        case .cropOrientation: return applyGeometry(filter, to: image)
        default: return image
        }
    }

    private static func applyGeometry(_ filter: ClipFilter, to input: CIImage) -> CIImage {
        guard filter.kind == .cropOrientation else { return input }
        let left = filter.value("left"), right = filter.value("right"), top = filter.value("top"), bottom = filter.value("bottom")
        let extent = input.extent
        var image = input.cropped(to: CGRect(x: extent.minX + left, y: extent.minY + bottom,
            width: max(extent.width - left - right, 2), height: max(extent.height - top - bottom, 2)))
        image = image.transformed(by: CGAffineTransform(rotationAngle: -Double(filter.rotation) * .pi / 180))
        if filter.flipHorizontal { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if filter.flipVertical { image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)) }
        return image
    }
}
