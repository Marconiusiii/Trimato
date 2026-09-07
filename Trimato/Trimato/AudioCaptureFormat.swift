import CoreAudio

/// Prefer the editing rate without reducing an already higher hardware rate.
/// Unsupported or read-only devices retain their native format.
nonisolated enum AudioCaptureFormat {
    static func preferredRate(current: Double, available: [AudioValueRange]) -> Double {
        let candidates = available.flatMap { range -> [Double] in
            guard range.mMinimum.isFinite, range.mMaximum.isFinite,
                  range.mMinimum > 0, range.mMaximum >= range.mMinimum else { return [] }
            return [min(48000, range.mMaximum)].filter { $0 >= range.mMinimum }
        }
        return max(current, candidates.max() ?? current)
    }

    static func prepare(device: AudioDeviceID) {
        var nominal = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var current = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &nominal, 0, nil, &size, &current) == noErr else { return }
        var writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &nominal, &writable) == noErr, writable.boolValue else { return }
        var available = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = 0
        guard AudioObjectGetPropertyDataSize(device, &available, 0, nil, &size) == noErr, size > 0 else { return }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        let status = ranges.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &available, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return }
        var preferred = preferredRate(current: current, available: ranges)
        guard preferred > current else { return }
        // Failure is a supported fallback: capture validates the actual format after settling.
        _ = AudioObjectSetPropertyData(device, &nominal, 0, nil, UInt32(MemoryLayout<Double>.size), &preferred)
    }
}
