import AVFoundation
import Combine
import CoreAudio

@MainActor
final class AudioInputManager: ObservableObject {
    static let shared = AudioInputManager()
    private var reloadingPreferences = false
    private var preferencesObservation: AnyCancellable?
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var selectedUID: String { didSet { guard !reloadingPreferences else { return }; defaults.set(selectedUID, forKey: AppPreferenceKey.audioInputDevice); channel = 0; refresh() } }
    @Published var channel: Int { didSet { guard !reloadingPreferences else { return }; defaults.set(channel, forKey: AppPreferenceKey.audioInputChannel); refreshGain() } }
    @Published var bitDepth: Int { didSet { guard !reloadingPreferences else { return }; defaults.set(bitDepth, forKey: AppPreferenceKey.audioRecordingBitDepth) } }
    @Published private(set) var hardwareGain: Float?
    private let gainWorker = SerialMediaWorker(label: "com.marconius.trimato.input-gain")
    private var gainGeneration = UUID()
    private var gainTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var observation: AnyCancellable?
    let routes: AudioOutputManager
    var inputs: [AudioDeviceChoice] { routes.devices.filter { $0.inputChannels > 0 } }
    var resolvedDevice: AudioDeviceChoice? {
        AudioOutputManager.resolve(selectedUID: selectedUID, devices: inputs, defaultID: routes.defaultInputID)
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
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    static func requestPermissionIfNeeded() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func requestPermission() async { await Self.requestPermissionIfNeeded(); refresh() }

    func refresh() {
        reloadingPreferences = true
        let uid = defaults.string(forKey: AppPreferenceKey.audioInputDevice) ?? ""
        let savedChannel = max(0, defaults.integer(forKey: AppPreferenceKey.audioInputChannel))
        let depth = AppPreferences.audioRecordingBitDepth(in: defaults)
        if selectedUID != uid { selectedUID = uid }
        if channel != savedChannel { channel = savedChannel }
        if bitDepth != depth { bitDepth = depth }
        reloadingPreferences = false
        if let device = resolvedDevice, channel >= device.inputChannels { channel = 0 }
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission != current { permission = current }
        refreshGain()
    }

    private func refreshGain() {
        gainTask?.cancel()
        let id = UUID(); gainGeneration = id
        let device = resolvedDevice; let channel = channel
        gainTask = Task { [weak self, gainWorker] in
            let gain = try? await gainWorker.run { device.flatMap { AudioHardware.gain($0.deviceID, channel: channel) } }
            guard let self, gainGeneration == id else { return }
            if hardwareGain != gain { hardwareGain = gain }
        }
    }

    func setGain(_ value: Float) throws {
        guard let device = resolvedDevice else { throw AudioCaptureError.message("The selected microphone is unavailable.") }
        let requestedGain = min(1, max(0, value))
        try AudioHardware.setGain(requestedGain, id: device.deviceID, channel: channel)
        // Devices may quantize gain more coarsely than a native slider increment.
        // Keep successful requests so repeated adjustments can cross those steps.
        // A route change or app activation refreshes the hardware readback.
        gainGeneration = UUID()
        hardwareGain = requestedGain
    }
}
