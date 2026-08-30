import AVFoundation
import Foundation

// Outputs belong to the caller and are removed with the composed preview or export.
enum ClipFilterRenderer {
    static func render(source: URL, filters: [ClipFilter], audio: Bool, duration: Double,
                       segments: [SourceSegment]? = nil, audioSettings: AudioClipSettings? = nil,
                       progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        for filter in filters { try filter.validate() }
        let active = ClipFilterKind.allCases.compactMap { kind in filters.first { $0.kind == kind && $0.enabled && $0.kind.isAudio == audio } }
        if let segments, !active.isEmpty {
            // Process the same source and history as the project renderer, then select the edited ranges.
            let processed = try await render(source: source, filters: filters, audio: audio, duration: duration, progress: progress)
            defer { try? FileManager.default.removeItem(at: processed) }
            return try await render(source: processed, filters: [], audio: audio, duration: duration,
                                    segments: segments, audioSettings: audioSettings, progress: progress)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrimatoClipFilters", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await FFmpegMediaProbe.inspect(url: source)
        try ProjectRenderMediaManager.requireAvailableSpace(in: directory, duration: report.duration,
                                                           width: report.videoStream?.width, height: report.videoStream?.height, hasVideo: !audio)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        var graph = active.map(\.graph).joined(separator: ",")
        if audio, let settings = audioSettings, let gain = FFmpegTimelineEffectRenderer.audioFilter(for: settings) {
            graph = [graph, gain].filter { !$0.isEmpty }.joined(separator: ",")
        }
        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", source.path]
        if let segments {
            let prefix = audio ? "a" : "v"
            let trim = audio ? "atrim" : "trim"
            let pts = audio ? "asetpts" : "setpts"
            var chains = segments.enumerated().map { index, segment in
                "[0:\(prefix):0]\(trim)=start=\(segment.sourceRange.start.seconds):end=\(segment.sourceRange.end.seconds),\(pts)=PTS-STARTPTS[s\(index)]"
            }
            let inputs = segments.indices.map { "[s\($0)]" }.joined()
            let effects = graph.isEmpty ? (audio ? "anull" : "null") : graph
            chains.append("\(inputs)concat=n=\(segments.count):v=\(audio ? 0 : 1):a=\(audio ? 1 : 0),\(effects)[out]")
            arguments += ["-filter_complex", chains.joined(separator: ";"), "-map", "[out]"]
        } else {
            arguments += ["-map", audio ? "0:a:0" : "0:v:0", audio ? "-af" : "-vf", graph.isEmpty ? (audio ? "anull" : "null") : graph]
        }
        if audio { arguments += ["-vn", "-c:a", "pcm_s16le", "-ar", "48000"] }
        else { arguments += ["-an", "-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le"] }
        arguments += ["-sn", "-dn", "-progress", "pipe:1", "-nostats", output.path]
        do {
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, progress: progress, expectedDuration: duration)
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func prepare(project: TrimatoProject, urls: [UUID: URL]) async throws -> (TrimatoProject, [UUID: URL], [URL]) {
        var prepared = project
        var resolved = urls
        var temporary: [URL] = []
        do {
            let used = Set(project.tracks.flatMap(\.clips).map(\.assetID) + project.cutaways.map(\.assetID))
            for record in project.media where record.generator != nil && used.contains(record.id) {
                resolved[record.id] = try await GeneratorRenderer.ensure(record.generator!)
            }
            for trackIndex in prepared.tracks.indices {
                for clipIndex in prepared.tracks[trackIndex].clips.indices {
                    let clip = prepared.tracks[trackIndex].clips[clipIndex]
                    let audio = prepared.tracks[trackIndex].kind == .audio
                    guard clip.filters.contains(where: { $0.enabled && $0.kind.isAudio == audio }) else { continue }
                    guard var record = prepared.asset(id: clip.assetID), let source = resolved[clip.assetID] else { throw ProjectCompositionError.missingMedia(clip.displayName) }
                    let output = try await render(source: source, filters: clip.filters, audio: audio, duration: record.duration.seconds)
                    temporary.append(output)
                    record.id = UUID()
                    record.generator = nil
                    record.playbackMode = .nativePassthrough
                    record.proxyCacheKey = nil
                    record.originalPath = output.path
                    prepared.media.append(record)
                    resolved[record.id] = output
                    prepared.tracks[trackIndex].clips[clipIndex].assetID = record.id
                    if let index = prepared.primaryTimeline.firstIndex(where: { $0.id == clip.id }) { prepared.primaryTimeline[index].assetID = record.id }
                    if let index = prepared.cutaways.firstIndex(where: { $0.id == clip.id }) { prepared.cutaways[index].assetID = record.id }
                }
            }
            return (prepared, resolved, temporary)
        } catch {
            for url in temporary { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
