import AVFoundation
import Combine
import CoreAudio

nonisolated struct AudioDeviceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

nonisolated enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var property = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &value)
        return value
    }

    static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func devices() -> [AudioDeviceChoice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDeviceChoice(id: uid, deviceID: id, name: name, inputChannels: channelCount(id, input: true), outputChannels: channelCount(id, input: false))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &rate)
        return rate
    }

    static func gainAddress(_ id: AudioDeviceID, channel: Int) -> AudioObjectPropertyAddress? {
        for element in [AudioObjectPropertyElement(channel + 1), kAudioObjectPropertyElementMain] {
            var property = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(id, &property), AudioObjectIsPropertySettable(id, &property, &settable) == noErr, settable.boolValue { return property }
        }
        return nil
    }

    static func gain(_ id: AudioDeviceID, channel: Int) -> Float? {
        guard var property = gainAddress(id, channel: channel) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setGain(_ value: Float, id: AudioDeviceID, channel: Int) throws {
        guard var property = gainAddress(id, channel: channel) else { throw AudioCaptureError.message("This input does not expose adjustable hardware gain.") }
        var value = min(1, max(0, value))
        guard AudioObjectSetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr else {
            throw AudioCaptureError.message("The input device could not change its hardware gain.")
        }
    }
}

@MainActor
final class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()
    @Published private(set) var devices: [AudioDeviceChoice] = []
    @Published private(set) var revision = 0
    @Published var selectedUID: String {
        didSet {
            defaults.set(selectedUID, forKey: AppPreferenceKey.audioOutputDevice)
            refresh()
        }
    }
    private let defaults: UserDefaults
    private let players = NSHashTable<AVPlayer>.weakObjects()
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastResolvedUID: String?
    var outputs: [AudioDeviceChoice] { devices.filter { $0.outputChannels > 0 } }
    var resolvedDevice: AudioDeviceChoice? {
        Self.resolve(selectedUID: selectedUID, devices: outputs, defaultID: AudioHardware.defaultDevice(input: false))
    }
    var isAvailable: Bool { resolvedDevice != nil }

    init(defaults: UserDefaults = .standard, observeHardware: Bool = true) {
        self.defaults = defaults
        selectedUID = defaults.string(forKey: AppPreferenceKey.audioOutputDevice) ?? ""
        guard observeHardware else { return }
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var property = AudioHardware.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, block) == noErr {
                listeners.append((property, block))
            }
        }
    }

    deinit {
        for (var property, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, block)
        }
    }

    nonisolated static func resolve(selectedUID: String, devices: [AudioDeviceChoice], defaultID: AudioDeviceID) -> AudioDeviceChoice? {
        selectedUID.isEmpty ? devices.first { $0.deviceID == defaultID } : devices.first { $0.id == selectedUID }
    }

    func register(_ player: AVPlayer) {
        players.add(player)
        apply(to: player)
    }

    func refresh() {
        let updated = AudioHardware.devices()
        if devices != updated { devices = updated }
        let uid = resolvedDevice?.id
        let interruptedPlayback = uid == nil && lastResolvedUID != nil && players.allObjects.contains { $0.rate != 0 }
        for player in players.allObjects {
            if uid != lastResolvedUID { player.pause() }
            apply(to: player)
        }
        lastResolvedUID = uid
        revision += 1
        if interruptedPlayback, !AudioCaptureSession.suppressesAnnouncements {
            ApplicationMessageWindowCoordinator.shared.present(
                ApplicationMessageDescriptor(title: "Playback Output Unavailable", message: "Playback paused because the selected audio output disconnected. Choose an available Audio Playback Output in Settings.", initialFocus: .message),
                dismissed: {}
            )
        }
    }

    private func apply(to player: AVPlayer) {
        // Keep an unavailable explicit route silent; never fall back to speakers.
        player.isMuted = !isAvailable
        player.audioOutputDeviceUniqueID = selectedUID.isEmpty ? nil : selectedUID
        if !isAvailable { player.pause() }
    }
}
