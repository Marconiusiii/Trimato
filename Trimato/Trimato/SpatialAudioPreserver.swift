import AVFoundation
import Foundation

/// Retains the original alternate audio group. Never sends spatial audio through the stereo mixer.
nonisolated struct SpatialAudioPlan: Sendable {
    let source: AVURLAsset
    let ranges: [CMTimeRange]
    var processing: SpatialAudioRenderPlan? = nil
    var temporaryURL: URL? = nil

    func materialized() async throws -> Self {
        guard let processing else { return self }
        let url = try await processing.render()
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let description = try await track.load(.formatDescriptions).first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw SpatialAudioError.invalidMovie }
            let duration = CMTime(value: Int64((processing.duration * format.mSampleRate).rounded()), timescale: Int32(format.mSampleRate))
            return Self(source: asset, ranges: [CMTimeRange(start: .zero, duration: duration)], temporaryURL: url)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    var duration: CMTime { ranges.reduce(.zero) { CMTimeAdd($0, $1.duration) } }

    static func detect(in asset: AVAsset) async throws -> Bool {
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) }
        catch {
            let failure = error as NSError
            guard let file = asset as? AVURLAsset, failure.domain == AVFoundationErrorDomain,
                  failure.code == AVError.fileFormatNotRecognized.rawValue else { throw error }
            // FFmpeg-only containers still support ordinary mono/stereo editing.
            // Never assume an unreadable multichannel source is safe to downmix.
            let report = try await FFmpegMediaProbe.inspect(url: file.url)
            if report.streams.contains(where: { $0.codecType == "audio" && (($0.channels ?? 0) > 2 || $0.codecTag == "apac") }) {
                throw SpatialAudioError.unsupported("This multichannel source cannot be inspected by the native spatial audio exporter.")
            }
            return false
        }
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                if CMFormatDescriptionGetMediaSubType(description) == 0x61706163 { return true }
                if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil) {
                    let family = layout.pointee.mChannelLayoutTag & 0xFFFF0000
                    // iPhone ProRes captures can store ambisonic audio as PCM.
                    if family == (kAudioChannelLayoutTag_HOA_ACN_SN3D & 0xFFFF0000) ||
                       family == (kAudioChannelLayoutTag_HOA_ACN_N3D & 0xFFFF0000) ||
                       family == (kAudioChannelLayoutTag_Ambisonic_B_Format & 0xFFFF0000) { return true }
                }
            }
            if try await !track.loadAssociatedTracks(ofType: .audioFallback).isEmpty { return true }
        }
        return false
    }

    /// Copy the recording's existing stereo rendering and picture without another
    /// encoding step, so the ordinary effects engine never receives APAC channels.
    static func stereoSource(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let selected = try await AudioProcessingFormat.selectedTrack(in: asset) else { throw SpatialAudioError.invalidMovie }
        let movie = AVMutableMovie(url: url, options: nil)
        for track in movie.tracks where track.mediaType != .video && track.trackID != selected.trackID { movie.removeTrack(track) }
        for track in movie.tracks(withMediaType: .audio) { track.alternateGroupID = 0; track.isEnabled = true }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-stereo-source-" + UUID().uuidString + ".mov")
        do {
            guard let export = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else { throw SpatialAudioError.invalidMovie }
            try await export.export(to: output, as: .mov)
            try Task.checkCancellation()
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }

    static func clip(asset: AVAsset, ranges: [CMTimeRange]) async throws -> Self? {
        guard try await detect(in: asset) else { return nil }
        guard let source = asset as? AVURLAsset else { throw SpatialAudioError.unsupported("This spatial source is not an original media file.") }
        let duration = try await source.load(.duration)
        guard !ranges.isEmpty, ranges.allSatisfy({ $0.isValid && !$0.isEmpty && $0.start >= .zero && $0.end <= duration }) else {
            throw SpatialAudioError.unsupported("The selected spatial audio range is outside the source recording.")
        }
        var previousEnd = CMTime.zero
        for range in ranges {
            guard range.start >= previousEnd else {
                throw SpatialAudioError.unsupported("Spatial audio cuts must stay in their original recording order, without repeated or overlapping source ranges.")
            }
            previousEnd = range.end
        }
        return Self(source: source, ranges: ranges)
    }

    static func project(_ project: TrimatoProject, urls: [UUID: URL]) async throws -> Self? {
        let tracks = project.tracks.filter { $0.kind == .audio && $0.clips.contains(where: { $0.visibleDuration.isPositive }) }
        var spatialIDs: Set<UUID> = []
        let sourceIDs = Set(tracks.flatMap(\.clips).map(\.assetID))
            .union(project.cutaways.filter { $0.audioMode == .sourceAudio }.map(\.assetID))
        for id in sourceIDs {
            if let url = urls[id], try await detect(in: AVURLAsset(url: url)) { spatialIDs.insert(id) }
        }
        guard !spatialIDs.isEmpty else { return nil }
        try validateControls(project)
        guard let track = tracks.first, let id = track.clips.first?.assetID, let url = urls[id],
              sourceIDs == spatialIDs else {
            throw SpatialAudioError.unsupported("This edit combines spatial audio with a different audio format. Choose High-quality Stereo for this edit.")
        }
        let regions = try tracks.flatMap { try SpatialAudioRenderPlan.project(project, source: url, track: $0, urls: urls).regions }
        let render = SpatialAudioRenderPlan(source: url, duration: project.duration.seconds, regions: regions)
        var cursor = ProjectTime.zero
        var ranges: [CMTimeRange] = []
        var consecutive = true
        for clip in track.sortedClips where clip.visibleDuration.isPositive {
            if clip.visibleTimelineStart != cursor { consecutive = false }
            ranges += clip.visibleSegments.map { $0.sourceRange.cmTimeRange }
            cursor = cursor + clip.visibleDuration
        }
        if tracks.count == 1, sourceIDs.count == 1, consecutive, cursor == project.duration, (try? validatePassthroughControls(project)) != nil,
           let preserved = try? await clip(asset: AVURLAsset(url: url), ranges: ranges) {
            return preserved
        }
        try await SpatialAudioRenderPlan.validateSources(Set(sourceIDs.compactMap { urls[$0] }))
        return Self(source: AVURLAsset(url: url), ranges: [CMTimeRange(start: .zero, duration: project.duration.cmTime)], processing: render)
    }

    static func validateControls(_ project: TrimatoProject) throws {
        try SpatialAudioRenderPlan.validate(project)
    }

    private static func validatePassthroughControls(_ project: TrimatoProject) throws {
        let audio = project.tracks.filter { $0.kind == .audio && !$0.clips.isEmpty }
        guard project.masterVolumeDB == 0,
              audio.allSatisfy({ !$0.isMuted && $0.mix == .neutral && $0.clips.allSatisfy {
                  $0.audioSettings.isNeutral && !$0.filters.contains(where: { $0.enabled && $0.kind.isAudio })
              } }) else {
            throw SpatialAudioError.unsupported("Spatial Audio currently requires unchanged clip audio, default track and master mix settings, and unmuted tracks. Audio filters and volume changes are not supported yet.")
        }
        let audioIDs = Set(audio.map(\.id))
        guard !project.transitions.contains(where: { audioIDs.contains($0.trackID) }),
              project.descriptionDucking.ranges(in: project).isEmpty,
              !project.cutaways.contains(where: { $0.audioMode == .sourceAudio }) else {
            throw SpatialAudioError.unsupported("Spatial audio fades, crossfades, ducking, and source-audio cutaways are not supported yet.")
        }
    }

    func validate(format: ExportFormat) throws {
        guard format.supportsSpatialAudio else {
            throw SpatialAudioError.unsupported("Choose a QuickTime movie format to preserve Spatial Audio. MP4 and audio-only spatial exports are not supported yet.")
        }
    }

    /// Retain native audio edit lists, alternate groups, fallback associations, and metadata.
    @concurrent
    func movie(video: AVAsset? = nil, includeSourceVideo: Bool = false) async throws -> (AVMutableMovie, [CMPersistentTrackID: AVAssetTrack]) {
        try Task.checkCancellation()
        // Keep the native edit lists and codec priming. Re-inserting individual
        // compressed tracks changes AAC/APAC decoder timing even with copied settings.
        let movie = AVMutableMovie(url: source.url, options: nil)
        let sourceDuration = try await source.load(.duration)
        var gaps: [CMTimeRange] = []
        var cursor = CMTime.zero
        for range in ranges {
            if range.start > cursor { gaps.append(CMTimeRange(start: cursor, duration: range.start - cursor)) }
            cursor = range.end
        }
        if cursor < sourceDuration { gaps.append(CMTimeRange(start: cursor, duration: sourceDuration - cursor)) }
        for gap in gaps.reversed() { movie.removeTimeRange(gap) }
        if !includeSourceVideo {
            for track in movie.tracks(withMediaType: .video) { movie.removeTrack(track) }
        }
        var mapping: [CMPersistentTrackID: AVAssetTrack] = [:]
        if let video {
            for track in try await video.loadTracks(withMediaType: .video) {
                guard let target = movie.addMutableTrack(withMediaType: .video, copySettingsFrom: track, options: nil) else {
                    throw SpatialAudioError.invalidMovie
                }
                if let compositionTrack = track as? AVCompositionTrack {
                    // Inserting a multi-source composition into a movie in one call
                    // can silently retain only its first segment. Copy each source
                    // edit explicitly, retaining its timeline position and speed.
                    for segment in try await compositionTrack.load(.segments) where !segment.isEmpty {
                        try Task.checkCancellation()
                        guard let segment = segment as? AVCompositionTrackSegment,
                              let url = segment.sourceURL else {
                            throw SpatialAudioError.videoAssemblyFailed
                        }
                        let sourceAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        guard try await sourceAsset.load(.providesPreciseDurationAndTiming),
                              let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video)
                                .first(where: { $0.trackID == segment.sourceTrackID }) else {
                            throw SpatialAudioError.videoAssemblyFailed
                        }
                        let edit = segment.timeMapping
                        try target.insertTimeRange(edit.source, of: sourceTrack, at: edit.target.start, copySampleData: false)
                        if edit.source.duration != edit.target.duration {
                            target.scaleTimeRange(CMTimeRange(start: edit.target.start, duration: edit.source.duration),
                                                  toDuration: edit.target.duration)
                        }
                        let copied = try await target.load(.timeRange)
                        guard abs((copied.end - edit.target.end).seconds) < 0.001 else {
                            throw SpatialAudioError.videoAssemblyFailed
                        }
                    }
                } else {
                    let available = try await track.load(.timeRange)
                    try target.insertTimeRange(available, of: track, at: available.start, copySampleData: false)
                    let copied = try await target.load(.timeRange)
                    guard abs((copied.end - available.end).seconds) < 0.001 else {
                        throw SpatialAudioError.videoAssemblyFailed
                    }
                }
                mapping[track.trackID] = target
            }
        }
        try await validatePreservedAudio(in: movie)
        return (movie, mapping)
    }

    private func validatePreservedAudio(in asset: AVAsset) async throws {
        let before = try await source.loadTracks(withMediaType: .audio)
        let after = try await asset.loadTracks(withMediaType: .audio)
        guard before.count == 2, after.count == before.count,
              try await asset.load(.trackGroups).contains(where: {
                  Set($0.trackIDs.map(\.int32Value)) == Set(after.map(\.trackID))
              }) else { throw SpatialAudioError.processingFailure(#line) }
        for (original, preserved) in zip(before, after) {
            guard let a = try await original.load(.formatDescriptions).first,
                  let b = try await preserved.load(.formatDescriptions).first,
                  let originalFormat = CMAudioFormatDescriptionGetStreamBasicDescription(a)?.pointee,
                  let preservedFormat = CMAudioFormatDescriptionGetStreamBasicDescription(b)?.pointee,
                  originalFormat.mFormatID == preservedFormat.mFormatID,
                  originalFormat.mSampleRate == preservedFormat.mSampleRate,
                  originalFormat.mChannelsPerFrame == preservedFormat.mChannelsPerFrame,
                  try await original.load(.isEnabled) == preserved.load(.isEnabled),
                  try await original.loadAssociatedTracks(ofType: .audioFallback).count == preserved.loadAssociatedTracks(ofType: .audioFallback).count
            else { throw SpatialAudioError.processingFailure(#line) }
            guard try Self.channelLayout(a) == Self.channelLayout(b) else { throw SpatialAudioError.processingFailure(#line) }
        }
    }

    static func channelLayout(_ description: CMAudioFormatDescription) throws -> Data {
        var size = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size) {
            return Data(bytes: layout, count: size)
        }
        let channels = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame
        guard channels == 1 || channels == 2 else { throw SpatialAudioError.invalidMovie }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return withUnsafeBytes(of: &layout) { Data($0.prefix(12)) }
    }

    static func remap(_ composition: AVMutableVideoComposition?, tracks: [CMPersistentTrackID: AVAssetTrack],
                      playbackDuration: CMTime) throws -> AVMutableVideoComposition? {
        guard let composition else { return nil }
        let result = composition.mutableCopy() as! AVMutableVideoComposition
        result.instructions = try composition.instructions.map { item in
            guard let original = item as? AVVideoCompositionInstruction,
                  let copy = original.mutableCopy() as? AVMutableVideoCompositionInstruction else { throw SpatialAudioError.invalidMovie }
            copy.layerInstructions = try original.layerInstructions.map { layer in
                guard let track = tracks[layer.trackID] else { throw SpatialAudioError.invalidMovie }
                let replacement = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                var range = CMTimeRange.invalid
                var first = CGAffineTransform.identity, last = CGAffineTransform.identity
                if layer.getTransformRamp(for: item.timeRange.start, start: &first, end: &last, timeRange: &range) {
                    if range.start.isNumeric, range.duration.isNumeric, range.duration > .zero {
                        replacement.setTransformRamp(fromStart: first, toEnd: last, timeRange: range)
                    } else { replacement.setTransform(first, at: item.timeRange.start) }
                }
                var startOpacity: Float = 1, endOpacity: Float = 1
                if layer.getOpacityRamp(for: item.timeRange.start, startOpacity: &startOpacity, endOpacity: &endOpacity, timeRange: &range) {
                    if range.start.isNumeric, range.duration.isNumeric, range.duration > .zero {
                        replacement.setOpacityRamp(fromStartOpacity: startOpacity, toEndOpacity: endOpacity, timeRange: range)
                    } else { replacement.setOpacity(startOpacity, at: item.timeRange.start) }
                }
                var startCrop = CGRect.zero, endCrop = CGRect.zero
                if layer.getCropRectangleRamp(for: item.timeRange.start, startCropRectangle: &startCrop, endCropRectangle: &endCrop, timeRange: &range) {
                    if range.start.isNumeric, range.duration.isNumeric, range.duration > .zero {
                        replacement.setCropRectangleRamp(fromStartCropRectangle: startCrop, toEndCropRectangle: endCrop, timeRange: range)
                    } else { replacement.setCropRectangle(startCrop, at: item.timeRange.start) }
                }
                return replacement
            }
            return copy
        }
        if let track = tracks[result.sourceTrackIDForFrameTiming] { result.sourceTrackIDForFrameTiming = track.trackID }
        // Spatial audio is rounded to whole audio samples. Even a fractional
        // sample beyond the last picture instruction invalidates AVPlayer video.
        if let last = result.instructions.last as? AVMutableVideoCompositionInstruction,
           playbackDuration > last.timeRange.end,
           (playbackDuration - last.timeRange.end).seconds < 0.001 {
            last.timeRange.duration = playbackDuration - last.timeRange.start
        }
        return result
    }

    @concurrent
    func export(video: AVAsset? = nil, includeSourceVideo: Bool = false, range: CMTimeRange? = nil,
                to output: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let (movie, _) = try await movie(video: video, includeSourceVideo: includeSourceVideo)
        guard let session = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else { throw SpatialAudioError.invalidMovie }
        session.audioTrackGroupHandling = .preserveAlternateTracks
        session.timeRange = range ?? CMTimeRange(start: .zero, duration: duration)
        session.shouldOptimizeForNetworkUse = true
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: output, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("spatial.mov")
        let reporter = Task { @MainActor in
            while !Task.isCancelled { progress(min(Double(session.progress), 0.99)); try? await Task.sleep(for: .milliseconds(200)) }
        }
        defer { reporter.cancel() }
        try await session.export(to: temporary, as: .mov)
        try Task.checkCancellation()
        try await validatePreservedAudio(in: AVURLAsset(url: temporary))
        try await ExportOutputValidator.validate(temporary, duration: session.timeRange.duration.seconds,
            video: !(try await movie.loadTracks(withMediaType: .video)).isEmpty, audio: true)
        try ExportFileCommit.commit(temporary, to: output)
        reporter.cancel()
        await progress(1)
    }
}

nonisolated enum SpatialAudioError: LocalizedError {
    case unsupported(String)
    case invalidMovie
    case videoAssemblyFailed
    case processingFailure(Int)
    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): "\(reason) Spatial Audio has not been converted to stereo."
        case .videoAssemblyFailed: "Trimato could not assemble all of the project's video for playback with spatial audio."
        case .invalidMovie, .processingFailure: "Trimato could not preserve this recording's spatial audio tracks and metadata. No stereo substitute was exported."
        }
    }
}
