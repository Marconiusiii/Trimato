import AVFoundation
import Foundation

/// One sample-accurate edit plan drives both the spatial master and its stereo alternative.
/// Working data stays in Float32 PCM; exports do not add a lossy encoding stage.
nonisolated struct SpatialAudioRenderPlan: Sendable {
    struct Region: Sendable {
        var sourceStart: Double
        var start: Double
        var duration: Double
        var gain: Float
        var ramp: (Float, Float)? = nil
        var fades: [(Double, Double, Float, Float)] = []
        var exclusions: [(Double, Double)] = []
        var sourceURL: URL? = nil

        func level(at frame: Int, rate: Double) -> Float {
            func boundary(_ time: Double) -> Int { Int((time * rate).rounded()) }
            let first = boundary(start), last = boundary(start + duration)
            guard frame >= first, frame < last,
                  !exclusions.contains(where: { frame >= boundary($0.0) && frame < boundary($0.1) }) else { return 0 }
            var value = gain
            if let ramp { value *= ramp.0 + Float(frame - first) / Float(last - first) * (ramp.1 - ramp.0) }
            for (begin, length, a, b) in fades {
                let startFrame = boundary(begin), endFrame = boundary(begin + length)
                if frame >= startFrame, frame < endFrame { value *= a + Float(frame - startFrame) / Float(endFrame - startFrame) * (b - a) }
            }
            return value
        }

    }
    let source: URL
    let duration: Double
    let regions: [Region]

    static func validate(_ project: TrimatoProject) throws {
        for track in project.tracks where track.kind == .audio {
            var mix = track.mix
            mix.volumeDB = 0
            guard mix == .neutral else {
                throw SpatialAudioError.unsupported("Pan, stereo width, balance, and channel routing are not available for Spatial Audio yet. Volume, Mute, and fades are supported.")
            }
            for clip in track.clips {
                var settings = clip.audioSettings
                settings.gainDecibels = 0
                guard settings.isNeutral, !clip.filters.contains(where: { $0.enabled && $0.kind.isAudio }) else {
                    throw SpatialAudioError.unsupported("This audio effect is not available for Spatial Audio yet. Volume and audio transitions are supported.")
                }
            }
        }
        guard project.descriptionDucking.ranges(in: project).isEmpty,
              !project.cutaways.contains(where: { $0.audioMode == .sourceAudio }) else {
            throw SpatialAudioError.unsupported("Ducking and cutaways that replace the soundtrack are not available for Spatial Audio yet.")
        }
    }

    static func project(_ project: TrimatoProject, source: URL, track: TimelineTrack, urls: [UUID: URL] = [:]) throws -> Self {
        try validate(project)
        var regions: [Region] = []
        let transitions = project.transitions.filter { $0.trackID == track.id }
        let exclusions: [(Double, Double)] = transitions.compactMap { transition in
            guard transition.edge == .between, case .audio = transition.kind,
                  let clip = track.clips.first(where: { $0.id == transition.trailingClipID }) else { return nil }
            let start = clip.timelineStart.seconds - transition.duration.seconds / 2
            return (start, start + transition.duration.seconds)
        }
        func gain(_ clip: TimelineClip) -> Float {
            track.isMuted ? 0 : Float(pow(10, (project.masterVolumeDB + track.mix.volumeDB + clip.audioSettings.gainDecibels) / 20))
        }
        for clip in track.clips {
            var fades: [(Double, Double, Float, Float)] = []
            for transition in transitions where transition.kind == .audio(.fade) {
                if transition.edge == .intro, transition.trailingClipID == clip.id {
                    fades.append((clip.timelineStart.seconds, transition.duration.seconds, 0, 1))
                } else if transition.edge == .outro, transition.leadingClipID == clip.id {
                    fades.append((clip.timelineEnd.seconds - transition.duration.seconds, transition.duration.seconds, 1, 0))
                }
            }
            var cursor = clip.visibleTimelineStart.seconds
            for segment in clip.visibleSegments {
                regions.append(Region(sourceStart: segment.sourceRange.start.seconds, start: cursor,
                    duration: segment.duration.seconds, gain: gain(clip), fades: fades, exclusions: exclusions, sourceURL: urls[clip.assetID]))
                cursor += segment.duration.seconds
            }
        }
        for transition in transitions where transition.edge == .between {
            guard case .audio(let type) = transition.kind,
                  let leading = track.clips.first(where: { $0.id == transition.leadingClipID }),
                  let trailing = track.clips.first(where: { $0.id == transition.trailingClipID }),
                  let end = leading.segments.last?.sourceRange.end.seconds,
                  let begin = trailing.segments.first?.sourceRange.start.seconds else { continue }
            let length = transition.duration.seconds, half = length / 2
            let start = trailing.timelineStart.seconds - half
            if type == .fadeOutIn {
                regions.append(Region(sourceStart: end - half, start: start, duration: half, gain: gain(leading), ramp: (1, 0), sourceURL: urls[leading.assetID]))
                regions.append(Region(sourceStart: begin, start: start + half, duration: half, gain: gain(trailing), ramp: (0, 1), sourceURL: urls[trailing.assetID]))
            } else if type == .crossFade {
                regions.append(Region(sourceStart: end - half, start: start, duration: length, gain: gain(leading), ramp: (1, 0), sourceURL: urls[leading.assetID]))
                regions.append(Region(sourceStart: begin - half, start: start, duration: length, gain: gain(trailing), ramp: (0, 1), sourceURL: urls[trailing.assetID]))
            }
        }
        guard project.duration.seconds.isFinite, project.duration.seconds > 0,
              regions.allSatisfy({ $0.gain.isFinite && $0.duration.isFinite && $0.duration > 0 }) else { throw SpatialAudioError.processingFailure(#line) }
        return Self(source: source, duration: project.duration.seconds, regions: regions)
    }

    /// Decoded sources are temporary files rather than an entire recording held in RAM.
    private struct PCMFile {
        let url: URL
        let rate: Double
        let channels: Int
        let layout: Data
        let format: CMAudioFormatDescription
        let frames: Int
    }

    static func validateSources(_ urls: Set<URL>) async throws {
        var sources: [[PCMFile]] = []
        for url in urls {
            var formats: [PCMFile] = []
            for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
                guard let description = try await track.load(.formatDescriptions).first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw SpatialAudioError.invalidMovie }
                if format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame > 2, !isNativeFloat(format) {
                    throw SpatialAudioError.unsupported("This spatial recording's audio format needs High-quality Stereo for processing.")
                }
                formats.append(PCMFile(url: url, rate: format.mSampleRate, channels: Int(format.mChannelsPerFrame),
                    layout: try SpatialAudioPlan.channelLayout(description), format: description, frames: 0))
            }
            formats.sort { $0.channels < $1.channels }
            guard formats.count == 2, formats[0].channels == 2, formats[1].channels >= 4 else {
                throw SpatialAudioError.unsupported("This recording does not contain compatible spatial and stereo audio. Choose High-quality Stereo for this edit.")
            }
            sources.append(formats)
        }
        guard let reference = sources.max(by: { $0[1].channels < $1[1].channels }),
              sources.allSatisfy({ files in zip(files, reference).allSatisfy { $0.rate == $1.rate && compatible($0, with: $1) } }) else {
            throw SpatialAudioError.unsupported("These recordings use different spatial audio layouts or sample rates. Choose High-quality Stereo for this edit.")
        }
    }

    private static func compatible(_ input: PCMFile, with output: PCMFile) -> Bool {
        if input.channels == output.channels && input.layout == output.layout { return true }
        // The Cinematic layout adds a center channel to the same SN3D ACN 0–3
        // coefficients used by standard iPhone captures. Keep those coefficients
        // untouched and leave the absent center channel silent.
        guard input.channels == 4, output.channels == 5,
              input.layout.count >= 12, output.layout.count >= 112 else { return false }
        let tag = input.layout.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard tag == kAudioChannelLayoutTag_HOA_ACN_SN3D | 4 else { return false }
        let labels = output.layout.withUnsafeBytes { data in
            (0..<5).map { data.loadUnaligned(fromByteOffset: 12 + $0 * 20, as: UInt32.self) }
        }
        return labels == [131072, 131073, 131074, 131075, kAudioChannelLabel_Center]
    }

    private static func decode(_ track: AVAssetTrack, asset: AVAsset, to url: URL) async throws -> PCMFile {
        guard let description = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw SpatialAudioError.processingFailure(#line) }
        let layoutData = try SpatialAudioPlan.channelLayout(description)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame), AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        // Re-converting an already matching PCM layout can remix hybrid
        // ambisonic-plus-center recordings in Core Audio. Read those samples directly.
        let nativeFloat = Self.isNativeFloat(asbd)
        guard asbd.mFormatID != kAudioFormatLinearPCM || asbd.mChannelsPerFrame <= 2 || nativeFloat else {
            throw SpatialAudioError.unsupported("Trimato cannot safely apply audio changes to this spatial recording's format yet. Keep its original audio to export it.")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nativeFloat ? nil : settings)
        guard reader.canAdd(output) else { throw SpatialAudioError.processingFailure(#line) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpatialAudioError.processingFailure(#line) }
        defer { reader.cancelReading() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var frames = 0
        var pcmFormat: CMAudioFormatDescription?
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(buffer) == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(buffer),
                  abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - Double(frames) / asbd.mSampleRate) < 1 / asbd.mSampleRate else {
                throw SpatialAudioError.unsupported("This recording has audio timing that Trimato cannot safely process yet.")
            }
            pcmFormat = CMSampleBufferGetFormatDescription(buffer)
            let bytes = CMBlockBufferGetDataLength(block)
            var data = Data(count: bytes)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == noErr, bytes == CMSampleBufferGetNumSamples(buffer) * Int(asbd.mChannelsPerFrame) * 4 else { throw SpatialAudioError.processingFailure(#line) }
            try file.write(contentsOf: data)
            frames += CMSampleBufferGetNumSamples(buffer)
        }
        guard reader.status == .completed, let pcmFormat else { throw reader.error ?? SpatialAudioError.processingFailure(#line) }
        return PCMFile(url: url, rate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), layout: layoutData, format: pcmFormat, frames: frames)
    }

    static func isNativeFloat(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
            format.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0 &&
            format.mBytesPerFrame == format.mChannelsPerFrame * 4
    }

    @concurrent
    func render() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrimatoSpatial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sources: [URL: [PCMFile]] = [:]
        for url in Set(regions.map { $0.sourceURL ?? source }) {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 2 else { throw SpatialAudioError.unsupported("This recording does not contain compatible spatial and stereo audio. Choose High-quality Stereo for this edit.") }
            var files: [PCMFile] = []
            for track in tracks {
                files.append(try await Self.decode(track, asset: asset, to: directory.appendingPathComponent(UUID().uuidString + ".pcm")))
            }
            files.sort { $0.channels < $1.channels }
            guard files[0].channels == 2, files[1].channels >= 4, files[0].rate == files[1].rate else { throw SpatialAudioError.invalidMovie }
            sources[url] = files
        }
        guard let decoded = sources.values.max(by: { $0[1].channels < $1[1].channels }) else { throw SpatialAudioError.invalidMovie }
        guard sources.values.allSatisfy({ files in zip(files, decoded).allSatisfy { $0.rate == $1.rate && Self.compatible($0, with: $1) } }) else {
            throw SpatialAudioError.unsupported("These recordings use different spatial audio layouts or sample rates. Choose High-quality Stereo for this edit.")
        }
        let raw = directory.appendingPathComponent("render.mov")
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        writer.movieTimeScale = Int32(decoded[0].rate)
        let inputs = decoded.map { AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: $0.format) }
        for input in inputs {
            guard writer.canAdd(input) else { throw SpatialAudioError.processingFailure(#line) }
            writer.add(input)
        }
        inputs[1].addTrackAssociation(withTrackOf: inputs[0], type: AVAssetTrack.AssociationType.audioFallback.rawValue)
        guard writer.startWriting() else { throw writer.error ?? SpatialAudioError.processingFailure(#line) }
        writer.startSession(atSourceTime: .zero)
        var handles: [URL: [FileHandle]] = [:]
        defer { for files in handles.values { for file in files { try? file.close() } }; if writer.status == .writing { writer.cancelWriting() } }
        for (url, files) in sources { handles[url] = try files.map { try FileHandle(forReadingFrom: $0.url) } }
        let rate = decoded[0].rate
        let total = Int((duration * rate).rounded())
        for start in stride(from: 0, to: total, by: 4096) {
            try Task.checkCancellation()
            let count = min(4096, total - start)
            for index in decoded.indices {
                let pcm = decoded[index]
                var samples = [Float](repeating: 0, count: count * pcm.channels)
                for region in regions {
                    let url = region.sourceURL ?? source
                    guard let inputPCM = sources[url]?[index], let handle = handles[url]?[index] else { throw SpatialAudioError.invalidMovie }
                    let first = max(start, Int((region.start * rate).rounded()))
                    let last = min(start + count, Int(((region.start + region.duration) * rate).rounded()))
                    guard first < last else { continue }
                    let sourceFirst = Int((region.sourceStart * rate).rounded()) + first - Int((region.start * rate).rounded())
                    let validFirst = max(sourceFirst, 0), validLast = min(sourceFirst + last - first, inputPCM.frames)
                    guard validFirst < validLast else { continue }
                    try handle.seek(toOffset: UInt64(validFirst * inputPCM.channels * 4))
                    let data = try handle.read(upToCount: (validLast - validFirst) * inputPCM.channels * 4) ?? Data()
                    guard data.count == (validLast - validFirst) * inputPCM.channels * 4 else { throw SpatialAudioError.processingFailure(#line) }
                    data.withUnsafeBytes { bytes in
                        for frame in 0..<(validLast - validFirst) {
                            let target = first + validFirst - sourceFirst + frame
                            let level = region.level(at: target, rate: rate)
                            for channel in 0..<inputPCM.channels {
                                samples[(target - start) * pcm.channels + channel] += bytes.loadUnaligned(fromByteOffset: (frame * inputPCM.channels + channel) * 4, as: Float.self) * level
                            }
                        }
                    }
                }
                guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
                    throw SpatialAudioError.unsupported("The audio is too loud to export without distortion. Lower Volume or Master Volume and try again.")
                }
                var block: CMBlockBuffer?
                let bytes = samples.count * 4
                guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
                      let block else { throw SpatialAudioError.processingFailure(#line) }
                let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(rate)), decodeTimeStamp: .invalid)
                var buffer: CMSampleBuffer?
                var sampleSize = pcm.channels * 4
                guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                    formatDescription: pcm.format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer) == noErr, let buffer else { throw SpatialAudioError.processingFailure(#line) }
                while !inputs[index].isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing else { throw writer.error ?? SpatialAudioError.processingFailure(#line) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard inputs[index].append(buffer) else { throw writer.error ?? SpatialAudioError.processingFailure(#line) }
            }
        }
        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SpatialAudioError.processingFailure(#line) }
        // Establish alternate playback tracks without retaining stale recording-analysis metadata.
        let movie = AVMutableMovie(url: raw, options: nil)
        movie.timescale = Int32(rate)
        let audio = movie.tracks(withMediaType: .audio)
        guard audio.count == 2 else { throw SpatialAudioError.processingFailure(#line) }
        for (index, track) in audio.enumerated() { track.alternateGroupID = 1; track.isEnabled = index == 0 }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-spatial-processed-" + UUID().uuidString + ".mov")
        do {
            guard let session = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else { throw SpatialAudioError.processingFailure(#line) }
            session.audioTrackGroupHandling = .preserveAlternateTracks
            try await session.export(to: output, as: .mov)
            try Task.checkCancellation()
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
