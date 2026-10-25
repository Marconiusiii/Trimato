import AVFoundation
import Foundation

// Outputs belong to the caller and are removed with the composed preview or export.
nonisolated enum ClipFilterRenderer {
    typealias Progress = @MainActor @Sendable (Double) -> Void

    static func progress(in range: ClosedRange<Double>, report: Progress?) -> Progress? {
        guard let report else { return nil }
        return { value in
            guard value.isFinite else { return }
            report(range.lowerBound + min(max(value, 0), 1) * (range.upperBound - range.lowerBound))
        }
    }

    @concurrent
    static func render(source: URL, filters: [ClipFilter], audio: Bool, duration: Double,
                       segments: [SourceSegment]? = nil, audioSettings: AudioClipSettings? = nil,
                       voiceSegments: [SourceSegment]? = nil,
                       progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        for filter in filters { try filter.validate() }
        struct Recipe: Encodable {
            let filters: [ClipFilter]
            let audio: Bool
            let duration: Double
            let ranges: [ProjectTimeRange]?
            let audioSettings: AudioClipSettings?
            let voiceRanges: [ProjectTimeRange]?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stableID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let recipe = try encoder.encode(Recipe(filters: filters.map { value in
            var filter = value; filter.id = stableID; return filter
        }, audio: audio, duration: duration, ranges: segments?.map(\.sourceRange),
            audioSettings: audioSettings, voiceRanges: (audioSettings?.voice?.isActive == true || filters.contains { $0.kind == .matchLoudness }) ? voiceSegments?.map(\.sourceRange) : nil))
        let output = try await RenderedMediaCache.shared.value(source: source, recipe: recipe) {
            try await renderUncached(source: source, filters: filters, audio: audio, duration: duration,
                segments: segments, audioSettings: audioSettings, voiceSegments: voiceSegments, progress: progress)
        }
        do {
            try Task.checkCancellation()
            await progress?(1)
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    @concurrent
    private static func renderUncached(source: URL, filters: [ClipFilter], audio: Bool, duration: Double,
                       segments: [SourceSegment]?, audioSettings: AudioClipSettings?,
                       voiceSegments: [SourceSegment]?, progress: Progress?) async throws -> URL {
        for filter in filters { try filter.validate() }
        let asset = AVURLAsset(url: source)
        let spatial = try await SpatialAudioPlan.detect(in: asset)
        if audio, spatial { throw SpatialAudioError.unsupported("Audio filter processing for Spatial Audio is not supported yet.") }
        let audioTracks = audio ? [] : try await asset.loadTracks(withMediaType: .audio)
        let preservesAudio = !audio && (spatial || !audioTracks.isEmpty)
        let rendered = try await renderProcessed(source: source, filters: filters, audio: audio, duration: duration,
            segments: segments, audioSettings: audioSettings, voiceSegments: voiceSegments,
            progress: preservesAudio ? Self.progress(in: 0...0.9, report: progress) : progress)
        guard preservesAudio else { return rendered }
        defer { try? FileManager.default.removeItem(at: rendered) }
        let sourceDuration = try await asset.load(.duration)
        let ranges = segments?.map { $0.sourceRange.cmTimeRange } ?? [CMTimeRange(start: .zero, duration: sourceDuration)]
        let output = rendered.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            if spatial {
                guard let plan = try await SpatialAudioPlan.clip(asset: asset, ranges: ranges) else { throw SpatialAudioError.invalidMovie }
                try await plan.export(video: AVURLAsset(url: rendered), to: output,
                                      progress: Self.progress(in: 0.9...1, report: progress) ?? { _ in })
            } else {
                try await preserveAudio(audioTracks, ranges: ranges, video: AVURLAsset(url: rendered),
                                        to: output, progress: Self.progress(in: 0.9...1, report: progress))
            }
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // Both SDR and HDR processing produce picture-only intermediates. Restore
    // the original audio once, after all picture processing and range selection.
    @concurrent
    private static func preserveAudio(_ audioTracks: [AVAssetTrack], ranges: [CMTimeRange],
                                      video: AVAsset, to output: URL, progress: Progress?) async throws {
        let composition = AVMutableComposition()
        let videoDuration = try await video.load(.duration)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: video, at: .zero)
        for sourceTrack in audioTracks {
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ClipExportError.unavailable
            }
            let available = try await sourceTrack.load(.timeRange)
            var position = CMTime.zero
            for range in ranges {
                try Task.checkCancellation()
                let retained = CMTimeRangeGetIntersection(range, otherRange: available)
                if retained.isValid, retained.duration > .zero {
                    let destination = position + (retained.start - range.start)
                    try track.insertTimeRange(retained, of: sourceTrack, at: destination)
                }
                position = position + range.duration
            }
            track.preferredVolume = try await sourceTrack.load(.preferredVolume)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipExportError.unavailable
        }
        session.timeRange = CMTimeRange(start: .zero, duration: videoDuration)
        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress?(min(Double(session.progress), 0.99))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        try await session.export(to: output, as: .mov)
        try Task.checkCancellation()
        try await ExportOutputValidator.validate(output, duration: videoDuration.seconds, video: true, audio: true)
        reporter.cancel()
        await progress?(1)
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
                                             audioSettings: originalSettings, voiceSegments: segments ?? voiceSegments,
                                             progress: Self.progress(in: 0...0.8, report: progress))
            defer { try? FileManager.default.removeItem(at: processed) }
            let output = try await VoiceAudioProcessor.render(source: processed, settings: voice,
                segments: segments ?? voiceSegments, trimOutput: segments != nil)
            await progress?(1)
            return output
        }
        for filter in filters { try filter.validate() }
        let active = ClipFilterKind.allCases.compactMap { kind in filters.first { $0.kind == kind && $0.enabled && $0.kind.isAudio == audio } }
        if let segments, !active.isEmpty, audio || segments.count != 1 {
            // Process the same source and history as the project renderer, then select the edited ranges.
            let processed = try await render(source: source, filters: filters, audio: audio, duration: duration,
                voiceSegments: segments, progress: Self.progress(in: 0...0.8, report: progress))
            defer { try? FileManager.default.removeItem(at: processed) }
            return try await renderProcessed(source: processed, filters: [], audio: audio, duration: duration,
                                    segments: segments, audioSettings: audioSettings,
                                    progress: Self.progress(in: 0.8...1, report: progress))
        }
        let directory = try TemporaryMediaSession.directory(named: "TrimatoClipFilters")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await FFmpegMediaProbe.inspect(url: source)
        if !audio, report.isHDR, !active.isEmpty {
            return try await HDRVideoRenderer.render(source: source, filters: active, timeRange: segments?.first?.sourceRange.cmTimeRange, progress: progress)
        }
        try ProjectRenderMediaManager.requireAvailableSpace(in: directory,
            duration: segments?.reduce(0) { $0 + $1.duration.seconds } ?? report.duration,
            width: report.videoStream?.width, height: report.videoStream?.height, hasVideo: !audio,
            sampleRate: Double(report.audioStream?.sampleRate ?? "") ?? 48_000,
            channels: report.audioStream?.channels ?? 2,
            frameRate: report.frameRate ?? 30, hasAlpha: report.hasAlpha)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let sampleRate = Int(report.audioStream?.sampleRate ?? "") ?? 48_000
        var plateResponse: URL?
        defer { if let plateResponse { try? FileManager.default.removeItem(at: plateResponse) } }
        if let plate = active.first(where: { $0.kind == .plateReverb && $0.value("amount") > 0 }) {
            let response = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            plateResponse = response
            try PlateReverb.writeResponse(filter: plate, sampleRate: sampleRate, to: response)
        }
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
        // Echo and reverb decay stay inside the existing clip duration in both
        // preview and project rendering; they never shift later clips.
        if audio, active.contains(where: { $0.kind == .reverb || $0.kind == .plateReverb || $0.kind == .echo }) {
            graphText += ",atrim=duration=\(report.duration)"
        }
        var arguments = ["-hide_banner", "-nostdin", "-y"]
        if report.hasAlpha, report.videoStream?.codecName == "prores" { arguments += ["-alpha_mode", "premultiplied"] }
        let videoExcerpt = !audio && segments?.count == 1 ? segments?.first?.sourceRange : nil
        if let videoExcerpt { arguments += ["-ss", String(videoExcerpt.start.seconds)] }
        arguments += ["-i", source.path]
        if let videoExcerpt { arguments += ["-t", String(videoExcerpt.duration.seconds)] }
        if let plateResponse { arguments += ["-i", plateResponse.path] }
        if let segments, videoExcerpt == nil {
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
        } else if audio, plateResponse != nil {
            arguments += ["-filter_complex", "[0:a:0]\(graphText)[out]", "-map", "[out]"]
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
            let outputDuration = segments?.reduce(0) { $0 + $1.duration.seconds } ?? report.duration
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, progress: progress,
                                          expectedDuration: outputDuration)
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
                    // Retain a contiguous source envelope and all possible transition handles.
                    // Stateful audio processing retains the original source history.
                    let handle = project.transitions.map(\.duration).max() ?? .zero
                    var excerpt = audio ? nil : Self.sourceEnvelope(clip: clip, duration: record.duration, handle: handle)
                    if let envelope = excerpt, envelope.start > .zero {
                        do {
                            let timing = FrameWindowIndex(asset: AVURLAsset(url: source), duration: record.duration.cmTime)
                            // Keep preceding picture samples, including for a cut between source frames.
                            let earlier = try await timing.target(from: envelope.start.cmTime, forward: false, count: 2)
                            let start = min(ProjectTime(earlier), envelope.start)
                            excerpt = ProjectTimeRange(start: start, duration: envelope.end - start)
                        } catch is CancellationError { throw CancellationError() }
                        catch { excerpt = nil } // Preserve full-source processing when native timing is unavailable.
                    }
                    let output = try await render(source: source, filters: clip.filters, audio: audio, duration: record.duration.seconds,
                        segments: excerpt.map { [SourceSegment(sourceRange: $0)] },
                        audioSettings: hasVoice ? clip.audioSettings : nil, voiceSegments: clip.segments)
                    let preparedSegments = clip.segments.map { segment in
                        var value = segment
                        if let excerpt { value.sourceRange.start = value.sourceRange.start - excerpt.start }
                        return value
                    }
                    prepared.tracks[trackIndex].clips[clipIndex].segments = preparedSegments
                    if let excerpt {
                        record.duration = excerpt.duration
                        record.sourceEdit = [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: excerpt.duration))]
                    }
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
                        prepared.primaryTimeline[index].segments = preparedSegments
                        if hasVoice { prepared.primaryTimeline[index].audioSettings = .neutral }
                    }
                    if let index = prepared.cutaways.firstIndex(where: { $0.id == clip.id }) {
                        prepared.cutaways[index].assetID = record.id
                        prepared.cutaways[index].segments = preparedSegments
                    }
                }
            }
            return (prepared, resolved, temporary)
        } catch {
            for url in temporary { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    static func sourceEnvelope(clip: TimelineClip, duration: ProjectTime, handle: ProjectTime) -> ProjectTimeRange? {
        guard let first = clip.segments.map(\.sourceRange.start).min(),
              let last = clip.segments.map(\.sourceRange.end).max() else { return nil }
        let start = max(first - handle, .zero)
        let end = min(last + handle, duration)
        guard end > start else { return nil }
        return ProjectTimeRange(start: start, duration: end - start)
    }

}
