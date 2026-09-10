import AVFoundation
import Foundation

/// Clip processing keeps its source rate. A mixed project uses the highest source
/// rate once, avoiding repeated reductions between filters, transitions and export.
nonisolated struct AudioProcessingFormat: Equatable, Sendable {
    let sampleRate: Double
    let channels: Int

    static func select(_ sources: [AudioProcessingFormat], stereoMix: Bool = false) throws -> Self {
        guard sources.allSatisfy({ $0.sampleRate.isFinite && $0.sampleRate > 0 && (1...2).contains($0.channels) }) else {
            throw AudioProcessingError.unsupportedFormat
        }
        return Self(sampleRate: sources.map(\.sampleRate).max() ?? 48_000,
                    channels: stereoMix ? 2 : sources.map(\.channels).max() ?? 2)
    }

    static func inspect(tracks: [AVAssetTrack], stereoMix: Bool) async throws -> Self {
        var formats: [Self] = []
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                if let value = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    formats.append(Self(sampleRate: value.mSampleRate, channels: Int(value.mChannelsPerFrame)))
                }
            }
        }
        return try select(formats, stereoMix: stereoMix)
    }

    /// Select one compatible representation, never combine alternate AAC/APAC tracks.
    static func selectedTrack(in asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            if !descriptions.isEmpty, descriptions.allSatisfy({ description in
                guard let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return false }
                return (1...2).contains(audio.mChannelsPerFrame) && audio.mFormatID != 0x61706163
            }) { return track }
        }
        if !tracks.isEmpty { throw AudioProcessingError.unsupportedFormat }
        return nil
    }

    static func exportTracks(in asset: AVAsset) async throws -> [AVAssetTrack] {
        if !(asset is AVComposition) {
            return try await selectedTrack(in: asset).map { [$0] } ?? []
        }
        var result: [AVAssetTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if try await !track.load(.formatDescriptions).isEmpty { result.append(track) }
        }
        return result
    }

    var aacBitRate: Int { min(160_000, Int(sampleRate * 3.5)) * channels }

    var floatPCMSettings: [String: Any] { pcmSettings(bitDepth: 32, floatingPoint: true) }

    func pcmSettings(bitDepth: Int, floatingPoint: Bool = false) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM,
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: bitDepth,
         AVLinearPCMIsFloatKey: floatingPoint,
         AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }
}

nonisolated enum AudioProcessingError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "Trimato's mixer supports mono and stereo audio. This source's audio format cannot be mixed without changing its channels or sample rate. The audio has not been downmixed."
    }
}
