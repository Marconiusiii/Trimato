import Foundation
import AVFoundation
import AudioToolbox
@testable import Trimato

@main struct RecordingPlaybackCheck {
    @MainActor static func main() async throws {
        let cancelledRender = Task {
            try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-re", "-f", "lavfi", "-i", "sine=frequency=440", "-f", "null", "-"])
        }
        try await Task.sleep(for: .milliseconds(200))
        cancelledRender.cancel()
        do { _ = try await cancelledRender.value; preconditionFailure("Render ignored cancellation") }
        catch is CancellationError { }
        print("Cancelled media subprocess released its worker")
        try await checkCueTransitions()
        try checkInputFormats()
        try await checkCaptureLifecycle()
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
        session.player.volume = 0
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
        let playbackDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < playbackDeadline {
            let position = session.player.currentTime().seconds
            precondition(position <= 0.76, "Describer playback crossed Out")
            if session.player.rate == 0 && position >= 0.74 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let stoppedAt = session.player.currentTime().seconds
        precondition(session.player.rate == 0 && stoppedAt >= 0.74 && stoppedAt <= 0.76,
                     "Describer did not reach and stop at Out: \(stoppedAt), rate \(session.player.rate)")
        print("Describer sought to In, retained Out after ducking changed, and stopped at Out")
    }
}

@MainActor private final class CaptureCheckBackend: AudioCaptureBackend {
    var isReady = false
    var configurationChanged: (() -> Void)?
    var begins = 0
    var finishes = 0
    var stoppedAccepting = false
    func prepare(_ request: AudioCaptureRequest) async throws { configurationChanged?() }
    func settle() async throws { isReady = true }
    func begin() async throws {
        guard isReady else { throw AudioCaptureError.message("Input was lost during the cue.") }
        begins += 1
    }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(), nil) }
    func stopAccepting() { stoppedAccepting = true }
    func finish(playCue: Bool) async -> AudioCaptureResult {
        try? await Task.sleep(for: .milliseconds(100))
        finishes += 1; isReady = false
        return AudioCaptureResult()
    }
}

@MainActor private func checkCaptureLifecycle() async throws {
    let backend = CaptureCheckBackend()
    var cues = 0
    let session = AudioCaptureSession(routes: AudioOutputManager(observeHardware: false), backend: backend,
        preparationDelay: .zero, playCue: { _, _ in
            cues += 1; backend.configurationChanged?()
        })
    let request = AudioCaptureRequest(inputDeviceID: 10, inputUID: "test", outputDeviceID: 20,
                                     outputUID: "test-output", channel: 0, bitDepth: 24)
    session.record(request: request)
    let deadline = ContinuousClock.now + .seconds(2)
    while session.state == .preparing && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(session.state == .recording && cues == 1 && backend.begins == 1)
    session.close()
    precondition(backend.stoppedAccepting && session.state == .finishing)
    precondition(!AudioCaptureSession.suppressesAnnouncements)
    while session.state == .finishing && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(session.state == .idle && backend.finishes == 1)
    session.record(request: request)
    session.stop(playCue: false)
    try await Task.sleep(for: .milliseconds(200))
    precondition(session.state == .idle && backend.begins == 1 && cues == 1)
    session.close()
    print("Capture lifecycle: preparation changes, one cue, immediate stop gate and asynchronous cleanup passed")
}

private func checkInputFormats() throws {
    for rate in [8000.0, 16000, 32000, 44100, 48000, 96000, 192000] {
        for channels in [1, 2, 8, 32] {
            let channel = channels - 1
            let format = try AudioCaptureConfiguration.format(sampleRate: rate, channels: channels, selectedChannel: channel)
            precondition(format.mSampleRate == rate && format.mChannelsPerFrame == channels)
            precondition(format.mBytesPerFrame == channels * 4 && format.mFramesPerPacket == 1)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("InputFormat-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AudioCaptureWriter(url: url, sampleRate: rate, channel: channel, bitDepth: 24, inputChannels: channels)
            let samples = (0..<(64 * channels)).map { Float($0 % channels + 1) / Float(channels * 2) }
            writer.begin()
            samples.withUnsafeBytes { writer.receiveInterleaved($0.baseAddress!, byteCount: $0.count) }
            let result = writer.finish()
            precondition(result.1 == nil && result.0.frames == 64)
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
            try file.read(into: buffer)
            precondition(file.processingFormat.sampleRate == rate && file.processingFormat.channelCount == 1)
            for frame in 0..<64 { precondition(abs(buffer.floatChannelData![0][frame] - 0.5) < 0.0001) }
        }
    }
    for (rate, channels, selected) in [(0.0, 1, 0), (Double.nan, 1, 0), (48000.0, 0, 0), (48000.0, 2, 2), (48000.0, 2, -1)] {
        do { _ = try AudioCaptureConfiguration.format(sampleRate: rate, channels: channels, selectedChannel: selected)
            preconditionFailure("Invalid input configuration was accepted")
        } catch { }
    }
    precondition(AudioCaptureSetupError(status: kAudioQueueErr_InvalidDevice, operation: "test").canRetry)
    precondition(!AudioCaptureSetupError(status: kAudioQueueErr_Permissions, operation: "test").canRetry)
    // Native default selection must not attempt any property access on the queue.
    try AudioCaptureConfiguration.selectDevice(OpaquePointer(bitPattern: 1)!, uid: "", systemDefault: true, operation: "test")
    var selected = false
    try AudioCaptureConfiguration.selectDevice(OpaquePointer(bitPattern: 1)!, uid: "test-input", systemDefault: false,
        operation: "Selecting test input", setProperty: { _, property, data, size in
            precondition(property == kAudioQueueProperty_CurrentDevice && size == MemoryLayout<UnsafeRawPointer>.size)
            let reference = data.load(as: UnsafeRawPointer.self)
            let value = Unmanaged<CFString>.fromOpaque(reference).takeUnretainedValue() as String
            precondition(value == "test-input"); selected = true; return noErr
        })
    precondition(selected)
    do {
        try AudioCaptureConfiguration.selectDevice(OpaquePointer(bitPattern: 1)!, uid: "test-input", systemDefault: false,
            operation: "Selecting test input", setProperty: { _, _, _, _ in kAudioQueueErr_InvalidDevice })
        preconditionFailure("Explicit device failure was hidden")
    } catch let error as AudioCaptureSetupError {
        precondition(error.status == kAudioQueueErr_InvalidDevice && error.operation == "Selecting test input")
    }
    print("Input formats: 28 rate/channel combinations preserved the selected channel; invalid formats and retry policy passed")
}

@concurrent private func checkCueTransitions() async throws {
    let completion = RecordingCueCompletion()
    for _ in 0..<2 {
        completion.reset()
        var drained = false
        var checks = 0
        try completion.play(timeout: 1, start: {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { completion.bufferConsumed() }
        }, drain: { drained = true }, isRunning: {
            precondition(drained)
            checks += 1
            return checks == 1
        })
        precondition(drained && checks == 2)
    }
    // A queue that has not started is not a completed cue, even if IsRunning would be false.
    completion.reset()
    do {
        try completion.play(timeout: 0.03, start: {}, drain: { preconditionFailure("Unplayed cue was drained") },
                            isRunning: { preconditionFailure("Startup was mistaken for completion") })
        preconditionFailure("Unplayed cue succeeded")
    } catch is AudioCaptureError { }
    completion.reset()
    do {
        try completion.play(timeout: 1, start: {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { completion.cancel() }
        }, drain: { preconditionFailure("Cancelled cue was drained") }, isRunning: { false })
        preconditionFailure("Cue cancellation was ignored")
    } catch is CancellationError { }

    // A still-connected output remains selectable after its channel layout and device ID change.
    let stereo = AudioDeviceChoice(id: "headset", deviceID: 10, name: "Headset", inputChannels: 0, outputChannels: 2)
    let mono = AudioDeviceChoice(id: "headset", deviceID: 20, name: "Headset", inputChannels: 0, outputChannels: 1)
    precondition(AudioOutputManager.resolve(selectedUID: "headset", devices: [stereo], defaultID: 10) == stereo)
    precondition(AudioOutputManager.resolve(selectedUID: "headset", devices: [mono], defaultID: 20) == mono)
    precondition(AudioOutputManager.resolve(selectedUID: "", devices: [mono], defaultID: 20) == mono)
    precondition(AudioOutputManager.resolve(selectedUID: "headset", devices: [], defaultID: 20) == nil)
    print("Recording cues: delayed startup, completion, repeat use, timeout and cancellation passed; changed output remains selectable")
}
