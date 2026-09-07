import AVFoundation
import MediaToolbox
import Foundation

/// One state per composition audio track; no waits or model access on the render callback.
nonisolated final class TrackMixProcessor: @unchecked Sendable {
    let trackID: UUID
    private let lock = NSLock()
    private var target: StereoMixMatrix
    private var current: StereoMixMatrix
    private var format = AudioStreamBasicDescription()
    private var step = StereoMixMatrix.silent
    private var remaining = 0
    private var destination: StereoMixMatrix

    init(trackID: UUID, matrix: StereoMixMatrix) {
        self.trackID = trackID
        target = matrix; current = matrix; destination = matrix
    }
    func update(_ matrix: StereoMixMatrix) {
        lock.lock(); target = matrix; lock.unlock()
    }

    func copyProcessor() -> TrackMixProcessor {
        lock.lock(); let matrix = target; lock.unlock()
        return TrackMixProcessor(trackID: trackID, matrix: matrix)
    }

    func makeTap() throws -> MTAudioProcessingTap {
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let state = Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.prepare(format.pointee)
            }, unprepare: nil,
            process: { tap, requested, _, buffers, frames, flags in
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, frames)
                guard status == noErr else { frames.pointee = 0; return }
                let state = Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.process(buffers, frames: frames.pointee)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<TrackMixProcessor>.fromOpaque(callbacks.clientInfo!).release()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return tap
    }

    func prepare(_ value: AudioStreamBasicDescription) { format = value }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        if lock.try() {
            let next = target
            lock.unlock()
            if next != destination {
                destination = next
                remaining = max(Int(format.mSampleRate * 0.01), 1)
                let n = Double(remaining)
                step = StereoMixMatrix(ll: (next.ll-current.ll)/n, lr: (next.lr-current.lr)/n,
                                       rl: (next.rl-current.rl)/n, rr: (next.rr-current.rr)/n)
            }
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM,
              (1...2).contains(format.mChannelsPerFrame),
              buffers.count >= (planar ? Int(format.mChannelsPerFrame) : 1) else { return }
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[planar ? 1 : 0].mData else {
            processOtherPCM(buffers, frames: frames, planar: planar)
            return
        }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right = rightData.assumingMemoryBound(to: Float.self)
        let stride = planar ? 1 : 2
        let offset = planar ? 0 : 1
        let capacity = min(Int(buffers[0].mDataByteSize), Int(buffers[planar ? 1 : 0].mDataByteSize)) / (4 * stride)
        for frame in 0..<min(frames, capacity) {
            advanceMatrix()
            let index = frame * stride
            let l = Double(left[index]), r = Double(right[index+offset])
            left[index] = Float(l * current.ll + r * current.lr)
            right[index+offset] = Float(l * current.rl + r * current.rr)
        }
    }

    private func advanceMatrix() {
        if remaining > 0 {
            current.ll += step.ll; current.lr += step.lr
            current.rl += step.rl; current.rr += step.rr
            remaining -= 1
            if remaining == 0 { current = destination }
        }
    }

    private func processOtherPCM(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, planar: Bool) {
        let channels = Int(format.mChannelsPerFrame)
        let bytes = Int(format.mBytesPerFrame) / (planar ? 1 : channels)
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bits = format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 ? bytes * 8 : Int(format.mBitsPerChannel)
        guard (1...8).contains(bytes),
              (isFloat && [32, 64].contains(bits) || !isFloat && bits > 0 && bits <= 32),
              let first = buffers[0].mData else { return }
        let stride = bytes * (planar ? 1 : channels)
        let rightBuffer = planar && channels == 2 ? 1 : 0
        guard let second = buffers[rightBuffer].mData else { return }
        let capacity = min(Int(buffers[0].mDataByteSize), Int(buffers[rightBuffer].mDataByteSize)) / stride
        let scale = pow(2, Double(bits - 1))
        func read(_ pointer: UnsafeMutableRawPointer) -> Double {
            var raw: UInt64 = 0
            let data = pointer.assumingMemoryBound(to: UInt8.self)
            for index in 0..<bytes { raw |= UInt64(data[index]) << (8 * (bigEndian ? bytes-1-index : index)) }
            if isFloat { return bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw) }
            let mask = (UInt64(1) << bits) - 1
            raw &= mask
            if !signed { return (Double(raw) - scale) / scale }
            if raw & (UInt64(1) << (bits-1)) != 0 { raw |= ~mask }
            return Double(Int64(bitPattern: raw)) / scale
        }
        func write(_ value: Double, _ pointer: UnsafeMutableRawPointer) {
            let raw: UInt64
            if isFloat { raw = bits == 32 ? UInt64(Float(value).bitPattern) : value.bitPattern }
            else {
                let bounded = min(max(value.isFinite ? value : 0, -1), 1 - 1 / scale)
                raw = UInt64(bitPattern: Int64((bounded * scale).rounded()) + (signed ? 0 : Int64(scale)))
            }
            let data = pointer.assumingMemoryBound(to: UInt8.self)
            for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: raw >> (8 * (bigEndian ? bytes-1-index : index))) }
        }
        for frame in 0..<min(frames, capacity) {
            advanceMatrix()
            let leftPointer = first.advanced(by: frame * stride)
            let rightPointer = second.advanced(by: frame * stride + (planar || channels == 1 ? 0 : bytes))
            let left = read(leftPointer), right = read(rightPointer)
            let l = left * current.ll + right * current.lr
            let r = left * current.rl + right * current.rr
            if channels == 1 { write((l+r)/2, leftPointer) }
            else { write(l, leftPointer); write(r, rightPointer) }
        }
    }

}
