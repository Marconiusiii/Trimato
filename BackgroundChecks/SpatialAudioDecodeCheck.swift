import AVFoundation
import Foundation

/// Compares native decoded AAC and APAC samples with the original recording.
/// This does not play audio or change the system's output route.
@main
struct SpatialAudioDecodeCheck {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Spatial decode check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure.invalid("Usage: spatial-decode-check source-directory results-directory")
        }
        let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let resultsDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
        var results: [Comparison] = []
        for name in ["4K_30fps.MOV", "4K_60fps.mov", "4K_120fps.MOV"] {
            let source = sourceDirectory.appendingPathComponent(name)
            let original = try await decode(source)
            for suffix in ["spatial-original-video", "spatial-trim-1s-to-5s",
                           "spatial-Trimato-HDR", "spatial-Trimato-HDR-trim-1s-to-5s"] {
                let file = source.deletingPathExtension().lastPathComponent + "-" + suffix + ".mov"
                let output = try await decode(resultsDirectory.appendingPathComponent(file))
                guard output.keys == original.keys else { throw Failure.invalid("Changed audio codecs: \(file)") }
                for codec in original.keys.sorted() {
                    let before = original[codec]!, after = output[codec]!
                    let trimmed = suffix.contains("trim-")
                    let offset = trimmed ? Int(before.rate) * before.channels : 0
                    let expectedCount = trimmed ? Int(before.rate * 4) * before.channels : before.samples.count
                    guard before.channels == after.channels, before.rate == after.rate,
                          after.samples.count == expectedCount,
                          before.samples.count >= offset + after.samples.count else {
                        throw Failure.invalid("Changed audio length or format: \(file), \(codec)")
                    }
                    var maximum = 0.0, squaredError = 0.0
                    for index in after.samples.indices {
                        let difference = Double(before.samples[offset + index]) - Double(after.samples[index])
                        guard difference.isFinite else { throw Failure.invalid("Nonfinite decoded audio") }
                        maximum = max(maximum, abs(difference))
                        squaredError += difference * difference
                    }
                    // Float32 decoder rounding is allowed; a gain or channel change is not.
                    guard maximum <= 0.000001 else {
                        throw Failure.invalid("Decoded audio differs: \(file), \(codec), maximum error \(maximum)")
                    }
                    results.append(Comparison(file: file, codec: codec, channels: after.channels,
                                              sampleRate: after.rate, frames: after.samples.count / after.channels,
                                              sourceStartSeconds: trimmed ? 1 : 0, maximumAbsoluteError: maximum,
                                              rmsError: sqrt(squaredError / Double(after.samples.count))))
                    print("PASS \(file) codec=\(codec) maxError=\(maximum)")
                    fflush(stdout)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: resultsDirectory.appendingPathComponent("decoded-audio-validation.json"),
                                          options: .withoutOverwriting)
    }

    struct PCM {
        let channels: Int
        let rate: Double
        let samples: [Float]
    }

    static func decode(_ url: URL) async throws -> [UInt32: PCM] {
        let asset = AVURLAsset(url: url)
        var result: [UInt32: PCM] = [:]
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let description = descriptions.first,
                  let sourceFormat = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw Failure.invalid("Missing source audio format")
            }
            let codec = sourceFormat.mFormatID
            guard result[codec] == nil else { throw Failure.invalid("Ambiguous audio tracks") }
            let channels = Int(sourceFormat.mChannelsPerFrame)
            var layoutSize = 0
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) else {
                throw Failure.invalid("Missing channel layout")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sourceFormat.mSampleRate, AVNumberOfChannelsKey: channels,
                AVChannelLayoutKey: Data(bytes: layout, count: layoutSize)
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { throw Failure.invalid("Cannot read native audio") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.invalid("Cannot start decoder") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                let frameCount = CMSampleBufferGetNumSamples(buffer)
                let expectedTime = Double(samples.count / channels) / sourceFormat.mSampleRate
                guard abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - expectedTime) < 1 / sourceFormat.mSampleRate,
                      let block = CMSampleBufferGetDataBuffer(buffer),
                      CMBlockBufferGetDataLength(block) == frameCount * channels * MemoryLayout<Float>.size else {
                    throw Failure.invalid("Unexpected decoded audio layout or timestamps")
                }
                var values = [Float](repeating: 0, count: frameCount * channels)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw Failure.invalid("Cannot copy decoded samples") }
                samples.append(contentsOf: values)
            }
            guard reader.status == .completed, !samples.isEmpty else {
                throw reader.error ?? Failure.invalid("Incomplete audio decoding")
            }
            result[codec] = PCM(channels: channels, rate: sourceFormat.mSampleRate, samples: samples)
        }
        guard result.count == 2 else { throw Failure.invalid("Expected AAC and APAC audio") }
        return result
    }

    struct Comparison: Codable {
        let file: String
        let codec: UInt32
        let channels: Int
        let sampleRate: Double
        let frames: Int
        let sourceStartSeconds: Int
        let maximumAbsoluteError: Double
        let rmsError: Double
    }
    enum Failure: Error { case invalid(String) }
}
