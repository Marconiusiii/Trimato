import Foundation

nonisolated struct FilterParameter: Identifiable, Sendable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let initial: Double
    var step: Double = 0.1
}

nonisolated enum ClipFilterKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case brightnessContrast, colorAdjustment, blackAndWhite, sharpen, videoNoise, cropOrientation
    case tone, backgroundNoise, evenVolume, matchLoudness, reverb, echo, softenS, limitPeaks
    var id: Self { self }
    var isAudio: Bool { [.tone, .backgroundNoise, .evenVolume, .matchLoudness, .reverb, .echo, .softenS, .limitPeaks].contains(self) }
    var title: String {
        switch self {
        case .brightnessContrast: "Brightness and Contrast"
        case .colorAdjustment: "Color Adjustment"
        case .blackAndWhite: "Black and White"
        case .sharpen: "Sharpen"
        case .videoNoise: "Reduce Video Noise"
        case .cropOrientation: "Crop and Orientation"
        case .tone: "Equalizer"
        case .backgroundNoise: "Reduce Background Noise"
        case .evenVolume: "Even Out Volume"
        case .matchLoudness: "Match Loudness"
        case .reverb: "Reverb"
        case .echo: "Echo"
        case .softenS: "Soften harsh S sounds"
        case .limitPeaks: "Limit loud peaks"
        }
    }
    var description: String {
        switch self {
        case .brightnessContrast: "Adjust overall lightness and the difference between dark and bright areas."
        case .colorAdjustment: "Adjust color intensity, warmth, and green or magenta tint."
        case .blackAndWhite: "Remove color while preserving differences in brightness."
        case .sharpen: "Emphasize edges. Strong settings can add visible outlines."
        case .videoNoise: "Soften fine image noise. Strong settings can remove detail."
        case .cropOrientation: "Remove pixels from the edges, then rotate or flip the image. The result fits the project frame."
        case .tone: "Adjust low, middle, and high frequencies or reduce rumble and hiss."
        case .backgroundNoise: "Reduce steady background noise. Strong reduction can affect speech."
        case .evenVolume: "Compress louder passages and limit peaks to reduce changes in volume."
        case .matchLoudness: "Adjust the whole clip toward a target perceived loudness, measured in LUFS."
        case .reverb: "Add the sound of a room. The effect ends at the clip’s Out point."
        case .echo: "Add a delayed repeat. The effect ends at the clip’s Out point."
        case .softenS: "Reduce sharp S and sh sounds in speech."
        case .limitPeaks: "Keep sudden loud peaks below the selected level."
        }
    }
    var parameters: [FilterParameter] {
        switch self {
        case .brightnessContrast: [p("brightness", "Brightness", -0.5...0.5, 0, 0.01), p("contrast", "Contrast", 0.5...2, 1, 0.05)]
        case .colorAdjustment: [p("saturation", "Saturation", 0...2, 1), p("warmth", "Warmth", -1...1, 0), p("tint", "Tint", -1...1, 0)]
        case .blackAndWhite: []
        case .sharpen: [p("amount", "Sharpness", 0...2, 0.5)]
        case .videoNoise: [p("amount", "Noise Reduction", 1...10, 2)]
        case .cropOrientation: [p("left", "Crop Left in Pixels", 0...8190, 0, 1), p("right", "Crop Right in Pixels", 0...8190, 0, 1), p("top", "Crop Top in Pixels", 0...8190, 0, 1), p("bottom", "Crop Bottom in Pixels", 0...8190, 0, 1)]
        case .tone: [p("low", "Bass", -12...12, 0, 1), p("mid", "Midrange", -12...12, 0, 1), p("high", "Treble", -12...12, 0, 1), p("highpass", "Rumble cutoff", 20...2000, 80, 1), p("lowpass", "Hiss cutoff", 1000...20000, 16000, 1)]
        case .reverb: [p("amount", "Amount", 0...100, 25, 1), p("room", "Room", 0...2, 1, 1)]
        case .echo: [p("delay", "Delay", 50...1000, 250, 10), p("amount", "Strength", 0...80, 30, 1)]
        case .softenS: [p("amount", "Amount", 0...100, 50, 1)]
        case .limitPeaks: [p("ceiling", "Peak ceiling", -18 ... -1, -3, 0.5)]
        case .backgroundNoise: [p("amount", "Noise reduction", 0.01...30, 12)]
        case .evenVolume: [p("threshold", "Start smoothing above", -40...0, -18, 1), p("ratio", "Smoothing strength", 1...10, 3)]
        case .matchLoudness: [p("target", "Playback loudness", -30 ... -10, -16, 1), p("peak", "Peak ceiling", -9 ... -1, -1, 0.1)]
        }
    }
    private func p(_ id: String, _ label: String, _ range: ClosedRange<Double>, _ initial: Double, _ step: Double = 0.1) -> FilterParameter {
        FilterParameter(id: id, label: label, range: range, initial: initial, step: step)
    }
}

nonisolated struct ClipFilter: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: ClipFilterKind
    var enabled = true
    var values: [String: Double] = [:]
    var highPassEnabled = false
    var lowPassEnabled = false
    var rotation = 0
    var flipHorizontal = false
    var flipVertical = false

    func value(_ key: String) -> Double { values[key] ?? kind.parameters.first(where: { $0.id == key })?.initial ?? 0 }
    func validate() throws {
        for parameter in kind.parameters {
            guard value(parameter.id).isFinite, parameter.range.contains(value(parameter.id)) else {
                throw MediaSourceError.unreadable("\(kind.title): \(parameter.label) must be between \(parameter.range.lowerBound) and \(parameter.range.upperBound).")
            }
        }
        guard [0, 90, 180, 270].contains(rotation) else { throw MediaSourceError.unreadable("Choose a supported rotation.") }
    }

    var graph: String {
        switch kind {
        case .brightnessContrast: "format=yuv420p,lutyuv=y='clip((val-128)*\(value("contrast"))+128+\(value("brightness") * 255),0,255)'"
        case .colorAdjustment: "hue=s=\(value("saturation")),colorbalance=rm=\(value("warmth") * 0.3):bm=\(-value("warmth") * 0.3):gm=\(value("tint") * 0.3)"
        case .blackAndWhite: "hue=s=0"
        case .sharpen: "unsharp=5:5:\(value("amount")):5:5:0"
        case .videoNoise: "nlmeans=s=\(value("amount"))"
        case .cropOrientation: orientationGraph
        case .tone: FFmpegTimelineEffectRenderer.audioFilter(for: toneSettings) ?? "anull"
        case .backgroundNoise: "afftdn=nr=\(value("amount"))"
        case .evenVolume: "acompressor=threshold=\(pow(10, value("threshold") / 20)):ratio=\(value("ratio")):attack=20:release=250,alimiter=limit=0.891251:level=false"
        case .matchLoudness: "loudnorm=I=\(value("target")):TP=\(value("peak")):LRA=11"
        case .reverb: reverbGraph
        case .echo: value("amount") == 0 ? "anull" : "aecho=1:1:\(value("delay")):\(value("amount") / 100)"
        case .softenS: "deesser=i=\(value("amount") / 100):m=0.8:f=0.5"
        case .limitPeaks: "aresample=192000,alimiter=limit=\(pow(10, value("ceiling") / 20)):level=false:latency=true,aresample=48000"
        }
    }
    var reverbDecay: Double { [0.35, 0.8, 1.6][min(max(Int(value("room")), 0), 2)] }
    private var reverbGraph: String {
        guard value("amount") > 0 else { return "anull" }
        let key = "r" + id.uuidString.replacingOccurrences(of: "-", with: "")
        // A deterministic broadband impulse response gives a diffuse room decay,
        // rather than labeling a handful of discrete echoes as reverb.
        let noise = "2*(sin(n*12.9898)*43758.5453-floor(sin(n*12.9898)*43758.5453))-1"
        let impulse = "if(lt(t,0.012),0,(\(noise))*exp(-6.907755*t/\(reverbDecay)))"
        return "asplit=2[\(key)d][\(key)w];aevalsrc='\(impulse)':s=48000:d=\(reverbDecay)[\(key)i];[\(key)w][\(key)i]afir=dry=1:wet=1:irfmt=mono:minp=64:maxp=512[\(key)r];[\(key)d][\(key)r]amix=inputs=2:duration=first:normalize=0:weights='1 \(value("amount") / 100)'"
    }

    private var orientationGraph: String {
        var parts: [String] = []
        let left = Int(value("left")), right = Int(value("right")), top = Int(value("top")), bottom = Int(value("bottom"))
        if left + right + top + bottom > 0 { parts.append("crop=iw-\(left + right):ih-\(top + bottom):\(left):\(top):exact=1") }
        if rotation == 90 { parts.append("transpose=clock") }
        if rotation == 180 { parts += ["hflip", "vflip"] }
        if rotation == 270 { parts.append("transpose=cclock") }
        if flipHorizontal { parts.append("hflip") }
        if flipVertical { parts.append("vflip") }
        return parts.isEmpty ? "null" : parts.joined(separator: ",")
    }
    var toneSettings: AudioClipSettings {
        var settings = AudioClipSettings()
        settings.lowGainDecibels = value("low")
        settings.midGainDecibels = value("mid")
        settings.highGainDecibels = value("high")
        settings.highPassEnabled = highPassEnabled
        settings.lowPassEnabled = lowPassEnabled
        settings.highPassFrequency = value("highpass")
        settings.lowPassFrequency = value("lowpass")
        return settings
    }
    static func legacyTone(_ settings: AudioClipSettings) -> ClipFilter? {
        var tone = settings
        tone.gainDecibels = 0
        tone.voice = nil
        guard !tone.isNeutral else { return nil }
        var filter = ClipFilter(kind: .tone)
        filter.values = ["low": settings.lowGainDecibels, "mid": settings.midGainDecibels, "high": settings.highGainDecibels, "highpass": settings.highPassFrequency, "lowpass": settings.lowPassFrequency]
        filter.highPassEnabled = settings.highPassEnabled
        filter.lowPassEnabled = settings.lowPassEnabled
        return filter
    }
}


extension TrimatoProject {
    mutating func setClipEffects(id: UUID, audio: AudioClipSettings?, filters: [ClipFilter]?) throws {
        if let filters { for filter in filters { try filter.validate() } }
        guard let trackIndex = tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else { throw ProjectTimelineError.clipNotFound }
        if let audio, tracks[trackIndex].kind == .audio { tracks[trackIndex].clips[clipIndex].audioSettings = audio }
        if let filters { tracks[trackIndex].clips[clipIndex].filters = filters.filter { $0.kind.isAudio == (tracks[trackIndex].kind == .audio) } }
        synchronizeTracksToLegacyTimeline()
    }
}
