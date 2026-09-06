import Foundation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let subRipCaption = UTType(importedAs: "com.marconius.trimato.subrip-caption", conformingTo: .plainText)
    nonisolated static let webVTTCaption = UTType(importedAs: "org.w3.webvtt", conformingTo: .plainText)
}

nonisolated enum CaptionFileFormat: String, Codable, CaseIterable, Sendable {
    case subRip
    case webVTT

    var title: String { self == .subRip ? "SRT" : "WebVTT" }
    var fileExtension: String { self == .subRip ? "srt" : "vtt" }
    var contentType: UTType { self == .subRip ? .subRipCaption : .webVTTCaption }

    static func format(for url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "srt": .subRip
        case "vtt": .webVTT
        default: nil
        }
    }
}

nonisolated struct CaptionCue: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var start: ProjectTime
    var end: ProjectTime
    var text: String
    var identifier: String?
    var webVTTSettings: String?
    var isDraft = false

    init(
        id: UUID = UUID(),
        start: ProjectTime,
        end: ProjectTime,
        text: String,
        identifier: String? = nil,
        webVTTSettings: String? = nil,
        isDraft: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.identifier = identifier
        self.webVTTSettings = webVTTSettings
        self.isDraft = isDraft
    }

    var duration: ProjectTime { end - start }

    var firstLine: String {
        text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? "Untitled caption"
    }

    var displayName: String { "Caption: \(firstLine)" }

    func validated() throws -> Self {
        guard start >= .zero else {
            throw CaptionFileError.invalidCue("A caption cannot begin before the start of the project.")
        }
        guard end > start else {
            throw CaptionFileError.invalidCue("A caption must end after it begins.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptionFileError.invalidCue("Enter caption text.")
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, text, identifier, webVTTSettings, isDraft
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(ProjectTime.self, forKey: .start)
        end = try values.decode(ProjectTime.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        webVTTSettings = try values.decodeIfPresent(String.self, forKey: .webVTTSettings)
        isDraft = try values.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    }
}

nonisolated enum CaptionFileError: LocalizedError, Equatable {
    case unsupportedFormat
    case unreadableText
    case noCues
    case malformedCue(Int, String)
    case invalidCue(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Choose an SRT or WebVTT caption file."
        case .unreadableText: "The caption file is not valid UTF-8 or UTF-16 text."
        case .noCues: "The caption file does not contain any usable caption cues."
        case .malformedCue(let number, let detail): "Caption \(number) could not be read. \(detail)"
        case .invalidCue(let detail): detail
        }
    }
}

nonisolated extension TrimatoProject {
    var nonCaptionDuration: ProjectTime {
        tracks.filter { $0.kind != .captions }.map(\.end).max() ?? .zero
    }

    @discardableResult
    mutating func ensureCaptionTrack() -> UUID {
        if let track = captionTrack { return track.id }
        let track = TimelineTrack(name: "Captions", kind: .captions)
        tracks.append(track)
        return track.id
    }

    mutating func addCaptionCues(_ cues: [CaptionCue]) throws {
        let validated = try cues.map { try $0.validated() }
        guard !validated.isEmpty else { throw CaptionFileError.noCues }
        let trackID = ensureCaptionTrack()
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].captionCues.append(contentsOf: validated)
    }

    mutating func updateCaptionCue(_ cue: CaptionCue) throws {
        let cue = try cue.validated()
        guard let trackIndex = tracks.firstIndex(where: { track in
            track.captionCues.contains { $0.id == cue.id }
        }), let cueIndex = tracks[trackIndex].captionCues.firstIndex(where: { $0.id == cue.id }) else {
            throw CaptionFileError.invalidCue("The caption is no longer in the project.")
        }
        tracks[trackIndex].captionCues[cueIndex] = cue
    }

    mutating func removeCaptionCue(id: UUID) throws {
        guard let trackIndex = tracks.firstIndex(where: { track in
            track.captionCues.contains { $0.id == id }
        }) else { throw CaptionFileError.invalidCue("The caption is no longer in the project.") }
        tracks[trackIndex].captionCues.removeAll { $0.id == id }
    }

    mutating func replaceCaptionCues(_ cues: [CaptionCue]) throws {
        let validated = try cues.map { try $0.validated() }
        guard let index = tracks.firstIndex(where: { $0.kind == .captions }) else {
            throw CaptionFileError.invalidCue("The caption track is no longer in the project.")
        }
        tracks[index].captionCues = validated
    }
}
