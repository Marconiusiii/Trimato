import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// The UI and encoder use this same layout, including the fit check. Text never enters
// an FFmpeg expression, so punctuation, newlines, and Unicode remain literal text.
nonisolated enum TextGeneratorRenderer {
    struct Layout {
        let frame: CTFrame
        let lineCount: Int
        let textBounds: CGRect
        let paintedBounds: CGRect
        let fits: Bool
        let fontSize: Double
        let warnings: [String]

        var report: String {
            "\(lineCount) \(lineCount == 1 ? "line" : "lines"). " +
            (fits ? "Fits within the safe area." : "Text extends outside the safe area. Reduce the size, shorten the text, or adjust Layout.") +
            (warnings.isEmpty ? "" : " " + warnings.joined(separator: " "))
        }
    }

    static func layout(_ definition: GeneratorDefinition) throws -> Layout {
        try Task.checkCancellation()
        try definition.validate()
        let settings = definition.textSettings
        let width = Double(definition.width), height = Double(definition.height)
        let fontSize = height * settings.sizePercent / 100
        let safe = CGRect(x: width * settings.safeMargin / 100, y: height * settings.safeMargin / 100,
                          width: width * (1 - settings.safeMargin / 50), height: height * (1 - settings.safeMargin / 50))
        let decorationPadding = max(settings.panelEnabled ? fontSize * 0.3 : 0,
                                    settings.shadowEnabled ? fontSize * 0.2 : (settings.outlineEnabled ? fontSize * 0.06 : 1))
        let available = safe.insetBy(dx: decorationPadding, dy: decorationPadding)
        guard available.width > 1, available.height > 1 else {
            throw MediaSourceError.unreadable("The safe margins leave no room for text at this size.")
        }
        let textWidth = max(1, available.width * settings.maximumWidth / 100)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch settings.alignment { case .left: .left; case .center: .center; case .right: .right }
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = fontSize * settings.lineSpacing / 100
        paragraph.paragraphSpacing = fontSize * settings.lineSpacing / 100
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(settings.font, weight: settings.weight, size: fontSize),
            .foregroundColor: nsColor(settings.color), .paragraphStyle: paragraph
        ]
        if settings.outlineEnabled {
            attributes[.strokeColor] = nsColor(settings.outlineColor)
            attributes[.strokeWidth] = -3.0 // A negative percentage draws both fill and outline.
        }
        let text = NSMutableAttributedString(string: settings.text, attributes: attributes)
        if settings.template.hasSecondaryText, !settings.secondaryText.isEmpty {
            attributes[.font] = font(settings.font, weight: .regular, size: fontSize * 0.65)
            text.append(NSAttributedString(string: "\n" + settings.secondaryText, attributes: attributes))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                 CGSize(width: textWidth, height: 1_000_000), nil)
        let textHeight = min(ceil(needed.height) + 2, available.height)
        let x: Double
        switch settings.position {
        case .topLeft, .centerLeft, .bottomLeft: x = available.minX
        case .topRight, .centerRight, .bottomRight: x = available.maxX - textWidth
        default: x = available.midX - textWidth / 2
        }
        let y: Double
        switch settings.position {
        case .topLeft, .topCenter, .topRight: y = available.maxY - textHeight
        case .bottomLeft, .bottomCenter, .bottomRight: y = available.minY
        default: y = available.midY - textHeight / 2
        }
        let rect = CGRect(x: x + width * settings.horizontalOffset / 100,
                          y: y - height * settings.verticalOffset / 100, width: textWidth, height: textHeight)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        var bounds = CGRect.null
        for (line, origin) in zip(lines, origins) {
            let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            if !lineBounds.isEmpty {
                bounds = bounds.union(lineBounds.offsetBy(dx: origin.x + rect.minX, dy: origin.y + rect.minY))
            }
        }
        let painted = bounds.isNull ? rect : bounds.insetBy(dx: -decorationPadding, dy: -decorationPadding)
        let visible = CTFrameGetVisibleStringRange(frame)
        let fits = visible.location + visible.length == text.length && needed.height <= available.height &&
            safe.insetBy(dx: -0.5, dy: -0.5).contains(painted)
        var warnings: [String] = []
        if fontSize < 16 { warnings.append("The main text is smaller than 16 pixels in this project and may be difficult to read.") }
        if settings.background == .black && !settings.panelEnabled && !settings.outlineEnabled,
           contrast(settings.color, against: TextGeneratorColor(choice: .black)) < 4.5 {
            warnings.append("Text contrast against the black background is low.")
        } else if settings.panelEnabled && settings.panelOpacity == 100 && !settings.outlineEnabled,
                  contrast(settings.color, against: settings.panelColor) < 4.5 {
            warnings.append("Text contrast against the backing panel is low.")
        }
        return Layout(frame: frame, lineCount: lines.count, textBounds: bounds, paintedBounds: painted,
                      fits: fits, fontSize: fontSize, warnings: warnings)
    }

    static func image(_ definition: GeneratorDefinition) throws -> CGImage {
        let layout = try layout(definition)
        guard layout.fits else { throw MediaSourceError.unreadable(layout.report) }
        let settings = definition.textSettings
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: definition.width, height: definition.height,
                                      bitsPerComponent: 8, bytesPerRow: definition.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaSourceError.unreadable("The text image could not be created.")
        }
        let canvas = CGRect(x: 0, y: 0, width: definition.width, height: definition.height)
        context.clear(canvas)
        if settings.background == .black {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(canvas)
        }
        if settings.panelEnabled, !layout.textBounds.isNull {
            context.setFillColor(nsColor(settings.panelColor).withAlphaComponent(settings.panelOpacity / 100).cgColor)
            context.fill(layout.textBounds.insetBy(dx: -layout.fontSize * 0.3, dy: -layout.fontSize * 0.3))
        }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false) // Grayscale edges, without screen subpixel color fringes.
        if settings.shadowEnabled {
            context.setShadow(offset: CGSize(width: layout.fontSize * 0.04, height: -layout.fontSize * 0.04),
                              blur: layout.fontSize * 0.06, color: CGColor(gray: 0, alpha: 0.7))
        }
        context.textMatrix = .identity
        CTFrameDraw(layout.frame, context)
        guard let image = context.makeImage() else { throw MediaSourceError.unreadable("The text image could not be created.") }
        return image
    }

    static func writePNG(_ definition: GeneratorDefinition, to url: URL) throws {
        let image = try image(definition)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaSourceError.unreadable("The text image could not be saved.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaSourceError.unreadable("The text image could not be saved.") }
    }

    static func writeRGBA(_ definition: GeneratorDefinition, to url: URL) throws {
        let image = try image(definition)
        guard let source = image.dataProvider?.data, let bytes = CFDataGetBytePtr(source) else {
            throw MediaSourceError.unreadable("The text pixels could not be read.")
        }
        var rgba = Data(count: definition.width * definition.height * 4)
        try rgba.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            for y in 0..<definition.height {
                try Task.checkCancellation()
                for x in 0..<definition.width {
                    let input = y * image.bytesPerRow + x * 4
                    let output = (y * definition.width + x) * 4
                    let alpha = Int(bytes[input + 3])
                    destination[output + 3] = UInt8(alpha)
                    // Core Graphics draws premultiplied pixels; FFmpeg's rgba input is straight.
                    // Undo premultiplication before encoding to avoid dark letter edges.
                    for channel in 0..<3 {
                        destination[output + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(bytes[input + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        try Task.checkCancellation()
        try rgba.write(to: url)
    }

    private static func font(_ family: TextFontFamily, weight: TextFontWeight, size: Double) -> NSFont {
        let nativeWeight: NSFont.Weight = switch weight { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
        let base = NSFont.systemFont(ofSize: size, weight: nativeWeight)
        let design: NSFontDescriptor.SystemDesign = switch family { case .sans: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    private static func nsColor(_ color: TextGeneratorColor) -> NSColor {
        let (red, green, blue) = color.rgb ?? (1, 1, 1)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func contrast(_ a: TextGeneratorColor, against b: TextGeneratorColor) -> Double {
        func luminance(_ color: TextGeneratorColor) -> Double {
            let (r, g, b) = color.rgb ?? (1, 1, 1)
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let a = luminance(a), b = luminance(b)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
