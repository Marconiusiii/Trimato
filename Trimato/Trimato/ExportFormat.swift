import AppKit
import AVFoundation
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Equatable, Sendable {
    case original
    case h264MP4
    case hevcMovie
    case h264QuickTime
    case proRes422
    case m4a
    case wav

    static let projectFormats: [ExportFormat] = [
        .h264MP4, .hevcMovie, .h264QuickTime, .proRes422, .m4a, .wav,
    ]

    var title: String {
        switch self {
        case .original: "Original format"
        case .h264MP4: "MP4"
        case .hevcMovie: "HEVC movie"
        case .h264QuickTime: "QuickTime movie"
        case .proRes422: "ProRes 422 movie"
        case .m4a: "M4A audio"
        case .wav: "WAV audio"
        }
    }

    var fileExtension: String {
        switch self {
        case .original: ""
        case .h264MP4: "mp4"
        case .hevcMovie, .h264QuickTime, .proRes422: "mov"
        case .m4a: "m4a"
        case .wav: "wav"
        }
    }

    var contentType: UTType {
        switch self {
        case .original: .data
        case .h264MP4: .mpeg4Movie
        case .hevcMovie, .h264QuickTime, .proRes422: .quickTimeMovie
        case .m4a: UTType(filenameExtension: "m4a") ?? .audio
        case .wav: UTType(filenameExtension: "wav") ?? .audio
        }
    }

    var fileType: AVFileType? {
        switch self {
        case .original: nil
        case .h264MP4: .mp4
        case .hevcMovie, .h264QuickTime, .proRes422: .mov
        case .m4a: .m4a
        case .wav: .wav
        }
    }

    var exportPreset: String? {
        switch self {
        case .original, .wav: nil
        case .h264MP4, .h264QuickTime: AVAssetExportPresetHighestQuality
        case .hevcMovie: AVAssetExportPresetHEVCHighestQuality
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .m4a: AVAssetExportPresetAppleM4A
        }
    }

    var isAudioOnly: Bool {
        self == .m4a || self == .wav
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
