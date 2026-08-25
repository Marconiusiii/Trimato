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

@MainActor
enum ExportFormatChooser {
    static func choose(title: String, formats: [ExportFormat]) -> ExportFormat? {
        guard !formats.isEmpty else { return nil }

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 28), pullsDown: false)
        picker.addItems(withTitles: formats.map(\.title))
        picker.setAccessibilityLabel("Format")

        let label = NSTextField(labelWithString: "Format")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, picker])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 330, height: 32)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose a format."
        alert.accessoryView = row
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return formats[picker.indexOfSelectedItem]
    }
}
