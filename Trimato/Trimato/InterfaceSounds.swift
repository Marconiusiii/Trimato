import AppKit
import Combine

/// Operation tokens prevent overlapping preparations from stacking sounds.
@MainActor
final class InterfaceSounds {
    static let shared = InterfaceSounds()
    private var operations: Set<UUID> = []
    private var captures: Set<UUID> = []
    private var loop: Task<Void, Never>?
    private var sound: NSSound?
    private var completionSound: NSSound?
    private var markerSound: NSSound?
    private static let exportData = exportWave()
    private let markerData = InterfaceSounds.wave(notes: [660], noteLength: 0.055, volume: 0.065)
    private let defaults: UserDefaults
    private let playback: ((Data) -> Void)?
    private let stopPlayback: (() -> Void)?
    private var preferences: AnyCancellable?

    init(defaults: UserDefaults = .standard, playback: ((Data) -> Void)? = nil, stopPlayback: (() -> Void)? = nil) {
        self.defaults = defaults
        self.playback = playback
        self.stopPlayback = stopPlayback
        preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                if !self.enabled(AppPreferenceKey.processingSounds) { self.stopLoop() }
                if !self.enabled(AppPreferenceKey.exportCompletionSound) { self.completionSound?.stop() }
            }
    }

    private func enabled(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    func begin() -> UUID {
        let id = UUID()
        operations.insert(id)
        if loop == nil, captures.isEmpty, enabled(AppPreferenceKey.processingSounds) {
            loop = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(650))
                    while !Task.isCancelled {
                        guard let self, !self.operations.isEmpty, self.captures.isEmpty,
                              self.enabled(AppPreferenceKey.processingSounds) else { return }
                        self.play(notes: [523.25, 659.25, 783.99], noteLength: 0.085, volume: 0.055)
                        try await Task.sleep(for: .seconds(2.4))
                    }
                } catch { }
            }
        }
        return id
    }

    func end(_ id: UUID) {
        operations.remove(id)
        if operations.isEmpty { stopLoop() }
    }

    func capture(_ id: UUID, active: Bool) {
        if active { captures.insert(id); markerSound?.stop(); silenceForPlayback() }
        else { captures.remove(id) }
    }

    func markerCreated() {
        guard captures.isEmpty, enabled(AppPreferenceKey.markerAudio) else { return }
        if let playback { playback(markerData); return }
        markerSound?.stop()
        markerSound = NSSound(data: markerData)
        markerSound?.play()
    }

    func exportCompleted() {
        guard captures.isEmpty, enabled(AppPreferenceKey.exportCompletionSound) else { return }
        stopLoop()
        let data = Self.exportData
        if let playback { playback(data); return }
        completionSound?.stop()
        completionSound = NSSound(data: data)
        completionSound?.play()
    }

    func silenceForPlayback() {
        stopLoop()
        completionSound?.stop()
    }

    private func stopLoop() {
        loop?.cancel(); loop = nil
        sound?.stop(); sound = nil
        stopPlayback?()
    }

    private func play(notes: [Double], noteLength: Double, volume: Double) {
        let data = Self.wave(notes: notes, noteLength: noteLength, volume: volume)
        if let playback { playback(data); return }
        sound?.stop()
        sound = NSSound(data: data)
        sound?.play()
    }

    /// A downward mallet turn resolves upward into a bell that gently rings out.
    nonisolated private static func exportWave() -> Data {
        let rate = 48000
        let duration = 1.2
        let strikes: [(start: Double, frequency: Double, strength: Double, decay: Double)] = [
            (0, 783.99, 0.72, 0.105),
            (0.105, 659.25, 0.59, 0.095),
            (0.255, 1046.5, 1, 0.205)
        ]
        var samples = [Double](repeating: 0, count: Int(duration * Double(rate)))
        for (frame, _) in samples.enumerated() {
            let time = Double(frame) / Double(rate)
            var value = 0.0
            for (index, strike) in strikes.enumerated() {
                let t = time - strike.start
                guard t >= 0 else { continue }
                let attack = 1 - exp(-t / 0.004)
                let phase = 2 * Double.pi * strike.frequency * t
                let body = sin(phase) * exp(-t / strike.decay)
                let ring = 0.24 * sin(phase * 2.01) * exp(-t / 0.065)
                    + 0.09 * sin(phase * 3.97) * exp(-t / 0.032)
                let wood = 0.12 * sin(2 * Double.pi * 1850 * t) * exp(-t / 0.012)
                // A quiet octave and fifth give the final strike a rounded resolution.
                let support = index == 2
                    ? (0.32 * sin(phase * 0.5) + 0.12 * sin(phase * 0.75)) * exp(-t / 0.182)
                    : 0
                value += strike.strength * attack * (body + ring + wood + support)
            }
            let fadePosition = min(1, max(0, (duration - time) / 0.145))
            let fade = 0.5 - 0.5 * cos(Double.pi * fadePosition)
            samples[frame] = value * fade
        }
        let peak = samples.map { abs($0) }.max() ?? 1
        let gain = 0.4 / max(peak, 0.001)
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((sample * gain * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return waveData(pcm: pcm, rate: rate)
    }

    nonisolated static func wave(notes: [Double], noteLength: Double, volume: Double) -> Data {
        let rate = 48000
        let frames = Int(Double(rate) * noteLength)
        var pcm = Data()
        for frequency in notes {
            for frame in 0..<frames {
                let time = Double(frame) / Double(rate)
                let envelope = max(0, min(1, time / 0.012, (noteLength - time) / 0.035))
                let fundamental = sin(2 * .pi * frequency * time)
                let harmonic = 0.15 * sin(4 * .pi * frequency * time)
                var sample = Int16(max(-32767, min(32767, (fundamental + harmonic) * envelope * volume * 32767))).littleEndian
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
        }
        return waveData(pcm: pcm, rate: rate)
    }

    nonisolated private static func waveData(pcm: Data, rate: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + pcm.count)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(rate))
        number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

@MainActor
final class ProcessingSound {
    private var token: UUID?
    private let sounds: InterfaceSounds
    init(sounds: InterfaceSounds? = nil) { self.sounds = sounds ?? .shared }
    func start() {
        stop()
        token = sounds.begin()
    }
    func stopBeforePlayback() {
        stop()
        sounds.silenceForPlayback()
    }
    func stop() {
        if let token { sounds.end(token) }
        token = nil
    }
}
