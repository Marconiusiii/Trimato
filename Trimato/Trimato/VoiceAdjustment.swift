import AVFoundation
import Foundation

nonisolated struct VoiceAdjustment: Codable, Hashable, Sendable {
    var targetLoudness: Double?
    var referenceStart = 0.0
    var referenceEnd = 5.0
    var evenOut = false
    var level = 0.0
    // Optional preserves decoding of projects saved before this control existed.
    var smoothingAmount: Double?
    var effectiveSmoothingAmount: Double { smoothingAmount ?? 50 }

    // Missing bypass flags keep older projects enabled.
    var matchingBypassed: Bool?
    var smoothingBypassed: Bool?
    var matchingActive: Bool { targetLoudness != nil && matchingBypassed != true }
    var smoothingActive: Bool { evenOut && smoothingBypassed != true }
    var isActive: Bool { matchingActive || smoothingActive || level != 0 }

    func validate() throws {
        guard effectiveSmoothingAmount.isFinite, (0...100).contains(effectiveSmoothingAmount) else {
            throw AudioCaptureError.message("Use a smoothing amount between 0 and 100 percent.")
        }
        guard level.isFinite, (-12...12).contains(level),
              targetLoudness.map({ $0.isFinite && (-60 ... -5).contains($0) }) ?? true else {
            throw AudioCaptureError.message("Use a voice level between −12 and 12 dB and a usable dialogue reference.")
        }
    }
}

/// Measures the audible edit but preserves source timing for timeline placement.
/// Originals are never overwritten. Callers own all returned files.
nonisolated enum VoiceAudioProcessor {
    @concurrent
    static func measure(_ url: URL, segments: [SourceSegment]? = nil) async throws -> Double {
        let selection = try selectionGraph(segments)
        let graph = selection + "loudnorm=I=-23:TP=-1:dual_mono=true:print_format=json[out]"
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-i", url.path, "-filter_complex", graph,
            "-map", "[out]", "-f", "null", "-"
        ])
        return try loudness(from: result.standardError)
    }

    static func loudness(from diagnostics: String) throws -> Double {
        guard let start = diagnostics.range(of: "{", options: .backwards),
              let end = diagnostics[start.lowerBound...].firstIndex(of: "}"),
              let data = String(diagnostics[start.lowerBound...end]).data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let text = values["input_i"], let value = Double(text),
              value.isFinite, (-60 ... -5).contains(value) else {
            throw AudioCaptureError.message("This audio is silent, too short, or outside the usable voice level range. Choose a longer passage of clear dialogue or record a clearer take. Existing adjustments have been kept.")
        }
        return value
    }

    static func selectionGraph(_ segments: [SourceSegment]?) throws -> String {
        guard let segments else { return "[0:a:0]" }
        guard !segments.isEmpty, segments.allSatisfy({
            $0.sourceRange.start.seconds.isFinite && $0.sourceRange.start.seconds >= 0 &&
            $0.duration.seconds.isFinite && $0.duration.seconds > 0
        }) else { throw AudioCaptureError.message("Choose a nonempty audio range.") }
        let splits = segments.indices.map { "[v\($0)]" }.joined()
        var graph = "[0:a:0]asplit=\(segments.count)\(splits);"
        for (index, segment) in segments.enumerated() {
            graph += "[v\(index)]atrim=start=\(segment.sourceRange.start.seconds):end=\(segment.sourceRange.end.seconds),asetpts=PTS-STARTPTS[s\(index)];"
        }
        return graph + segments.indices.map { "[s\($0)]" }.joined() + "concat=n=\(segments.count):v=0:a=1,"
    }

    @concurrent
    static func render(source: URL, settings: VoiceAdjustment, segments: [SourceSegment]?, trimOutput: Bool) async throws -> URL {
        try settings.validate()
        var intermediate: URL?
        defer { if let intermediate { try? FileManager.default.removeItem(at: intermediate) } }
        var input = source
        if settings.smoothingActive {
            let originalLevel = try await measure(source, segments: segments)
            let preparationGain = -23 - originalLevel
            let ratio = 1 + effectiveRatio(settings.effectiveSmoothingAmount)
            input = try await process(source: source, graph: "[0:a:0]volume=\(preparationGain)dB,acompressor=threshold=0.063096:ratio=\(ratio):attack=20:release=250:makeup=1,volume=\(-preparationGain)dB[out]")
            intermediate = input
        }
        var gain = settings.level
        if settings.matchingActive, let target = settings.targetLoudness {
            let measured = try await measure(input, segments: segments)
            let correction = target - measured
            guard abs(correction) <= 24 else {
                throw AudioCaptureError.message("Matching this take would require an excessive volume change. Choose a more representative dialogue passage or adjust the recording level and try again.")
            }
            gain += correction
        }
        // Oversample the limiter and compensate its lookahead so timing stays intact.
        let graph = "[0:a:0]volume=\(gain)dB,aresample=192000,alimiter=limit=0.891251:level=false:latency=true,aresample=48000[out]"
        let output = try await process(source: input, graph: graph)
        guard trimOutput, let segments else { return output }
        defer { try? FileManager.default.removeItem(at: output) }
        return try await process(source: output, graph: selectionGraph(segments) + "anull[out]")
    }

    static func effectiveRatio(_ amount: Double) -> Double { min(max(amount, 0), 100) * 0.04 }

    @concurrent
    private static func process(source: URL, graph: String) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-voice-\(UUID()).wav")
        do {
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
                "-hide_banner", "-nostdin", "-y", "-i", source.path, "-filter_complex", graph,
                "-map", "[out]", "-c:a", "pcm_f32le", "-ar", "48000", output.path
            ])
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

nonisolated enum VoiceReferenceAudio {
    static func showOnly(_ project: TrimatoProject) -> TrimatoProject {
        var result = project
        let narration = Set(project.media.filter { [.audioDescription, .voiceOver].contains($0.recordingPurpose) }.map(\.id))
        for index in result.tracks.indices { result.tracks[index].clips.removeAll { narration.contains($0.assetID) } }
        let remaining = Set(result.tracks.flatMap(\.clips).map(\.id))
        result.transitions.removeAll {
            ($0.leadingClipID.map { !remaining.contains($0) } ?? false) ||
            ($0.trailingClipID.map { !remaining.contains($0) } ?? false)
        }
        result.descriptionDucking.enabled = false
        result.synchronizeTracksToLegacyTimeline()
        return result
    }

    @concurrent
    static func render(project: TrimatoProject, urls: [UUID: URL], start: Double, end: Double) async throws -> URL {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.4,
              end <= project.duration.seconds else {
            throw AudioCaptureError.message("Choose a dialogue reference of at least 0.4 seconds within Primary Audio. Several seconds of clear dialogue give a more useful match.")
        }
        let result = try await ProjectCompositionBuilder.build(project: showOnly(project), mediaURLs: urls)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-reference-\(UUID()).wav")
        do {
            try await AudioOnlyExporter.export(asset: result.composition, audioMix: result.audioMix,
                timeRange: CMTimeRange(start: ProjectTime(seconds: start).cmTime, duration: ProjectTime(seconds: end - start).cmTime),
                format: .wav24, to: output, progress: { _ in })
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

extension Optional where Wrapped == RecordingPurpose {
    var isNarration: Bool { self == .audioDescription || self == .voiceOver }
}

extension TrimatoProject {
    mutating func setTrackVoice(_ trackID: UUID, settings: VoiceAdjustment) throws {
        try settings.validate()
        guard let index = tracks.firstIndex(where: { $0.id == trackID && $0.kind == .audio }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let ids = Set(media.filter { $0.recordingPurpose.isNarration }.map(\.id))
        for clip in tracks[index].clips.indices where ids.contains(tracks[index].clips[clip].assetID) {
            tracks[index].clips[clip].audioSettings.voice = settings
        }
        synchronizeTracksToLegacyTimeline()
    }

    func recordingDestination(purpose: RecordingPurpose, start: ProjectTime, duration: ProjectTime) -> TimelineTrack? {
        tracks.first { track in
            track.kind == .audio && track.recordingPurpose == purpose && !track.clips.contains {
                max($0.timelineStart, start) < min($0.timelineEnd, start + duration)
            }
        }
    }
}
