import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Equatable, Sendable {
    case original
    case h264MP4
    case hevcMP4
    case hevcMovie
    case h264QuickTime
    case proRes422LT
    case proRes422
    case proRes422HQ
    case m4a
    case m4aAppleLossless
    case flac
    case wav
    case wav24

    static let projectFormats: [ExportFormat] = [
        .h264MP4, .hevcMP4, .h264QuickTime, .hevcMovie,
        .proRes422LT, .proRes422, .proRes422HQ,
        .m4a, .m4aAppleLossless, .flac, .wav, .wav24,
    ]

    var title: String {
        switch self {
        case .original: "Original format"
        case .h264MP4: "H.264 MP4"
        case .hevcMP4: "HEVC MP4"
        case .hevcMovie: "HEVC movie"
        case .h264QuickTime: "H.264 QuickTime movie"
        case .proRes422LT: "ProRes 422 LT movie"
        case .proRes422: "ProRes 422 movie"
        case .proRes422HQ: "ProRes 422 HQ movie"
        case .m4a: "M4A AAC audio"
        case .m4aAppleLossless: "M4A Apple Lossless audio"
        case .flac: "FLAC audio"
        case .wav: "WAV audio, 16-bit"
        case .wav24: "WAV audio, 24-bit"
        }
    }

    var fileExtension: String {
        switch self {
        case .original: ""
        case .h264MP4, .hevcMP4: "mp4"
        case .hevcMovie, .h264QuickTime, .proRes422LT, .proRes422, .proRes422HQ: "mov"
        case .m4a, .m4aAppleLossless: "m4a"
        case .flac: "flac"
        case .wav, .wav24: "wav"
        }
    }

    var contentType: UTType {
        switch self {
        case .original: .data
        case .h264MP4, .hevcMP4: .mpeg4Movie
        case .hevcMovie, .h264QuickTime, .proRes422LT, .proRes422, .proRes422HQ: .quickTimeMovie
        case .m4a, .m4aAppleLossless: UTType(filenameExtension: "m4a") ?? .audio
        case .flac: UTType(filenameExtension: "flac") ?? .audio
        case .wav, .wav24: UTType(filenameExtension: "wav") ?? .audio
        }
    }

    var fileType: AVFileType? {
        switch self {
        case .original: nil
        case .h264MP4, .hevcMP4: .mp4
        case .hevcMovie, .h264QuickTime, .proRes422LT, .proRes422, .proRes422HQ: .mov
        case .m4a, .m4aAppleLossless: .m4a
        case .flac: AVFileType(rawValue: "org.xiph.flac")
        case .wav, .wav24: .wav
        }
    }

    var exportPreset: String? {
        switch self {
        case .original, .proRes422LT, .proRes422HQ,
             .m4a, .m4aAppleLossless, .flac, .wav, .wav24: nil
        case .h264MP4, .h264QuickTime: AVAssetExportPresetHighestQuality
        case .hevcMP4, .hevcMovie: AVAssetExportPresetHEVCHighestQuality
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        }
    }

    var isAudioOnly: Bool {
        switch self {
        case .m4a, .m4aAppleLossless, .flac, .wav, .wav24: true
        default: false
        }
    }

    var requiresCustomVideoWriter: Bool {
        self == .proRes422LT || self == .proRes422HQ
    }

    var supportsFastStart: Bool {
        switch self {
        case .h264MP4, .hevcMP4, .h264QuickTime, .hevcMovie, .m4a, .m4aAppleLossless: true
        default: false
        }
    }

    func filename(for baseName: String, originalExtension: String? = nil) -> String {
        let outputExtension = self == .original ? (originalExtension ?? "") : fileExtension
        return outputExtension.isEmpty ? baseName : "\(baseName).\(outputExtension)"
    }
}

struct ExportSaveSelection {
    let format: ExportFormat
    let url: URL
    let captionDelivery: CaptionDelivery
}

nonisolated enum CaptionDelivery: String, CaseIterable, Identifiable, Sendable {
    case burnedIn
    case webVTT
    case subRip
    case none

    var id: Self { self }
    var title: String {
        switch self {
        case .burnedIn: "Burn Captions into Video"
        case .webVTT: "WebVTT Sidecar File"
        case .subRip: "SRT Sidecar File"
        case .none: "No Captions"
        }
    }
    var sidecarFormat: CaptionFileFormat? {
        switch self {
        case .webVTT: .webVTT
        case .subRip: .subRip
        default: nil
        }
    }
}

@MainActor
final class ExportFormatSelectionModel: ObservableObject {
    nonisolated static let pickerLabel = "Format"

    @Published var selectedFormat: ExportFormat {
        didSet {
            if selectedFormat.isAudioOnly, captionDelivery == .burnedIn {
                captionDelivery = .webVTT
            }
            formatChanged?(selectedFormat)
        }
    }
    @Published var captionDelivery: CaptionDelivery
    let hasCaptions: Bool

    fileprivate var formatChanged: ((ExportFormat) -> Void)?

    init(selectedFormat: ExportFormat, hasCaptions: Bool) {
        self.selectedFormat = selectedFormat
        self.captionDelivery = selectedFormat.isAudioOnly ? .webVTT : .burnedIn
        self.hasCaptions = hasCaptions
    }
}

private struct ExportFormatAccessoryView: View {
    @ObservedObject var model: ExportFormatSelectionModel
    let formats: [ExportFormat]

    var body: some View {
        VStack {
            Picker(ExportFormatSelectionModel.pickerLabel, selection: $model.selectedFormat) {
                ForEach(formats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .frame(width: 330)
            if model.hasCaptions {
                Picker("Captions", selection: $model.captionDelivery) {
                    ForEach(CaptionDelivery.allCases) { delivery in
                        Text(delivery.title).tag(delivery)
                            .disabled(delivery == .burnedIn && model.selectedFormat.isAudioOnly)
                    }
                }
                .frame(width: 330)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class ExportSavePanel {
    let panel = NSSavePanel()
    let formatModel: ExportFormatSelectionModel

    private let formats: [ExportFormat]
    private let originalExtension: String?
    private let originalContentType: UTType?

    init(
        title: String,
        baseName: String,
        formats: [ExportFormat],
        hasCaptions: Bool = false,
        originalExtension: String? = nil,
        originalContentType: UTType? = nil
    ) {
        precondition(!formats.isEmpty)
        self.formats = formats
        self.originalExtension = originalExtension
        self.originalContentType = originalContentType
        self.formatModel = ExportFormatSelectionModel(selectedFormat: formats[0], hasCaptions: hasCaptions)

        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false

        let accessory = NSHostingView(rootView: ExportFormatAccessoryView(
            model: formatModel,
            formats: formats
        ))
        accessory.frame = NSRect(x: 0, y: 0, width: 330, height: hasCaptions ? 74 : 36)
        panel.accessoryView = accessory

        panel.nameFieldStringValue = formats[0].filename(
            for: baseName,
            originalExtension: originalExtension
        )
        apply(format: formats[0], replacingFilenameExtension: false)
        formatModel.formatChanged = { [weak self] format in
            self?.apply(format: format, replacingFilenameExtension: true)
        }
    }

    func selection(parentWindow: NSWindow) async -> ExportSaveSelection? {
        let response = await panel.beginSheetModal(for: parentWindow)
        panel.orderOut(nil)
        guard response == .OK, let url = panel.url else { return nil }
        return ExportSaveSelection(
            format: selectedFormat,
            url: url,
            captionDelivery: formatModel.hasCaptions ? formatModel.captionDelivery : .none
        )
    }

    var selectedFormat: ExportFormat {
        formatModel.selectedFormat
    }

    func applySelectedFormat() {
        apply(format: selectedFormat, replacingFilenameExtension: true)
    }

    private func apply(format: ExportFormat, replacingFilenameExtension: Bool) {
        panel.allowedContentTypes = [contentType(for: format)]
        guard replacingFilenameExtension else { return }
        let currentName = panel.nameFieldStringValue
        let baseName = URL(fileURLWithPath: currentName)
            .deletingPathExtension()
            .lastPathComponent
        panel.nameFieldStringValue = format.filename(
            for: baseName,
            originalExtension: originalExtension
        )
    }

    private func contentType(for format: ExportFormat) -> UTType {
        if format == .original { return originalContentType ?? .data }
        return format.contentType
    }
}

@MainActor
final class CaptionExportSavePanel {
    enum Format: CaseIterable {
        case webVTT
        case subRip
        case plainText

        var title: String {
            switch self {
            case .webVTT: "WebVTT"
            case .subRip: "SRT"
            case .plainText: "Plain Text"
            }
        }

        var fileExtension: String {
            switch self {
            case .webVTT: "vtt"
            case .subRip: "srt"
            case .plainText: "txt"
            }
        }

        var contentType: UTType {
            switch self {
            case .webVTT: .webVTTCaption
            case .subRip: .subRipCaption
            case .plainText: .plainText
            }
        }

        var captionFileFormat: CaptionFileFormat? {
            switch self {
            case .webVTT: .webVTT
            case .subRip: .subRip
            case .plainText: nil
            }
        }
    }

    private let panel = NSSavePanel()
    private let formatPicker = NSPopUpButton()

    init(baseName: String) {
        panel.title = "Export Captions"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.nameFieldStringValue = "\(baseName).vtt"
        panel.allowedContentTypes = [.webVTTCaption]
        panel.isExtensionHidden = false
        formatPicker.addItems(withTitles: Format.allCases.map(\.title))
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged)
        let formatLabel = NSTextField(labelWithString: "Format")
        formatLabel.setAccessibilityElement(false)
        formatPicker.setAccessibilityTitleUIElement(formatLabel)
        let accessory = NSStackView(views: [formatLabel, formatPicker])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        panel.accessoryView = accessory
    }

    var selectedFormat: Format {
        Format.allCases[formatPicker.indexOfSelectedItem]
    }

    func selection(parentWindow: NSWindow) async -> (URL, Format)? {
        let response = await panel.beginSheetModal(for: parentWindow)
        panel.orderOut(nil)
        guard response == .OK, let url = panel.url else { return nil }
        return (url, selectedFormat)
    }

    @objc private func formatChanged() {
        let format = selectedFormat
        panel.allowedContentTypes = [format.contentType]
        let base = URL(fileURLWithPath: panel.nameFieldStringValue).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }
}
