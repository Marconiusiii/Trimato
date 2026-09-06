import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Trimato

@Suite("Audio capture storage")
struct AudioCaptureSessionTests {
    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<4 { samples[0][index] = 0.125; samples[1][index] = index == 0 ? 1 : 0.5 }
        return buffer
    }

    @Test func cueAndPostStopSamplesAreExcludedAndSelectedChannelIsSaved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(url: url, sampleRate: 48_000, channel: 1, bitDepth: 24)
        let source = try buffer()
        writer.receive(source)
        #expect(writer.hasReceivedAudio)
        #expect(writer.snapshot().0.frames == 0)
        writer.begin()
        writer.receive(source)
        let (summary, error) = writer.finish()
        writer.receive(source)
        #expect(error == nil)
        #expect(summary.frames == 4)
        #expect(summary.peak == 1)
        #expect(summary.clippedSamples == 1)
        #expect(writer.snapshot().0.frames == 4)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 4)
        #expect(file.processingFormat.channelCount == 1)
        let result = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4))
        try file.read(into: result)
        #expect(abs(try #require(result.floatChannelData)[0][1] - 0.5) < 0.0001)
    }

    @Test func changedInputFormatStopsWritingWithAnActionableError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(url: url, sampleRate: 44_100, channel: 0, bitDepth: 16)
        writer.begin()
        writer.receive(try buffer())
        let result = writer.finish()
        #expect(result.0.frames == 0)
        #expect(result.1 != nil)
    }

    @Test func silenceDoesNotProduceInvalidDecibels() {
        let summary = AudioRecordingSummary(frames: 48_000, sampleRate: 48_000)
        #expect(summary.duration == 1)
        #expect(summary.peakDecibels == nil)
    }
}

@MainActor
@Suite("Audio recording startup and controls", .serialized)
struct AudioCaptureLifecycleTests {
    private let request = AudioCaptureRequest(inputDeviceID: 10, inputUID: "microphone", outputDeviceID: 20, outputUID: "headphones", channel: 0, bitDepth: 24)

    private func makeSession(_ backend: TestCaptureBackend, playCue: @escaping (Bool, AudioDeviceID) async throws -> Void = { _, _ in }) -> AudioCaptureSession {
        AudioCaptureSession(routes: AudioOutputManager(observeHardware: false), backend: backend, preparationDelay: .zero, cueSettlingDelay: .zero, playCue: playCue)
    }

    private func waitUntilRecording(_ session: AudioCaptureSession) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while session.state == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.state == .recording)
        #expect(session.message == nil)
    }

    @Test func selectingAnInputCanReconfigureDuringPreparationWithoutCancelingRecording() async throws {
        let backend = TestCaptureBackend()
        backend.notifyDuringPreparation = true
        var heardCue = false
        let session = makeSession(backend) { _, _ in
            #expect(backend.isReady)
            #expect(backend.beginCount == 0)
            heardCue = true
        }
        defer { session.close() }
        session.record(request: request)
        try await waitUntilRecording(session)
        #expect(heardCue)
        #expect(backend.beginCount == 1)
        #expect(session.isRecordingRequested)
        session.setRecording(false, input: AudioInputManager(routes: AudioOutputManager(observeHardware: false)))
        #expect(!session.isRecordingRequested)
        #expect(backend.finishCount == 1)
    }

    @Test func cueDeviceReconfigurationSettlesBeforeAnySamplesAreRetained() async throws {
        let backend = TestCaptureBackend()
        var cues = 0
        let session = makeSession(backend) { _, _ in
            cues += 1
            #expect(backend.beginCount == 0)
            if cues == 1 {
                backend.isReady = false
                backend.configurationChanged?()
            }
        }
        defer { session.close() }
        session.record(request: request)
        try await waitUntilRecording(session)
        #expect(cues == 2)
        #expect(backend.settleCount == 2)
        #expect(backend.beginCount == 1)
    }

    @Test func staleNotificationDoesNotStopAHealthyRecordingButActualLossDoes() async throws {
        let backend = TestCaptureBackend()
        let session = makeSession(backend)
        defer { session.close() }
        session.record(request: request)
        try await waitUntilRecording(session)
        backend.configurationChanged?()
        #expect(session.state == .recording)
        #expect(session.message == nil)
        backend.isReady = false
        backend.configurationChanged?()
        #expect(session.state == .idle)
        #expect(session.message != nil)
        #expect(backend.finishCount == 1)
    }

    @Test func togglingOffImmediatelyDoesNotOpenTheMicrophoneLater() async throws {
        let backend = TestCaptureBackend()
        var cues = 0
        let session = makeSession(backend) { _, _ in cues += 1 }
        defer { session.close() }
        session.record(request: request)
        #expect(session.isRecordingRequested)
        session.setRecording(false, input: AudioInputManager(routes: AudioOutputManager(observeHardware: false)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .idle)
        #expect(backend.prepareCount == 0)
        #expect(backend.beginCount == 0)
        #expect(cues == 0)
        #expect(!AudioCaptureSession.suppressesAnnouncements)
    }

    @Test func closingSettingsStopsRecordingBeforeClosingTheWindow() async throws {
        let backend = TestCaptureBackend()
        let session = makeSession(backend)
        defer { session.close() }
        session.record(request: request)
        try await waitUntilRecording(session)
        var closed = false
        let close = SettingsCloseAction(capture: session, closeWindow: {
            #expect(session.state == .idle)
            #expect(backend.finishCount == 1)
            #expect(!AudioCaptureSession.suppressesAnnouncements)
            closed = true
        })
        close()
        #expect(closed)
    }

    @Test func settingsAudioPaneHasNoScrollOrCollectionView() {
        let host = NSHostingView(rootView: AudioRecordingSettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        #expect(!views.contains { $0 is NSScrollView })
        #expect(!views.contains { $0 is NSCollectionView })
        #expect(host.fittingSize.height <= 600)
    }
}

@MainActor
private final class TestCaptureBackend: AudioCaptureBackend {
    var isReady = false
    var configurationChanged: (() -> Void)?
    var notifyDuringPreparation = false
    var prepareCount = 0
    var settleCount = 0
    var beginCount = 0
    var finishCount = 0
    func prepare(_ request: AudioCaptureRequest) throws {
        prepareCount += 1
        if notifyDuringPreparation { configurationChanged?() }
    }
    func settle() throws {
        settleCount += 1
        isReady = true
    }
    func begin() { beginCount += 1 }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(), nil) }
    func finish() -> AudioCaptureResult { finishCount += 1; isReady = false; return AudioCaptureResult() }
}
