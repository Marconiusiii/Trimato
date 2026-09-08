import AudioToolbox
import Foundation
import os

/// The queue converts the device's hardware format to this interleaved client format.
/// Choosing a client format does not change the device's nominal hardware rate.
nonisolated enum AudioCaptureConfiguration {
    static func format(sampleRate: Double, channels: Int, selectedChannel: Int) throws -> AudioStreamBasicDescription {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0,
              channels <= Int(UInt32.max) / (4096 * MemoryLayout<Float>.size),
              selectedChannel >= 0, selectedChannel < channels else {
            throw AudioCaptureError.message("The selected input does not currently provide the requested audio channel or a valid sample rate.")
        }
        let bytes = UInt32(channels * MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: bytes, mFramesPerPacket: 1,
            mBytesPerFrame: bytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status != noErr else { return }
        let detail = "\(operation) failed (Core Audio \(status))."
        Logger(subsystem: "com.marconius.trimato", category: "Audio capture").error("\(detail, privacy: .public)")
        throw AudioCaptureSetupError(status: status, operation: operation)
    }

    static func selectDevice(_ queue: AudioQueueRef, uid: String, systemDefault: Bool, operation: String,
                             setProperty: (AudioQueueRef, AudioQueuePropertyID, UnsafeRawPointer, UInt32) -> OSStatus = {
                                 AudioQueueSetProperty($0, $1, $2, $3)
                             }) throws {
        // A new queue already tracks the appropriate system default. Do not replace it.
        guard !systemDefault else { return }
        let value = uid as CFString
        var reference = Unmanaged.passUnretained(value).toOpaque()
        let status = withExtendedLifetime(value) {
            setProperty(queue, kAudioQueueProperty_CurrentDevice, &reference,
                                  UInt32(MemoryLayout<UnsafeMutableRawPointer>.size))
        }
        try check(status, operation: operation)
    }
}

nonisolated struct AudioCaptureSetupError: LocalizedError {
    let status: OSStatus
    let operation: String
    var canRetry: Bool {
        [kAudioQueueErr_InvalidDevice, kAudioQueueErr_QueueInvalidated,
         kAudioQueueErr_CannotStartYet, kAudioHardwareBadDeviceError].contains(status)
    }
    var errorDescription: String? {
        if status == kAudioQueueErr_Permissions {
            return "macOS denied access to the audio input. Check Trimato's microphone permission in System Settings."
        }
        return "\(operation) failed (Core Audio \(status))."
    }
}
