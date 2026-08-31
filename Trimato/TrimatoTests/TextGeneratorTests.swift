import AVFoundation
import AppKit
import CoreText
import Testing
@testable import Trimato

@Suite(.serialized)
@MainActor
struct TextGeneratorTests {
    private func definition(_ template: TextTemplate = .lowerLeft, width: Int = 640, height: Int = 360) -> GeneratorDefinition {
        var value = GeneratorDefinition()
        value.kind = .text
        value.width = width
        value.height = height
        value.frameRate = 24
        value.duration = ProjectTime(seconds: 2)
        value.textSettings.apply(template)
        value.textSettings.text = "River walk"
        value.textSettings.secondaryText = "An afternoon outside"
        return value
    }

    @Test func savedTextAndOldGeneratorsRoundTrip() throws {
        var value = definition(.nameAndRole)
        value.textSettings.text = "O'Brien: 50% [title] \\ test\nCafé 東京"
        value.textSettings.color = TextGeneratorColor(choice: .custom, customHex: "#A1B2C3")
        let saved = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(GeneratorDefinition.self, from: saved) == value)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(GeneratorDefinition())) as? [String: Any])
        legacy.removeValue(forKey: "text")
        let reopened = try JSONDecoder().decode(GeneratorDefinition.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(reopened.kind == .black)
        #expect(reopened.text == nil)
        #expect(try GeneratorRenderer.cacheURL(for: value) != GeneratorRenderer.cacheURL(for: definition(.nameAndRole)))
    }

    @Test(arguments: TextTemplate.allCases, [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), CGSize(width: 480, height: 480)])
    func templatesFitAcrossProjectShapes(template: TextTemplate, size: CGSize) throws {
        let value = definition(template, width: Int(size.width), height: Int(size.height))
        let layout = try TextGeneratorRenderer.layout(value)
        #expect(layout.fits, "\(template.title): \(layout.report)")
        #expect(layout.lineCount > 0)
        _ = try TextGeneratorRenderer.image(value)
    }

    @Test func changingTemplateAndResettingStylePreserveText() {
        var value = definition(.titleAndSubtitle).textSettings
        let text = value.text, secondary = value.secondaryText
        for template in TextTemplate.allCases {
            value.apply(template)
            #expect(value.text == text)
            #expect(value.secondaryText == secondary)
        }
        value.apply(.lowerRight)
        #expect(value.position == .bottomRight)
        #expect(value.alignment == .right)
        #expect(value.background == .transparent)
    }

    @Test func rightJustificationAndManualLineBreaksReachTheSameRightEdge() throws {
        var value = definition(.lowerRight)
        value.textSettings.outlineEnabled = false
        value.textSettings.text = "A longer line\nShort"
        let layout = try TextGeneratorRenderer.layout(value)
        let lines = CTFrameGetLines(layout.frame) as! [CTLine]
        #expect(lines.count == 2)
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(layout.frame, CFRange(location: 0, length: 0), &origins)
        let ends = zip(lines, origins).map { CTLineGetTypographicBounds($0.0, nil, nil, nil) + $0.1.x }
        #expect(abs(ends[0] - ends[1]) < 1)
    }

    @Test func overflowAndInvalidSettingsCannotSilentlyRender() throws {
        var value = definition()
        value.textSettings.text = String(repeating: "A very long line of text.\n", count: 100)
        #expect(try !TextGeneratorRenderer.layout(value).fits)
        #expect(throws: (any Error).self) { try TextGeneratorRenderer.image(value) }
        value = definition()
        value.textSettings.position = .bottomRight
        value.textSettings.alignment = .right
        value.textSettings.horizontalOffset = 50
        #expect(try !TextGeneratorRenderer.layout(value).fits)
        value.textSettings.text = " "
        #expect(throws: (any Error).self) { try value.validate() }
        value = definition()
        value.textSettings.color = TextGeneratorColor(choice: .custom, customHex: "not-a-color")
        #expect(throws: (any Error).self) { try value.validate() }
    }

    @Test(arguments: TextFontFamily.allCases)
    func unicodeAndPunctuationRenderLiterally(font: TextFontFamily) throws {
        var value = definition(.centerTitle)
        value.textSettings.font = font
        value.textSettings.text = "Café 東京\nO'Brien: 50% [test] \\"
        #expect(try TextGeneratorRenderer.layout(value).lineCount >= 2)
        _ = try TextGeneratorRenderer.image(value)
    }

    @Test func nativeAndEncodedAlphaContainClearOpaqueAndAntialiasedPixels() async throws {
        var value = definition()
        value.textSettings.outlineEnabled = false
        let image = try TextGeneratorRenderer.image(value)
        let native = try rgba(image)
        let encoded = try await pixels(GeneratorRenderer.ensure(value))
        #expect(encoded.count == native.count)
        let nativeAlpha = stride(from: 3, to: native.count, by: 4).map { native[$0] }
        let encodedAlpha = stride(from: 3, to: encoded.count, by: 4).map { encoded[$0] }
        #expect(nativeAlpha.contains(0) && nativeAlpha.contains(255))
        #expect(nativeAlpha.contains { $0 > 0 && $0 < 255 })
        #expect(zip(nativeAlpha, encodedAlpha).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        #expect(encoded[3] == 0)
        // PNG and ProRes must contain straight white color at partially transparent letter edges.
        let edges = stride(from: 0, to: encoded.count, by: 4).filter { encoded[$0 + 3] > 30 && encoded[$0 + 3] < 220 }
        #expect(!edges.isEmpty)
        #expect(edges.allSatisfy { encoded[$0] > 235 && encoded[$0 + 1] > 235 && encoded[$0 + 2] > 235 })
        value.textSettings.background = .black
        let opaque = try await pixels(GeneratorRenderer.ensure(value))
        #expect(stride(from: 3, to: opaque.count, by: 4).allSatisfy { opaque[$0] == 255 })
    }

    @Test(arguments: ClipFilterKind.allCases.filter { !$0.isAudio })
    func everyVideoFilterPreservesTheAlphaMask(kind: ClipFilterKind) async throws {
        let value = definition(.caption)
        let source = try await GeneratorRenderer.ensure(value)
        let output = try await ClipFilterRenderer.render(source: source, filters: [ClipFilter(kind: kind)], audio: false, duration: 2)
        defer { try? FileManager.default.removeItem(at: output) }
        let original = try await pixels(source)
        let filtered = try await pixels(output)
        #expect(try await FFmpegMediaProbe.inspect(url: output).hasAlpha)
        #expect(original.count == filtered.count)
        let errors = stride(from: 3, to: original.count, by: 4).map { abs(Int(original[$0]) - Int(filtered[$0])) }
        #expect(errors.max() ?? 0 <= 2)
        if [.brightnessContrast, .colorAdjustment, .cropOrientation].contains(kind) {
            let a = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            let b = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let originalImage = try rgba(try await a.image(at: .zero).image)
            let filteredImage = try rgba(try await b.image(at: .zero).image)
            let difference = zip(originalImage, filteredImage).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(originalImage.count)
            #expect(difference < 3, "Neutral filtering must preserve the native decoded picture: \(difference)")
        }
    }

    @Test func customColorsPanelOpacityAndShadowSurviveEncoding() async throws {
        var value = definition(.caption)
        value.textSettings.sizePercent = 12
        value.textSettings.text = "Readable text"
        value.textSettings.color = TextGeneratorColor(choice: .custom, customHex: "40A0E0")
        value.textSettings.panelColor = TextGeneratorColor(choice: .custom, customHex: "224466")
        value.textSettings.panelOpacity = 70
        let data = try await pixels(GeneratorRenderer.ensure(value))
        let body = stride(from: 0, to: data.count, by: 4).filter { data[$0 + 3] == 255 }
        #expect(!body.isEmpty)
        let error = body.reduce(0.0) { sum, i in
            sum + abs(Double(data[i]) - 64) + abs(Double(data[i + 1]) - 160) + abs(Double(data[i + 2]) - 224)
        } / Double(body.count * 3)
        #expect(error < 7, "Custom text color must survive RGB/YUV conversion: \(error)")
        let panel = stride(from: 0, to: data.count, by: 4).filter { (178...180).contains(data[$0 + 3]) }
        #expect(panel.count > 100)
        #expect(panel.allSatisfy { abs(Int(data[$0]) - 34) < 8 && abs(Int(data[$0 + 1]) - 68) < 8 && abs(Int(data[$0 + 2]) - 102) < 8 })
        value.textSettings.panelEnabled = false
        let withoutShadow = try rgba(TextGeneratorRenderer.image(value))
        value.textSettings.shadowEnabled = true
        let withShadow = try rgba(TextGeneratorRenderer.image(value))
        let clearBefore = stride(from: 3, to: withoutShadow.count, by: 4).filter { withoutShadow[$0] == 0 }
        #expect(clearBefore.contains { withShadow[$0] > 0 })
        let encodedShadow = try await pixels(GeneratorRenderer.ensure(value))
        #expect(zip(stride(from: 3, to: withShadow.count, by: 4).map { withShadow[$0] },
                    stride(from: 3, to: encodedShadow.count, by: 4).map { encodedShadow[$0] }).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }

    @Test func cropRotationAndEditedSegmentsPreserveAlignedAlpha() async throws {
        let source = try await GeneratorRenderer.ensure(definition(.caption))
        var crop = ClipFilter(kind: .cropOrientation)
        crop.values = ["left": 10, "top": 6, "right": 10, "bottom": 6]
        crop.rotation = 90
        crop.flipHorizontal = true
        let output = try await ClipFilterRenderer.render(source: source, filters: [crop], audio: false, duration: 1,
            segments: [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.25), duration: ProjectTime(seconds: 0.5))),
                       SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 0.5)))])
        defer { try? FileManager.default.removeItem(at: output) }
        let report = try await FFmpegMediaProbe.inspect(url: output)
        #expect(report.hasAlpha)
        #expect(report.videoStream?.width == 348)
        #expect(report.videoStream?.height == 620)
        let expected = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-i", source.path, "-vf", "alphaextract,\(crop.graph)", "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"]).standardOutput
        let actual = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-i", output.path, "-vf", "alphaextract", "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"]).standardOutput
        #expect(expected.count == actual.count)
        #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }

    @Test(arguments: VideoTransitionType.allCases.filter { $0 != .fade })
    func betweenTransitionsKeepTransparentBackgroundsAndCleanEdges(type: VideoTransitionType) async throws {
        var leading = definition(.lowerLeft), trailing = definition(.lowerRight)
        leading.textSettings.outlineEnabled = false
        trailing.textSettings.outlineEnabled = false
        let a = try await GeneratorRenderer.ensure(leading), b = try await GeneratorRenderer.ensure(trailing)
        let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.5), duration: ProjectTime(seconds: 1)))]
        let first = TimelineClip(assetID: UUID(), name: "First", segments: segments)
        let second = TimelineClip(assetID: UUID(), name: "Second", segments: segments)
        let output = try await FFmpegTimelineEffectRenderer.renderVideoTransition(leadingURL: a, trailingURL: b,
            leadingClip: first, trailingClip: second, type: type, duration: ProjectTime(seconds: 1), width: 640, height: 360, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(try await FFmpegMediaProbe.inspect(url: output).hasAlpha)
        let middle = try await pixels(output, at: "0.5")
        #expect(middle[3] == 0)
        if type == .fadeOutIn {
            #expect(stride(from: 3, to: middle.count, by: 4).allSatisfy { middle[$0] < 3 })
        } else {
            if type == .crossDissolve { #expect((stride(from: 3, to: middle.count, by: 4).map { middle[$0] }.max() ?? 0) <= 130) }
            let visible = stride(from: 0, to: middle.count, by: 4).filter { middle[$0 + 3] > 100 }
            if type == .crossDissolve { #expect(!visible.isEmpty) }
            #expect(visible.allSatisfy { middle[$0] > 235 && middle[$0 + 1] > 235 && middle[$0 + 2] > 235 })
        }
    }

    @Test(arguments: [VideoTransitionType.crossDissolve, .fadeOutIn])
    func textTransitionReplacesItsSourceAndStaysBelowHigherTracks(type: VideoTransitionType) async throws {
        var base = GeneratorDefinition()
        base.kind = .solidColor; base.color = .red
        base.width = 640; base.height = 360; base.duration = ProjectTime(seconds: 2)
        let background = base.assetRecord()
        var leading = definition(.lowerLeft), trailing = definition(.lowerRight)
        leading.textSettings.outlineEnabled = false; trailing.textSettings.outlineEnabled = false
        let a = leading.assetRecord(), b = trailing.assetRecord()
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 640, height: 360, frameRate: 24)
        project.media = [background, a, b]
        _ = try project.append(asset: background)
        let track = project.createTrack(kind: .video)
        let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.5), duration: ProjectTime(seconds: 1)))]
        let first = try project.append(asset: a, segments: segments, toTrack: track)
        let second = try project.append(asset: b, segments: segments, toTrack: track)
        try project.addTransition(TimelineTransition(trackID: track, edge: .between, kind: .video(type), duration: ProjectTime(seconds: 1), leadingClipID: first, trailingClipID: second))
        func frame(_ project: TrimatoProject, at seconds: Double = 1) async throws -> Data {
            let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [:])
            defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
            let image = AVAssetImageGenerator(asset: result.composition)
            image.videoComposition = result.videoComposition
            image.requestedTimeToleranceBefore = .zero; image.requestedTimeToleranceAfter = .zero
            let cg = try await image.image(at: CMTime(seconds: seconds, preferredTimescale: 60000)).image
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TrimatoTextVerification", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writePNG(cg, to: folder.appendingPathComponent("\(type.rawValue)-\(project.tracks.count)-\(seconds).png"))
            return try rgba(cg)
        }
        let dissolved = try await frame(project, at: type == .fadeOutIn ? 0.75 : 1)
        let original = try await pixels(GeneratorRenderer.ensure(leading))
        let white = stride(from: 0, to: original.count, by: 4).filter { original[$0 + 3] > 250 && original[$0 + 1] > 245 }
        var reference = TrimatoProject()
        reference.format = project.format
        reference.media = [background, a]
        _ = try reference.append(asset: background)
        let referenceTrack = reference.createTrack(kind: .video)
        let referenceClip = try reference.append(asset: a, toTrack: referenceTrack)
        try reference.addTransition(TimelineTransition(trackID: referenceTrack, edge: .intro, kind: .video(.fade), duration: ProjectTime(seconds: 1.5), trailingClipID: referenceClip))
        let halfOpacity = try await frame(reference, at: 0.75)
        let difference = white.reduce(0.0) { $0 + abs(Double(dissolved[$1 + 1]) - Double(halfOpacity[$1 + 1])) } / Double(white.count)
        #expect(difference < 8, "The original clip must not appear below its dissolve: \(difference)")
        var cover = base; cover.color = .blue
        let coverAsset = cover.assetRecord()
        project.media.append(coverAsset)
        let top = project.createTrack(kind: .video)
        _ = try project.append(asset: coverAsset, toTrack: top)
        let covered = try await frame(project)
        #expect(white.allSatisfy { covered[$0 + 2] > 230 && covered[$0] < 25 && covered[$0 + 1] < 25 })
    }

    @Test func transparentTextAndIndependentFadesMatchPreviewAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrimatoTextVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain these small fixtures for visual inspection of the actual application render path.
        print("Text verification images: \(directory.path)")
        let moving = directory.appendingPathComponent("moving.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=24", "-t", "2", "-c:v", "prores_ks", "-profile:v", "1", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", moving.path])
        var baseDefinition = GeneratorDefinition()
        baseDefinition.width = 640; baseDefinition.height = 360; baseDefinition.duration = ProjectTime(seconds: 2)
        var base = baseDefinition.assetRecord()
        base.generator = nil; base.originalPath = moving.path
        var text = definition(.caption)
        text.textSettings.sizePercent = 8
        text.textSettings.text = "An afternoon outside"
        let overlay = text.assetRecord()
        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 640, height: 360, frameRate: 24)
        project.media = [base, overlay]
        _ = try project.append(asset: base)
        let backgroundProject = project
        let track = project.createTrack(kind: .video)
        let clip = try project.append(asset: overlay, toTrack: track)
        try project.addTransition(TimelineTransition(trackID: track, edge: .intro, kind: .video(.fade), duration: ProjectTime(seconds: 0.5), trailingClipID: clip))
        try project.addTransition(TimelineTransition(trackID: track, edge: .outro, kind: .video(.fade), duration: ProjectTime(seconds: 0.75), leadingClipID: clip))
        let urls = [base.id: moving]
        let preview = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        defer { for url in preview.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let generator = AVAssetImageGenerator(asset: preview.composition)
        generator.videoComposition = preview.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let export = directory.appendingPathComponent("text-over-moving-video.mp4")
        try await ProjectExporter.export(project: project, mediaURLs: urls, to: export, progress: { _ in })
        let flat = AVAssetImageGenerator(asset: AVURLAsset(url: export))
        flat.requestedTimeToleranceBefore = .zero; flat.requestedTimeToleranceAfter = .zero
        let backgroundResult = try await ProjectCompositionBuilder.build(project: backgroundProject, mediaURLs: urls)
        defer { for url in backgroundResult.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let background = AVAssetImageGenerator(asset: backgroundResult.composition)
        background.videoComposition = backgroundResult.videoComposition
        background.requestedTimeToleranceBefore = .zero; background.requestedTimeToleranceAfter = .zero
        let alpha = try await pixels(GeneratorRenderer.ensure(text))
        let ink = stride(from: 0, to: alpha.count, by: 4).filter { alpha[$0 + 3] == 255 && alpha[$0] > 245 }
        #expect(ink.count > 50)
        for seconds in [0.0, 0.25, 0.5, 1.25, 1.625, 47.0 / 24] {
            let time = CMTime(seconds: seconds, preferredTimescale: 60000)
            let image = try await generator.image(at: time).image
            let actual = try rgba(image)
            let encodedImage = try await flat.image(at: time).image
            let exported = try rgba(encodedImage)
            let beneath = try rgba(try await background.image(at: time).image)
            let fade = min(1, min(seconds / 0.5, (2 - seconds) / 0.75))
            let outside = stride(from: 0, to: alpha.count, by: 4).filter { alpha[$0 + 3] == 0 }
            let outsideDifference = outside.reduce(0.0) { sum, i in sum + abs(Double(actual[i]) - Double(beneath[i])) } / Double(outside.count)
            #expect(outsideDifference < 4, "Underlying video should remain visible outside text at \(seconds)")
            let inkError = ink.reduce(0.0) { sum, i in sum + abs(Double(actual[i]) - (Double(beneath[i]) * (1 - fade) + 255 * fade)) } / Double(ink.count)
            #expect(inkError < 12, "Fade opacity at \(seconds): \(inkError)")
            let exportError = zip(actual, exported).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(actual.count)
            #expect(exportError < 8, "Preview/export difference at \(seconds): \(exportError)")
            try writePNG(image, to: directory.appendingPathComponent("preview-\(seconds).png"))
            try writePNG(encodedImage, to: directory.appendingPathComponent("export-\(seconds).png"))
        }
        for template in TextTemplate.allCases {
            try TextGeneratorRenderer.writePNG(definition(template), to: directory.appendingPathComponent("template-\(template.rawValue).png"))
        }
    }

    private func pixels(_ url: URL, at time: String = "0") async throws -> Data {
        let report = try await FFmpegMediaProbe.inspect(url: url)
        let inputAlpha = report.hasAlpha && report.videoStream?.codecName == "prores" ? ["-alpha_mode", "premultiplied"] : []
        return try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-ss", time] + inputAlpha + ["-i", url.path, "-frames:v", "1", "-pix_fmt", "rgba", "-alpha_mode", "straight", "-f", "rawvideo", "pipe:1"]).standardOutput
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
