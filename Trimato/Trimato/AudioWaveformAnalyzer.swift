import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

nonisolated struct AudioWaveformData: Equatable, Sendable {
    var samples: [Float]
    var duration: Double

    func samples(
        for sourceRanges: [CMTimeRange],
        maximumCount: Int = 2_048
    ) -> [Float] {
        guard duration > 0, !samples.isEmpty, maximumCount > 0 else { return [] }
        var selected: [Float] = []
        for range in sourceRanges where range.isValid && range.duration > .zero {
            let startFraction = min(max(range.start.seconds / duration, 0), 1)
            let endFraction = min(max(range.end.seconds / duration, startFraction), 1)
            let lower = min(Int((startFraction * Double(samples.count)).rounded(.down)), samples.count)
            let upper = min(Int((endFraction * Double(samples.count)).rounded(.up)), samples.count)
            if lower < upper { selected.append(contentsOf: samples[lower..<upper]) }
        }
        return Self.downsample(selected, maximumCount: maximumCount)
    }

    static func downsample(_ values: [Float], maximumCount: Int) -> [Float] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        return (0..<maximumCount).map { bucket in
            let lower = bucket * values.count / maximumCount
            let upper = max((bucket + 1) * values.count / maximumCount, lower + 1)
            return values[lower..<min(upper, values.count)].max() ?? 0
        }
    }
}

nonisolated enum AudioWaveformAnalyzer {
    static func analyze(asset: AVAsset, maximumCount: Int = 4_096) async throws -> AudioWaveformData {
        try await Task.detached(priority: .utility) {
            try await analyzeSynchronously(asset: asset, maximumCount: maximumCount)
        }.value
    }

    private static func analyzeSynchronously(
        asset: AVAsset,
        maximumCount: Int
    ) async throws -> AudioWaveformData {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return AudioWaveformData(samples: [], duration: 0)
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, maximumCount > 0 else {
            return AudioWaveformData(samples: [], duration: max(duration, 0))
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaSourceError.unreadable("Trimato could not read the audio samples for the waveform.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaSourceError.unreadable("Trimato could not begin waveform analysis.")
        }

        var peaks = Array(repeating: Float.zero, count: maximumCount)
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, length >= MemoryLayout<Float>.size else {
                continue
            }
            let sampleCount = length / MemoryLayout<Float>.size
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
            let streamDescription = format.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let channelCount = max(Int(streamDescription?.mChannelsPerFrame ?? 1), 1)
            let frameCount = max(CMSampleBufferGetNumSamples(sampleBuffer), 1)
            let floatPointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let declaredDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
            let sampleRate = streamDescription?.mSampleRate ?? 0
            let bufferDuration = declaredDuration.isFinite && declaredDuration > 0
                ? declaredDuration
                : (sampleRate > 0 ? Double(frameCount) / sampleRate : 0)
            for index in 0..<sampleCount {
                let frameIndex = min(index / channelCount, frameCount - 1)
                let fractionWithinBuffer = frameCount > 1 ? Double(frameIndex) / Double(frameCount - 1) : 0
                let time = start + bufferDuration * fractionWithinBuffer
                let bucket = min(max(Int(time / duration * Double(maximumCount)), 0), maximumCount - 1)
                peaks[bucket] = max(peaks[bucket], abs(floatPointer[index]))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? MediaSourceError.unreadable("Waveform analysis stopped before it finished.")
        }
        let maximum = peaks.max() ?? 0
        if maximum > 0 { peaks = peaks.map { min(max($0 / maximum, 0), 1) } }
        return AudioWaveformData(samples: peaks, duration: duration)
    }
}
