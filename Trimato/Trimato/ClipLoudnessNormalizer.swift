import Foundation

nonisolated enum ClipLoudnessNormalizer {
    static func graph(source: URL, preceding: [String], filter: ClipFilter, segments: [SourceSegment]?) async throws -> String {
        let base = filter.graph
        let prefix = preceding.isEmpty ? "anull" : preceding.joined(separator: ",")
        let selection = try VoiceAudioProcessor.selectionGraph(segments)
            .replacingOccurrences(of: "[0:a:0]", with: "[measured]")
        let analysis = "[0:a:0]" + prefix + "[measured];" + selection + base + ":print_format=json[out]"
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-i", source.path, "-map", "[out]",
            "-filter_complex", analysis, "-f", "null", "-"
        ])
        guard let start = result.standardError.range(of: "{", options: .backwards),
              let end = result.standardError[start.lowerBound...].firstIndex(of: "}"),
              let data = String(result.standardError[start.lowerBound...end]).data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw MediaSourceError.unreadable("The clip's loudness could not be measured.")
        }
        let keys = ["input_i", "input_tp"]
        // Silence has no finite loudness. Leave it silent without passing infinities to FFmpeg.
        if values["input_i"] == "-inf" { return "anull" }
        guard keys.allSatisfy({ Double(values[$0] ?? "").map(\.isFinite) == true }) else {
            throw MediaSourceError.unreadable("The clip's loudness could not be measured.")
        }
        // Apply one measured gain to the source so cuts and transition handles retain
        // their timing and dynamics. Stop short of the target if the selected true peak
        // needs more headroom. Discarded material never determines this correction.
        let gain = min(filter.value("target") - Double(values["input_i"]!)!,
                       filter.value("peak") - Double(values["input_tp"]!)!)
        return "volume=\(gain)dB"
    }
}
