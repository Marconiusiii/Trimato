import AVFoundation
import Combine
import CoreAudio

@MainActor
final class AudioInputManager: ObservableObject {
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var selectedUID: String { didSet { defaults.set(selectedUID, forKey: AppPreferenceKey.audioInputDevice); channel = 0; refresh() } }
    @Published var channel: Int { didSet { defaults.set(channel, forKey: AppPreferenceKey.audioInputChannel); refreshGain() } }
    @Published var bitDepth: Int { didSet { defaults.set(bitDepth, forKey: AppPreferenceKey.audioRecordingBitDepth) } }
    @Published private(set) var hardwareGain: Float?
    private let defaults: UserDefaults
    private var observation: AnyCancellable?
    let routes: AudioOutputManager
    var inputs: [AudioDeviceChoice] { routes.devices.filter { $0.inputChannels > 0 } }
    var resolvedDevice: AudioDeviceChoice? {
        AudioOutputManager.resolve(selectedUID: selectedUID, devices: inputs, defaultID: AudioHardware.defaultDevice(input: true))
    }
    var permissionTitle: String {
        switch permission {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unavailable"
        }
    }

    init(defaults: UserDefaults = .standard, routes: AudioOutputManager? = nil) {
        self.defaults = defaults
        let routes = routes ?? AudioOutputManager.shared
        self.routes = routes
        selectedUID = defaults.string(forKey: AppPreferenceKey.audioInputDevice) ?? ""
        channel = max(0, defaults.integer(forKey: AppPreferenceKey.audioInputChannel))
        bitDepth = AppPreferences.audioRecordingBitDepth(in: defaults)
        observation = routes.$revision.sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    static func requestPermissionIfNeeded() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func requestPermission() async { await Self.requestPermissionIfNeeded(); refresh() }

    func refresh() {
        permission = AVCaptureDevice.authorizationStatus(for: .audio)
        refreshGain()
    }

    private func refreshGain() {
        let gain = resolvedDevice.flatMap { AudioHardware.gain($0.deviceID, channel: channel) }
        if hardwareGain != gain { hardwareGain = gain }
    }

    func setGain(_ value: Float) throws {
        guard let device = resolvedDevice else { throw AudioCaptureError.message("The selected microphone is unavailable.") }
        try AudioHardware.setGain(value, id: device.deviceID, channel: channel)
        refreshGain()
    }
}
