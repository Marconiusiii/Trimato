import Foundation
import AVFoundation
@testable import Trimato

@main struct RecordingPlaybackCheck {
    @MainActor static func main() async throws {
        let soundID = UUID()
        InterfaceSounds.shared.capture(soundID, active: true)
        defer { InterfaceSounds.shared.capture(soundID, active: false) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstClip = TimelineElementSelection.clip(UUID())
        let secondClip = TimelineElementSelection.clip(UUID())
        precondition(TimelineKeyAction.target(voiceOver: true, accessibilityFocus: firstClip, keyboardFocus: secondClip, editingText: true) == firstClip)
        precondition(TimelineKeyAction.target(voiceOver: true, accessibilityFocus: nil, keyboardFocus: secondClip, editingText: false) == nil)
        precondition(TimelineKeyAction.target(voiceOver: false, accessibilityFocus: firstClip, keyboardFocus: secondClip, editingText: false) == secondClip)
        var project = TrimatoProject(name: "Mixed microphone regression")
        var clips: [TimelineClip] = []
        var urls: [UUID: URL] = [:]
        for (index, rate) in [16000.0, 48000, 44100].enumerated() {
            let url = directory.appendingPathComponent("microphone-\(index).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: index == 2 ? 2 : 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = Float(0.25 * sin(Double(frame) * 2 * .pi * 440 / rate))
                }
            }
            do {
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                if index < 2 {
                    let writer = try AudioCaptureWriter(url: url, sampleRate: rate, channel: 0, bitDepth: 24)
                    writer.receive(buffer)
                    precondition(writer.hasReceivedAudio)
                    writer.begin(); writer.receive(buffer)
                    let result = writer.finish()
                    precondition(result.1 == nil && result.0.duration == 1)
                } else {
                    let file = try AVAudioFile(forWriting: url, settings: settings)
                    try file.write(from: buffer)
                }
            }
            let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
            let asset = MediaAssetRecord(name: "Mic \(index)", originalPath: url.path, duration: ProjectTime(seconds: 1), hasAudio: true, sourceEdit: [segment], playbackMode: .nativePassthrough)
            project.media.append(asset); urls[asset.id] = url
            var clip = TimelineClip(assetID: asset.id, name: asset.name, segments: [segment])
            clip.timelineStart = ProjectTime(seconds: Double(index))
            if index == 0 { clip.audioSettings.lowGainDecibels = 3; clip.audioSettings.lowPassEnabled = true; clip.audioSettings.lowPassFrequency = 16000 }
            clips.append(clip)
        }
        var track = TimelineTrack(name: "Audio Description", kind: .audio, clips: clips)
        track.mix.volumeDB = -0.5
        project.tracks = [track]
        for purpose in [ProjectCompositionPurpose.preview, .finalExport] {
            let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls, purpose: purpose)
            defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
            let reader = try AVAssetReader(asset: result.composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: try await result.composition.loadTracks(withMediaType: .audio), audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            output.audioMix = result.audioMix
            reader.add(output)
            precondition(reader.startReading())
            var end = 0.0
            var peaks = [Float](repeating: 0, count: 3)
            while let sample = output.copyNextSampleBuffer() {
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                end = max(end, start + CMSampleBufferGetDuration(sample).seconds)
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                precondition(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr)
                let values = UnsafeRawPointer(pointer!).assumingMemoryBound(to: Float.self)
                for i in 0..<(length / 4) {
                    let second = min(2, max(0, Int(start + Double(i / 2) / 48000)))
                    peaks[second] = max(peaks[second], abs(values[i]))
                }
            }
            precondition(reader.status == .completed && end >= 2.99, "Mixed microphone playback truncated at \(end)")
            precondition(peaks.allSatisfy { $0 > 0.1 }, "A microphone clip is silent: \(peaks)")
            print("\(purpose): mixed 16/48/44.1 kHz audio reached \(end) seconds; peaks \(peaks)")
        }
        for type in [AudioTransitionType.crossFade, .fadeOutIn] {
            let url = try await FFmpegTimelineEffectRenderer.renderAudioTransition(
                leadingURL: urls[clips[0].assetID]!, trailingURL: urls[clips[1].assetID]!,
                leadingClip: clips[0], trailingClip: clips[1], type: type, duration: ProjectTime(seconds: 0.4))
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let audio = try await asset.loadTracks(withMediaType: .audio).first!
            let descriptions = try await audio.load(.formatDescriptions)
            precondition(CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])!.pointee.mSampleRate == 48000)
            let duration = try await asset.load(.duration).seconds
            precondition(abs(duration - 0.4) < 0.001)
        }
        let eqURL = try await ClipFilterRenderer.render(source: urls[clips[0].assetID]!, filters: [], audio: true,
            duration: 1, audioSettings: clips[0].audioSettings)
        defer { try? FileManager.default.removeItem(at: eqURL) }
        let eqAsset = AVURLAsset(url: eqURL)
        let eqDuration = try await eqAsset.load(.duration).seconds
        precondition(abs(eqDuration - 1) < 0.001)
        print("Mixed-rate transitions and low-rate Clip Editor EQ retained their full durations")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let session = ProjectRecordingSession(controller: controller, purpose: .audioDescription)
        defer { session.close() }
        session.start = 0.25; session.end = 0.75
        session.player.isMuted = true
        session.preview(mixed: false, autoplay: false)
        for _ in 0..<200 { if !session.busy { break }; try await Task.sleep(for: .milliseconds(25)) }
        precondition(!session.busy && session.message == nil, "Describer preview preparation failed")
        precondition(session.player.currentItem?.forwardPlaybackEndTime.seconds == 0.75)
        precondition(abs(session.player.currentTime().seconds - 0.25) < 0.01)
        session.preview(mixed: true, autoplay: false)
        for _ in 0..<200 { if !session.busy { break }; try await Task.sleep(for: .milliseconds(25)) }
        precondition(session.player.currentItem?.forwardPlaybackEndTime.seconds == 0.75)
        session.ducking.enabled.toggle()
        await session.applyDucking()
        for _ in 0..<200 { if !session.busy { break }; try await Task.sleep(for: .milliseconds(25)) }
        precondition(session.player.currentItem?.forwardPlaybackEndTime.seconds == 0.75)
        session.player.play()
        try await Task.sleep(for: .seconds(1))
        precondition(session.player.rate == 0 && session.player.currentTime().seconds <= 0.76, "Describer playback crossed Out")
        print("Describer sought to In, retained Out after ducking changed, and stopped at Out")
    }
}
