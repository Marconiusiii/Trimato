import AVFoundation
import Foundation

// Outputs belong to the caller and are removed with the composed preview or export.
nonisolated enum ClipFilterRenderer {
    @concurrent
    static func render(source: URL, filters: [ClipFilter], audio: Bool, duration: Double,
                       segments: [SourceSegment]? = nil, audioSettings: AudioClipSettings? = nil,
                       voiceSegments: [SourceSegment]? = nil,
                       progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        for filter in filters { try filter.validate() }
        let asset = AVURLAsset(url: source)
        let spatial = try await SpatialAudioPlan.detect(in: asset)
        if audio, spatial { throw SpatialAudioError.unsupported("Audio filter processing for Spatial Audio is not supported yet.") }
        let rendered = try await renderProcessed(source: source, filters: filters, audio: audio, duration: duration,
            segments: segments, audioSettings: audioSettings, voiceSegments: voiceSegments, progress: progress)
        guard spatial, !audio else { return rendered }
        defer { try? FileManager.default.removeItem(at: rendered) }
        let sourceDuration = try await asset.load(.duration)
        let ranges = segments?.map { $0.sourceRange.cmTimeRange } ?? [CMTimeRange(start: .zero, duration: sourceDuration)]
        guard let plan = try await SpatialAudioPlan.clip(asset: asset, ranges: ranges) else { throw SpatialAudioError.invalidMovie }
        let output = rendered.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try await plan.export(video: AVURLAsset(url: rendered), to: output, progress: { _ in })
        return output
    }

    @concurrent
    private static func renderProcessed(source: URL, filters: [ClipFilter], audio: Bool, duration: Double,
                       segments: [SourceSegment]? = nil, audioSettings: AudioClipSettings? = nil,
                       voiceSegments: [SourceSegment]? = nil,
                       progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        if audio, let voice = audioSettings?.voice, voice.isActive {
            var originalSettings = audioSettings
            originalSettings?.voice = nil
            let processed = try await renderProcessed(source: source, filters: filters, audio: true, duration: duration,
                                             audioSettings: originalSettings, voiceSegments: segments ?? voiceSegments, progress: progress)
            defer { try? FileManager.default.removeItem(at: processed) }
            return try await VoiceAudioProcessor.render(source: processed, settings: voice,
                segments: segments ?? voiceSegments, trimOutput: segments != nil)
        }
        for filter in filters { try filter.validate() }
        let active = ClipFilterKind.allCases.compactMap { kind in filters.first { $0.kind == kind && $0.enabled && $0.kind.isAudio == audio } }
        if let segments, !active.isEmpty {
            // Process the same source and history as the project renderer, then select the edited ranges.
            let processed = try await renderProcessed(source: source, filters: filters, audio: audio, duration: duration, voiceSegments: segments, progress: progress)
            defer { try? FileManager.default.removeItem(at: processed) }
            return try await renderProcessed(source: processed, filters: [], audio: audio, duration: duration,
                                    segments: segments, audioSettings: audioSettings, progress: progress)
        }
        let directory = try TemporaryMediaSession.directory(named: "TrimatoClipFilters")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await FFmpegMediaProbe.inspect(url: source)
        if !audio, report.isHDR, !active.isEmpty {
            return try await HDRVideoRenderer.render(source: source, filters: active, progress: progress)
        }
        try ProjectRenderMediaManager.requireAvailableSpace(in: directory,
            duration: segments?.reduce(0) { $0 + $1.duration.seconds } ?? report.duration,
            width: report.videoStream?.width, height: report.videoStream?.height, hasVideo: !audio,
            sampleRate: Double(report.audioStream?.sampleRate ?? "") ?? 48_000,
            channels: report.audioStream?.channels ?? 2,
            frameRate: report.frameRate ?? 30, hasAlpha: report.hasAlpha)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let sampleRate = Int(report.audioStream?.sampleRate ?? "") ?? 48_000
        var effects: [String] = []
        for filter in active {
            if filter.kind == .matchLoudness {
                effects.append(try await ClipLoudnessNormalizer.graph(source: source, preceding: effects,
                    filter: filter, segments: voiceSegments))
            } else { effects.append(filter.graph(sampleRate: sampleRate)) }
        }
        let graph = (audio ? ["aformat=sample_fmts=fltp"] : []) + effects
        var graphText = graph.joined(separator: ",")
        if audio, let settings = audioSettings, let gain = FFmpegTimelineEffectRenderer.audioFilter(for: settings) {
            graphText = [graphText, gain].filter { !$0.isEmpty }.joined(separator: ",")
        }
        // Echo and room decay stay inside the existing clip duration in both
        // preview and project rendering; they never shift later clips.
        if audio, active.contains(where: { $0.kind == .reverb || $0.kind == .echo }) {
            graphText += ",atrim=duration=\(report.duration)"
        }
        var arguments = ["-hide_banner", "-nostdin", "-y"]
        if report.hasAlpha, report.videoStream?.codecName == "prores" { arguments += ["-alpha_mode", "premultiplied"] }
        arguments += ["-i", source.path]
        if let segments {
            let prefix = audio ? "a" : "v"
            let trim = audio ? "atrim" : "trim"
            let pts = audio ? "asetpts" : "setpts"
            var chains = segments.enumerated().map { index, segment in
                "[0:\(prefix):0]\(trim)=start=\(segment.sourceRange.start.seconds):end=\(segment.sourceRange.end.seconds),\(pts)=PTS-STARTPTS[s\(index)]"
            }
            let inputs = segments.indices.map { "[s\($0)]" }.joined()
            let effects = graphText.isEmpty ? (audio ? "anull" : "null") : graphText
            chains.append("\(inputs)concat=n=\(segments.count):v=\(audio ? 0 : 1):a=\(audio ? 1 : 0),\(effects)[out]")
            arguments += ["-filter_complex", chains.joined(separator: ";"), "-map", "[out]"]
        } else if !audio, report.hasAlpha, !active.isEmpty {
            // Color filters may negotiate a format without alpha. Keep the original mask
            // on a separate branch, applying the same geometry before joining it again.
            let geometry = active.filter { $0.kind == .cropOrientation }.map(\.graph).joined(separator: ",")
            let mask = geometry.isEmpty ? "alphaextract" : "alphaextract,\(geometry)"
            let chains = "[0:v:0]format=yuva444p:alpha_modes=straight,split[picture][mask];[picture]format=yuv444p,\(graphText)[color];[mask]\(mask)[alpha];[color][alpha]alphamerge[out]"
            arguments += ["-filter_complex", chains, "-map", "[out]"]
        } else {
            arguments += ["-map", audio ? "0:a:0" : "0:v:0", audio ? "-af" : "-vf", graphText.isEmpty ? (audio ? "anull" : "null") : graphText]
        }
        if audio { arguments += ["-vn", "-c:a", "pcm_f32le", "-ar", String(sampleRate)] }
        else { arguments += ["-an", "-c:v", "prores_ks", "-profile:v", report.hasAlpha ? "4" : report.isHDR ? "3" : "1",
                             "-pix_fmt", report.hasAlpha ? "yuva444p10le" : "yuv422p10le"] }
        if !audio, report.isHDR {
            arguments += ["-color_primaries", "bt2020", "-colorspace", "bt2020nc", "-color_trc", report.videoStream?.colorTransfer ?? "arib-std-b67"]
        }
        if !audio, report.hasAlpha { arguments += ["-alpha_mode", "premultiplied"] }
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

    @concurrent
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
                    let hasVoice = audio && clip.audioSettings.voice?.isActive == true
                    guard hasVoice || clip.filters.contains(where: { $0.enabled && $0.kind.isAudio == audio }) else { continue }
                    guard var record = prepared.asset(id: clip.assetID), let source = resolved[clip.assetID] else { throw ProjectCompositionError.missingMedia(clip.displayName) }
                    let output = try await render(source: source, filters: clip.filters, audio: audio, duration: record.duration.seconds,
                        audioSettings: hasVoice ? clip.audioSettings : nil, voiceSegments: clip.segments)
                    temporary.append(output)
                    if hasVoice { prepared.tracks[trackIndex].clips[clipIndex].audioSettings = .neutral }
                    record.id = UUID()
                    record.generator = nil
                    record.playbackMode = .nativePassthrough
                    record.proxyCacheKey = nil
                    record.originalPath = output.path
                    prepared.media.append(record)
                    resolved[record.id] = output
                    prepared.tracks[trackIndex].clips[clipIndex].assetID = record.id
                    if let index = prepared.primaryTimeline.firstIndex(where: { $0.id == clip.id }) {
                        prepared.primaryTimeline[index].assetID = record.id
                        if hasVoice { prepared.primaryTimeline[index].audioSettings = .neutral }
                    }
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
