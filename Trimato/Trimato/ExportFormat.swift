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

    var supportsHDR: Bool {
        [.original, .hevcMP4, .hevcMovie, .proRes422LT, .proRes422, .proRes422HQ].contains(self)
    }

    var supportsSpatialAudio: Bool {
        [.original, .hevcMovie, .h264QuickTime, .proRes422LT, .proRes422, .proRes422HQ].contains(self)
    }

    var requiresCustomVideoWriter: Bool {
        self == .proRes422LT || self == .proRes422 || self == .proRes422HQ
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
    var exportDescriptions = false
    var audioMode: ExportAudioMode = .preserveSpatial
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

nonisolated enum ExportAudioMode: String, CaseIterable, Identifiable, Sendable {
    case preserveSpatial, highQualityStereo
    var id: Self { self }
    var title: String { self == .preserveSpatial ? "Preserve Spatial Audio" : "High-quality Stereo" }
    static let preferenceKey = "exportAudioMode"
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .preserveSpatial }
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
    @Published var audioMode: ExportAudioMode = .highQualityStereo {
        didSet {
            if !availableFormats.contains(selectedFormat), let first = availableFormats.first { selectedFormat = first }
        }
    }
    var allFormats: [ExportFormat] = []
    var offersAudioChoice = false
    var spatialUnavailableReason: String?
    var availableFormats: [ExportFormat] {
        guard offersAudioChoice else { return allFormats }
        return allFormats.filter { audioMode == .preserveSpatial ? $0.supportsSpatialAudio : $0 != .original }
    }
    var audioSummary: String {
        if audioMode == .preserveSpatial { return "Keeps spatial sound and a stereo playback alternative. Audio changes use uncompressed audio and produce larger files." }
        switch selectedFormat {
        case .proRes422LT, .proRes422, .proRes422HQ, .wav24: return "Stereo with uncompressed 24-bit audio."
        case .wav: return "Stereo with uncompressed 16-bit audio. Choose 24-bit WAV for greater precision."
        case .m4aAppleLossless, .flac: return "Stereo with lossless audio encoding."
        default: return "Stereo with high-quality AAC audio. AAC uses lossy compression."
        }
    }
    @Published var captionDelivery: CaptionDelivery
    let hasCaptions: Bool
    let hasDescriptions: Bool
    let outputSummary: String?
    @Published var exportDescriptions = true

    fileprivate var formatChanged: ((ExportFormat) -> Void)?

    init(selectedFormat: ExportFormat, hasCaptions: Bool, hasDescriptions: Bool = false, outputSummary: String? = nil) {
        self.selectedFormat = selectedFormat
        self.captionDelivery = selectedFormat.isAudioOnly ? .webVTT : .burnedIn
        self.hasCaptions = hasCaptions
        self.outputSummary = outputSummary
        self.hasDescriptions = hasDescriptions
    }
}

private struct ExportFormatAccessoryView: View {
    @ObservedObject var model: ExportFormatSelectionModel
    let formats: [ExportFormat]

    var body: some View {
        VStack {
            Picker(ExportFormatSelectionModel.pickerLabel, selection: $model.selectedFormat) {
                ForEach(model.availableFormats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .frame(width: 330)
            if model.offersAudioChoice {
                Picker("Audio", selection: $model.audioMode) {
                    ForEach(ExportAudioMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(mode == .preserveSpatial && model.spatialUnavailableReason != nil)
                    }
                }.frame(width: 330)
                Text(model.audioSummary).frame(width: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let reason = model.spatialUnavailableReason {
                    Text(reason).frame(width: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.selectedFormat.isAudioOnly, let summary = model.outputSummary {
                Text(summary).frame(width: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if model.hasCaptions {
                Picker("Captions", selection: $model.captionDelivery) {
                    ForEach(CaptionDelivery.allCases) { delivery in
                        Text(delivery.title).tag(delivery)
                            .disabled(delivery == .burnedIn && model.selectedFormat.isAudioOnly)
                    }
                }
                .frame(width: 330)
            }
            if model.hasDescriptions {
                Toggle("Export description transcript (WebVTT)", isOn: $model.exportDescriptions)
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
        hasDescriptions: Bool = false,
        outputSummary: String? = nil,
        offersAudioChoice: Bool = false,
        spatialUnavailableReason: String? = nil,
        originalExtension: String? = nil,
        originalContentType: UTType? = nil
    ) {
        precondition(!formats.isEmpty)
        let outputSummary = outputSummary ?? (formats.contains { !$0.isAudioOnly && $0 != .original }
            ? "Converted exports do not include editable Cinematic focus information." : nil)
        self.formats = formats
        self.originalExtension = originalExtension
        self.originalContentType = originalContentType
        self.formatModel = ExportFormatSelectionModel(selectedFormat: formats[0], hasCaptions: hasCaptions, hasDescriptions: hasDescriptions, outputSummary: outputSummary)

        formatModel.allFormats = formats
        formatModel.offersAudioChoice = offersAudioChoice
        formatModel.spatialUnavailableReason = spatialUnavailableReason ?? (offersAudioChoice && !formats.contains(where: \.supportsSpatialAudio)
            ? "Spatial Audio export requires a QuickTime video format." : nil)
        if offersAudioChoice {
            formatModel.audioMode = formatModel.spatialUnavailableReason == nil ? .saved : .highQualityStereo
        }

        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false

        let accessory = NSHostingView(rootView: ExportFormatAccessoryView(
            model: formatModel,
            formats: formats
        ))
        accessory.frame = NSRect(x: 0, y: 0, width: 330, height: (hasCaptions ? 74 : 36) + (hasDescriptions ? 32 : 0) + (outputSummary == nil ? 0 : 110) + (offersAudioChoice ? 160 : 0) + (spatialUnavailableReason == nil ? 0 : 100))
        panel.accessoryView = accessory

        panel.nameFieldStringValue = formatModel.selectedFormat.filename(
            for: baseName,
            originalExtension: originalExtension
        )
        apply(format: formatModel.selectedFormat, replacingFilenameExtension: false)
        formatModel.formatChanged = { [weak self] format in
            self?.apply(format: format, replacingFilenameExtension: true)
        }
    }

    func selection(parentWindow: NSWindow) async -> ExportSaveSelection? {
        let response = await panel.beginSheetModal(for: parentWindow)
        guard response == .OK, let url = panel.url else { return nil }
        if formatModel.offersAudioChoice { UserDefaults.standard.set(formatModel.audioMode.rawValue, forKey: ExportAudioMode.preferenceKey) }
        return ExportSaveSelection(
            format: selectedFormat,
            url: url,
            captionDelivery: formatModel.hasCaptions ? formatModel.captionDelivery : .none,
            exportDescriptions: formatModel.hasDescriptions && formatModel.exportDescriptions,
            audioMode: formatModel.audioMode
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

    init(baseName: String, title: String = "Export Captions") {
        panel.title = title
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
