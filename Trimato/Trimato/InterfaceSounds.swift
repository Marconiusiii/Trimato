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
        if active { captures.insert(id); silenceForPlayback() }
        else { captures.remove(id) }
    }

    func exportCompleted() {
        guard captures.isEmpty, enabled(AppPreferenceKey.exportCompletionSound) else { return }
        stopLoop()
        play(notes: [523.25, 659.25, 783.99, 1046.5], noteLength: 0.14, volume: 0.12, completion: true)
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

    private func play(notes: [Double], noteLength: Double, volume: Double, completion: Bool = false) {
        let data = Self.wave(notes: notes, noteLength: noteLength, volume: volume)
        if let playback { playback(data); return }
        if completion {
            completionSound?.stop()
            completionSound = NSSound(data: data)
            completionSound?.play()
        } else {
            sound?.stop()
            sound = NSSound(data: data)
            sound?.play()
        }
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
    func start() {
        stop()
        token = InterfaceSounds.shared.begin()
    }
    func stopBeforePlayback() {
        stop()
        InterfaceSounds.shared.silenceForPlayback()
    }
    func stop() {
        if let token { InterfaceSounds.shared.end(token) }
        token = nil
    }
}
