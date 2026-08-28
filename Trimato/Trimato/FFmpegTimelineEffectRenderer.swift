import Foundation

enum FFmpegTimelineEffectRenderer {
    static func renderAudio(
        sourceURL: URL,
        segments: [SourceSegment],
        settings: AudioClipSettings
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoTimelineEffects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let usable = segments.filter { $0.duration.isPositive }
        guard !usable.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        var chains: [String] = usable.enumerated().map { index, segment in
            "[0:a:0]atrim=start=\(number(segment.sourceRange.start.seconds)):end=\(number(segment.sourceRange.end.seconds)),asetpts=PTS-STARTPTS[s\(index)]"
        }
        let inputs = usable.indices.map { "[s\($0)]" }.joined()
        var final = "\(inputs)concat=n=\(usable.count):v=0:a=1"
        if let effects = audioFilter(for: settings) { final += ",\(effects)" }
        final += "[outa]"
        chains.append(final)
        let arguments = [
            "-hide_banner", "-nostdin", "-y", "-i", sourceURL.path,
            "-filter_complex", chains.joined(separator: ";"),
            "-map", "[outa]", "-vn", "-sn", "-dn",
            "-c:a", "pcm_s16le", outputURL.path,
        ]
        do {
            _ = try await FFmpegRunner.run(
                tool: .ffmpeg,
                arguments: arguments,
                expectedDuration: usable.reduce(0) { $0 + $1.duration.seconds }
            )
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func renderVideoTransition(
        leadingURL: URL,
        trailingURL: URL,
        leadingClip: TimelineClip,
        trailingClip: TimelineClip,
        type: VideoTransitionType,
        duration: ProjectTime,
        width: Int,
        height: Int,
        frameRate: Double
    ) async throws -> URL {
        guard let leadingEnd = leadingClip.segments.last?.sourceRange.end,
              let trailingStart = trailingClip.segments.first?.sourceRange.start else {
            throw ProjectTimelineError.transitionNotAvailable("The transition media is no longer available.")
        }
        let half = duration.seconds / 2
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoTimelineEffects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let graph: String
        if type == .fadeOutIn {
            graph = videoFadeOutInGraph(
                leadingStart: max(leadingEnd.seconds - half, 0),
                trailingStart: trailingStart.seconds,
                duration: duration.seconds,
                width: width,
                height: height,
                frameRate: frameRate
            )
        } else if let transitionName = videoTransitionName(type) {
            graph = videoTransitionGraph(
                leadingStart: max(leadingEnd.seconds - half, 0),
                trailingStart: max(trailingStart.seconds - half, 0),
                type: transitionName,
                duration: duration.seconds,
                width: width,
                height: height,
                frameRate: frameRate
            )
        } else {
            throw ProjectTimelineError.transitionNotAvailable("The transition media is no longer available.")
        }
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", leadingURL.path, "-i", trailingURL.path,
            "-filter_complex", graph, "-map", "[outv]", "-an", "-sn", "-dn",
            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
            outputURL.path,
        ]
        do {
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, expectedDuration: duration.seconds)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func renderAudioTransition(
        leadingURL: URL,
        trailingURL: URL,
        leadingClip: TimelineClip,
        trailingClip: TimelineClip,
        type: AudioTransitionType,
        duration: ProjectTime
    ) async throws -> URL {
        guard let leadingEnd = leadingClip.segments.last?.sourceRange.end,
              let trailingStart = trailingClip.segments.first?.sourceRange.start else {
            throw ProjectTimelineError.transitionNotAvailable("The transition media is no longer available.")
        }
        let half = duration.seconds / 2
        let graph: String
        if type == .fadeOutIn {
            graph = audioFadeOutInGraph(
                leadingStart: max(leadingEnd.seconds - half, 0),
                trailingStart: trailingStart.seconds,
                duration: duration.seconds,
                leadingSettings: leadingClip.audioSettings,
                trailingSettings: trailingClip.audioSettings
            )
        } else {
            graph = audioCrossFadeGraph(
                leadingStart: max(leadingEnd.seconds - half, 0),
                trailingStart: max(trailingStart.seconds - half, 0),
                duration: duration.seconds,
                leadingSettings: leadingClip.audioSettings,
                trailingSettings: trailingClip.audioSettings
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimatoTimelineEffects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", leadingURL.path, "-i", trailingURL.path,
            "-filter_complex", graph, "-map", "[outa]", "-vn", "-sn", "-dn",
            "-c:a", "pcm_s16le", outputURL.path,
        ]
        do {
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments, expectedDuration: duration.seconds)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func videoTransitionGraph(
        leadingStart: Double,
        trailingStart: Double,
        type: String,
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Double
    ) -> String {
        let normalized = "fps=\(number(frameRate)),settb=AVTB,setpts=PTS-STARTPTS," +
            "scale=\(width):\(height):force_original_aspect_ratio=decrease," +
            "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:black,setsar=1,format=yuv444p"
        return "[0:v:0]trim=start=\(number(leadingStart)):duration=\(number(duration)),\(normalized)[v0];" +
            "[1:v:0]trim=start=\(number(trailingStart)):duration=\(number(duration)),\(normalized)[v1];" +
            "[v0][v1]xfade=transition=\(type):duration=\(number(duration)):offset=0[outv]"
    }

    static func videoFadeOutInGraph(
        leadingStart: Double,
        trailingStart: Double,
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Double
    ) -> String {
        let half = duration / 2
        let normalized = "fps=\(number(frameRate)),settb=AVTB,setpts=PTS-STARTPTS," +
            "scale=\(width):\(height):force_original_aspect_ratio=decrease," +
            "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:black,setsar=1,format=yuv444p"
        return "[0:v:0]trim=start=\(number(leadingStart)):duration=\(number(half)),\(normalized)," +
            "fade=t=out:st=0:d=\(number(half))[v0];" +
            "[1:v:0]trim=start=\(number(trailingStart)):duration=\(number(half)),\(normalized)," +
            "fade=t=in:st=0:d=\(number(half))[v1];" +
            "[v0][v1]concat=n=2:v=1:a=0[outv]"
    }

    static func audioCrossFadeGraph(
        leadingStart: Double,
        trailingStart: Double,
        duration: Double,
        leadingSettings: AudioClipSettings,
        trailingSettings: AudioClipSettings
    ) -> String {
        let leadingEffects = audioFilter(for: leadingSettings).map { ",\($0)" } ?? ""
        let trailingEffects = audioFilter(for: trailingSettings).map { ",\($0)" } ?? ""
        return "[0:a:0]atrim=start=\(number(leadingStart)):duration=\(number(duration))," +
            "asetpts=PTS-STARTPTS\(leadingEffects)[a0];" +
            "[1:a:0]atrim=start=\(number(trailingStart)):duration=\(number(duration))," +
            "asetpts=PTS-STARTPTS\(trailingEffects)[a1];" +
            "[a0][a1]acrossfade=d=\(number(duration)):o=1:c1=qsin:c2=qsin[outa]"
    }

    static func audioFadeOutInGraph(
        leadingStart: Double,
        trailingStart: Double,
        duration: Double,
        leadingSettings: AudioClipSettings,
        trailingSettings: AudioClipSettings
    ) -> String {
        let half = duration / 2
        let leadingEffects = audioFilter(for: leadingSettings).map { ",\($0)" } ?? ""
        let trailingEffects = audioFilter(for: trailingSettings).map { ",\($0)" } ?? ""
        return "[0:a:0]atrim=start=\(number(leadingStart)):duration=\(number(half))," +
            "asetpts=PTS-STARTPTS\(leadingEffects),afade=t=out:st=0:d=\(number(half))[a0];" +
            "[1:a:0]atrim=start=\(number(trailingStart)):duration=\(number(half))," +
            "asetpts=PTS-STARTPTS\(trailingEffects),afade=t=in:st=0:d=\(number(half))[a1];" +
            "[a0][a1]concat=n=2:v=0:a=1[outa]"
    }

    static func audioFilter(for settings: AudioClipSettings) -> String? {
        var filters: [String] = []
        if settings.gainDecibels != 0 {
            filters.append("volume=\(number(settings.gainDecibels))dB")
        }
        if settings.lowGainDecibels != 0 {
            filters.append("equalizer=f=100:t=q:w=0.7:g=\(number(settings.lowGainDecibels))")
        }
        if settings.midGainDecibels != 0 {
            filters.append("equalizer=f=1000:t=q:w=1:g=\(number(settings.midGainDecibels))")
        }
        if settings.highGainDecibels != 0 {
            filters.append("equalizer=f=8000:t=q:w=0.7:g=\(number(settings.highGainDecibels))")
        }
        if settings.highPassEnabled {
            filters.append("highpass=f=\(number(settings.highPassFrequency))")
        }
        if settings.lowPassEnabled {
            filters.append("lowpass=f=\(number(settings.lowPassFrequency))")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    static func videoTransitionName(_ type: VideoTransitionType) -> String? {
        switch type {
        case .fade, .fadeOutIn: nil
        case .crossDissolve: "fade"
        case .wipeLeft: "wipeleft"
        case .wipeRight: "wiperight"
        case .wipeUp: "wipeup"
        case .wipeDown: "wipedown"
        }
    }

    static func fadeFilter(edge: TimelineTransitionEdge, duration: ProjectTime, clipDuration: ProjectTime, audio: Bool) -> String {
        let type = edge == .intro ? "in" : "out"
        let start = edge == .intro ? 0 : max(clipDuration.seconds - duration.seconds, 0)
        return "\(audio ? "afade" : "fade")=t=\(type):st=\(number(start)):d=\(number(duration.seconds))"
    }

    static func crossFilter(kind: TimelineTransitionKind, duration: ProjectTime, offset: ProjectTime) -> String {
        switch kind {
        case .video(let type):
            return "xfade=transition=\(videoTransitionName(type) ?? "fade"):duration=\(number(duration.seconds)):offset=\(number(offset.seconds))"
        case .audio:
            return "acrossfade=d=\(number(duration.seconds)):o=1:c1=qsin:c2=qsin"
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}
