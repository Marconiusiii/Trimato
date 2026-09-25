import CoreImage
import Foundation

/// Creative film-inspired looks, not a reconstruction of a particular film stock or print.
/// Both renderers use the same channel separation and amount. HDR contrast pivots in
/// linear light, leaving extended highlights unclamped; SDR works on encoded RGB.
nonisolated struct FilmLook {
    static func offsetDescription(_ value: Double) -> String {
        let pixels = Int(value.rounded())
        guard pixels != 0 else { return "Centered" }
        return "\(abs(pixels)) \(abs(pixels) == 1 ? "pixel" : "pixels") \(pixels < 0 ? "left" : "right")"
    }

    let kind: ClipFilterKind
    let offsets: [Double]
    let amount: Double
    let saturation: Double
    let contrast: Double
    let rows: [[Double]]

    init(filter: ClipFilter) {
        kind = filter.kind
        offsets = ["cyanOffset", "magentaOffset", "yellowOffset"].map { filter.value($0).rounded() }
        amount = min(max(filter.value("amount") / 100, 0), 1)
        switch filter.kind {
        case .bleachBypass:
            let saturation = 1 - 0.7 * amount
            self.saturation = saturation
            contrast = 1 + 0.35 * amount
            let luminance = [0.2126, 0.7152, 0.0722]
            rows = (0..<3).map { row in
                (0..<3).map { column in
                    (row == column ? saturation : 0) + (1 - saturation) * luminance[column]
                }
            }
        case .technicolor:
            saturation = 1
            contrast = 1 + 0.15 * amount
            rows = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        default:
            saturation = 1
            contrast = 1
            rows = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        }
    }

    var graph: String {
        guard amount > 0 else { return "null" }
        if kind == .technicolor { return technicolorGraph }
        let names = [["rr", "rg", "rb"], ["gr", "gg", "gb"], ["br", "bg", "bb"]]
        let matrix = (0..<3).flatMap { row in
            (0..<3).map { column in "\(names[row][column])=\(rows[row][column])" }
        }.joined(separator: ":")
        // Keep sixteen-bit channel precision until the existing output encoder.
        let curve = "clip((val/maxval-0.5)*\(contrast)+0.5,0,1)*maxval"
        return "format=gbrp16le,colorchannelmixer=\(matrix),lutrgb=r='\(curve)':g='\(curve)':b='\(curve)'"
    }

    func apply(to image: CIImage) -> CIImage {
        guard amount > 0 else { return image }
        if kind == .technicolor { return applyTechnicolor(to: image) }
        let vectors = rows.map { CIVector(x: $0[0] * contrast, y: $0[1] * contrast, z: $0[2] * contrast, w: 0) }
        let bias = 0.18 * (1 - contrast)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": vectors[0], "inputGVector": vectors[1], "inputBVector": vectors[2],
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])
    }
    // Ideal cyan, magenta and yellow transmission layers are (R,1,1), (1,G,1)
    // and (1,1,B). Their product is (R,G,B). Evaluate that product per channel
    // in FFmpeg rather than allocating three full-frame intermediate streams.
    private var technicolorGraph: String {
        let channels = ["r", "g", "b"]
        let expressions = channels.enumerated().map { index, channel in
            let sample = "\(channel)(clip(X-(\(offsets[index])),0,W-1),Y)"
            let dye = "clip((\(sample)/65535-0.5)*1.15+0.5,0,1)*65535"
            return "\(channel)='(1-\(amount))*\(channel)(X,Y)+\(amount)*(\(dye))'"
        }
        return "format=gbrp16le,geq=\(expressions.joined(separator: ":")):interpolation=nearest"
    }

    private func applyTechnicolor(to image: CIImage) -> CIImage {
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let keys = ["inputRVector", "inputGVector", "inputBVector"]
        let layers = (0..<3).map { channel -> CIImage in
            var vector = [CGFloat](repeating: 0, count: 4)
            vector[channel] = 1.15
            var bias = [CGFloat](repeating: 1, count: 4)
            bias[channel] = 0.18 * (1 - 1.15)
            var parameters: [String: Any] = ["inputRVector": zero, "inputGVector": zero,
                "inputBVector": zero, "inputAVector": zero,
                "inputBiasVector": CIVector(values: bias, count: 4)]
            parameters[keys[channel]] = CIVector(values: vector, count: 4)
            return image.applyingFilter("CIColorMatrix", parameters: parameters)
                .cropped(to: image.extent)
                .clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: offsets[channel], y: 0))
                .cropped(to: image.extent)
        }
        let combined = layers[0].applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: layers[1]])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: layers[2]])
        // Color offsets must never translate the clip's transparency mask.
        let restoredAlpha = combined.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: image
        ])
        return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: restoredAlpha,
            kCIInputTimeKey: amount]).cropped(to: image.extent)
    }

}
