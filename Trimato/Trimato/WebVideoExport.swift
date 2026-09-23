import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PictureExportRequest: Identifiable {
    let id = UUID()
    let time: ProjectTime
    let range: ProjectTimeRange?
    let web: Bool
    let project: TrimatoProject
}

struct PictureExportSheet: View {
    @AppStorage(AppPreferenceKey.showMilliseconds) private var showMilliseconds = true
    let request: PictureExportRequest
    let cancel: () -> Void
    let export: (Bool, String) -> Void
    @State private var includeCaptions: Bool
    @State private var language = "en"
    init(request: PictureExportRequest, cancel: @escaping () -> Void, export: @escaping (Bool, String) -> Void) {
        self.request = request
        self.cancel = cancel
        self.export = export
        _includeCaptions = State(initialValue: request.web && request.project.captionTrack?.captionCues.isEmpty == false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.web ? "Export Web Video" : "Export Frame").font(.headline)
            LabeledContent(request.web ? "Poster frame" : "Frame", value: ProjectTimecodeFormatter.string(request.time, milliseconds: showMilliseconds))
            if request.project.captionTrack?.captionCues.isEmpty == false {
                Toggle("Include captions", isOn: $includeCaptions)
                if request.web && includeCaptions {
                    Picker("Caption language", selection: $language) {
                        ForEach(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).sorted(), id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Continue…") { export(includeCaptions, language) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }
}

nonisolated enum WebVideoMarkup {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func fragment(title: String, captions: Bool, language: String, languageName: String) -> String {
        let track = captions ? "\n    <track kind=\"captions\" src=\"captions.vtt\" srclang=\"\(escape(language))\" label=\"\(escape(languageName))\" default>" : ""
        return """
        <figure>
          <figcaption>\(escape(title))</figcaption>
          <video controls playsinline preload="metadata" poster="poster.png" style="max-width: 100%; height: auto;">
            <source src="video.mp4" type="video/mp4">\(track)
            <p>Your browser does not support HTML video.</p>
          </video>
          <p><a href="video.mp4">Download \(escape(title)).</a></p>
        </figure>
        """
    }
}

nonisolated enum ProjectFrameExporter {
    static func png(project: TrimatoProject, mediaURLs: [UUID: URL], at time: ProjectTime, captions: Bool) async throws -> Data {
        guard time >= .zero, time < project.duration else {
            throw MediaFileHandlingError(message: "Move the playhead to a frame inside the project, then export again.")
        }
        var picture = project
        for index in picture.tracks.indices where picture.tracks[index].kind == .captions { picture.tracks[index].captionCues = [] }
        let result = try await ProjectCompositionBuilder.build(project: picture, mediaURLs: mediaURLs,
            purpose: .finalExport, preserveHDR: false, audioMode: .highQualityStereo)
        defer { for url in result.temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) } }
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let generated = try await withTaskCancellationHandler {
            try await generator.image(at: time.cmTime)
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        let image = generated.image
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        if captions {
            for cue in project.captionTrack?.captionCues ?? [] where cue.start <= time && cue.end > time {
                var definition = GeneratorDefinition()
                definition.kind = .text
                definition.width = image.width
                definition.height = image.height
                definition.textSettings.apply(.caption)
                definition.textSettings.text = cue.text
                context.draw(try TextGeneratorRenderer.image(definition), in: bounds)
            }
        }
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
