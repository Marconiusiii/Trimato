import AppKit
import AVFoundation
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
}

@MainActor
final class ExportSavePanel: NSObject {
    let panel = NSSavePanel()
    let formatPicker = NSPopUpButton(
        frame: NSRect(x: 0, y: 0, width: 250, height: 28),
        pullsDown: false
    )
    let formatCaption = NSTextField(labelWithString: "Format")

    private let formats: [ExportFormat]
    private let originalExtension: String?
    private let originalContentType: UTType?

    init(
        title: String,
        baseName: String,
        formats: [ExportFormat],
        originalExtension: String? = nil,
        originalContentType: UTType? = nil
    ) {
        precondition(!formats.isEmpty)
        self.formats = formats
        self.originalExtension = originalExtension
        self.originalContentType = originalContentType
        super.init()

        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false

        formatPicker.addItems(withTitles: formats.map(\.title))
        formatPicker.setAccessibilityLabel("Format")
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged)

        formatCaption.alignment = .right
        formatCaption.setContentHuggingPriority(.required, for: .horizontal)
        formatCaption.setAccessibilityElement(false)

        let row = NSStackView(views: [formatCaption, formatPicker])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 330, height: 32)
        panel.accessoryView = row

        panel.nameFieldStringValue = formats[0].filename(
            for: baseName,
            originalExtension: originalExtension
        )
        apply(format: formats[0], replacingFilenameExtension: false)
    }

    func selection(parentWindow: NSWindow) async -> ExportSaveSelection? {
        let response = await panel.beginSheetModal(for: parentWindow)
        panel.orderOut(nil)
        guard response == .OK, let url = panel.url else { return nil }
        return ExportSaveSelection(format: selectedFormat, url: url)
    }

    var selectedFormat: ExportFormat {
        formats[formatPicker.indexOfSelectedItem]
    }

    @objc private func formatChanged() {
        applySelectedFormat()
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
