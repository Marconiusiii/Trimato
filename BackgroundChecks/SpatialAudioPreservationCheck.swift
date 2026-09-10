import AVFoundation
import Cinematic
import CryptoKit
import Foundation

/// Standalone experiment, deliberately separate from Trimato's stereo mixer.
/// Build: xcrun swiftc -parse-as-library SpatialAudioPreservationCheck.swift -o /tmp/trimato-spatial-check
@main
struct SpatialAudioPreservationCheck {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Spatial preservation check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw CheckError.failed("Usage: spatial-check source.mov rendered-HDR.mov output-directory")
        }
        let source = URL(fileURLWithPath: arguments[1])
        let rendered = URL(fileURLWithPath: arguments[2])
        let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let trimmedRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48_000),
                                      duration: CMTime(seconds: 4, preferredTimescale: 48_000))
        guard duration >= trimmedRange.end else { throw CheckError.failed("Source must be at least five seconds.") }
        let original = try await inspect(asset, label: "original")
        guard original.audio.count == 2, original.audio.contains(where: { $0.codec == 0x61706163 }),
              original.groups.count == 1, original.groups[0].count == 2 else {
            throw CheckError.failed("This prototype requires an iPhone recording with paired AAC/APAC tracks.")
        }
        var results: [Snapshot] = []
        for (name, range, replaceVideo) in [
            ("spatial-original-video", CMTimeRange(start: .zero, duration: duration), false),
            ("spatial-trim-1s-to-5s", trimmedRange, false),
            ("spatial-Trimato-HDR", CMTimeRange(start: .zero, duration: duration), true),
            ("spatial-Trimato-HDR-trim-1s-to-5s", trimmedRange, true)
        ] {
            let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + name + ".mov")
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw CheckError.failed("Refusing to replace existing output: \(output.path)")
            }
            let movie = AVMutableMovie(url: source, options: nil)
            if replaceVideo {
                let renderedAsset = AVURLAsset(url: rendered)
                guard let renderedTrack = try await renderedAsset.loadTracks(withMediaType: .video).first else {
                    throw CheckError.failed("Rendered HDR movie has no video.")
                }
                for track in movie.tracks(withMediaType: .video) { movie.removeTrack(track) }
                guard let replacement = movie.addMutableTrack(withMediaType: .video, copySettingsFrom: renderedTrack, options: nil) else {
                    throw CheckError.failed("Cannot create replacement video track.")
                }
                try replacement.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                of: renderedTrack, at: .zero, copySampleData: false)
            }
            guard let session = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else {
                throw CheckError.failed("Cannot create passthrough export.")
            }
            session.audioTrackGroupHandling = .preserveAlternateTracks
            session.timeRange = range
            session.shouldOptimizeForNetworkUse = true
            try await session.export(to: output, as: .mov)
            let result = try await inspect(AVURLAsset(url: output), label: output.lastPathComponent)
            guard result.audio.map(\.signature) == original.audio.map(\.signature),
                  result.groups.map(\.count) == original.groups.map(\.count),
                  result.spatial == original.spatial,
                  abs(result.duration - range.duration.seconds) < 0.001 else {
                throw CheckError.failed("Native audio preservation checks failed for \(output.lastPathComponent).")
            }
            results.append(result)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(source: source.lastPathComponent, renderedVideo: rendered.lastPathComponent,
                            original: original, exports: results)
        try encoder.encode(report).write(to: directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-native-validation.json"), options: .withoutOverwriting)
    }

    static func inspect(_ asset: AVAsset, label: String) async throws -> Snapshot {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let groups = try await asset.load(.trackGroups)
        let duration = try await asset.load(.duration).seconds
        print("FILE \(label) duration=\(duration) groups=\(groups.map(\.trackIDs))")
        var audio: [Audio] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let description = descriptions.first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw CheckError.failed("Expected one audio format per source track.")
            }
            let fallbacks = try await track.loadAssociatedTracks(ofType: .audioFallback)
            var fallbackCodecs: [UInt32] = []
            for fallback in fallbacks {
                for format in try await fallback.load(.formatDescriptions) {
                    fallbackCodecs.append(CMFormatDescriptionGetMediaSubType(format))
                }
            }
            var layoutSize = 0
            let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
            let layoutHash = layout.map { digest(Data(bytes: $0, count: layoutSize)) }
            let item = Audio(id: track.trackID, codec: format.mFormatID, channels: format.mChannelsPerFrame,
                             sampleRate: format.mSampleRate, enabled: try await track.load(.isEnabled),
                             fallbackCodecs: fallbackCodecs, layoutHash: layoutHash)
            audio.append(item)
            print("AUDIO id=\(item.id) codec=\(item.codec) channels=\(item.channels) enabled=\(item.enabled)")
        }
        var spatial = Spatial(recognized: false, error: "Requires macOS 26")
        if #available(macOS 26, *) {
            do {
                let info = try await CNAssetSpatialAudioInfo(asset: asset)
                spatial = Spatial(recognized: true, metadataHash: digest(info.spatialAudioMixMetadata),
                                  style: info.defaultRenderingStyle.rawValue, intensity: info.defaultEffectIntensity)
            } catch {
                let error = error as NSError
                spatial = Spatial(recognized: false, error: "\(error.domain):\(error.code)")
            }
        }
        print("SPATIAL \(spatial)")
        fflush(stdout)
        return Snapshot(file: label, duration: duration, groups: groups.map { $0.trackIDs.map(\.int32Value) },
                        audio: audio, spatial: spatial)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    struct Audio: Codable {
        let id: Int32
        let codec: UInt32
        let channels: UInt32
        let sampleRate: Double
        let enabled: Bool
        let fallbackCodecs: [UInt32]
        let layoutHash: String?
        var signature: String { "\(codec)/\(channels)/\(sampleRate)/\(enabled)/\(fallbackCodecs)/\(layoutHash ?? "none")" }
    }
    struct Spatial: Codable, Equatable {
        let recognized: Bool
        var error: String? = nil
        var metadataHash: String? = nil
        var style: Int? = nil
        var intensity: Float? = nil
    }
    struct Snapshot: Codable {
        let file: String
        let duration: Double
        let groups: [[Int32]]
        let audio: [Audio]
        let spatial: Spatial
    }
    struct Report: Codable {
        let source: String
        let renderedVideo: String
        let original: Snapshot
        let exports: [Snapshot]
    }
    enum CheckError: Error { case failed(String) }
}
