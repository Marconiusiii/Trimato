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

    private func waitUntilIdle(_ session: AudioCaptureSession) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while session.state != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.state == .idle)
    }

    @Test func failedPreparationCanBeRetriedWithTheNewDevice() async throws {
        let backend = TestCaptureBackend()
        backend.failNextSettle = true
        let session = makeSession(backend)
        defer { session.close() }
        session.record(request: request)
        for _ in 0..<100 where session.state == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntilIdle(session)
        #expect(session.message != nil)
        let replacement = AudioCaptureRequest(inputDeviceID: 30, inputUID: "built-in", outputDeviceID: 40,
                                             outputUID: "default-output", channel: 0, bitDepth: 24)
        session.record(request: replacement)
        try await waitUntilRecording(session)
        #expect(backend.lastInputUID == "built-in")
        #expect(backend.prepareCount == 2)
        #expect(backend.finishCount >= 1)
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
        try await waitUntilIdle(session)
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
        #expect(cues == 1)
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
        try await waitUntilIdle(session)
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
            #expect(session.state == .finishing)
            #expect(!AudioCaptureSession.suppressesAnnouncements)
            closed = true
        })
        close()
        #expect(closed)
        try await waitUntilIdle(session)
        #expect(backend.finishCount == 1)
    }

    @Test func settingsToolbarIsNamedWithoutNamingPanelContents() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "SettingsAccessibilityTest")
        let host = NSHostingView(rootView: TrimatoSettingsView())
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        func attribute(_ element: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        func elements(_ element: NSObject) -> [NSObject] {
            let children = attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            return [element] + children.flatMap(elements)
        }
        SettingsToolbarAccessibility.update()
        let exposed = elements(host)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let frame = try #require(host.superview)
        let toolbar = try #require(views(frame).first { $0.accessibilityRole() == .toolbar })
        #expect(toolbar.accessibilityLabel() == "Settings")
        #expect(!exposed.contains {
            attribute($0, "accessibilityLabel") as? String == "Settings"
        }, "Settings must name the toolbar, not a panel content group")
        #expect(exposed.contains {
            attribute($0, "accessibilityRole") as? String == "AXHeading"
                && attribute($0, "accessibilityLabel") as? String == "Export notifications"
        })
        #expect(!exposed.contains {
            attribute($0, "accessibilityValue") as? String == "Permission"
        })
    }

    @Test func audioControlsExposeTheirOwnLabelsWithoutSeparateLabelStops() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AudioRecordingSettingsView())
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        func attribute(_ element: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        func elements(_ element: NSObject) -> [NSObject] {
            let children = attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            return [element] + children.flatMap(elements)
        }
        let exposed = elements(host)
        for title in ["Recording", "Playback", "Recording test"] {
            #expect(exposed.contains {
                attribute($0, "accessibilityRole") as? String == "AXHeading"
                    && attribute($0, "accessibilityLabel") as? String == title
            }, "Expected native heading for \(title)")
        }
        let labels = ["Microphone", "Microphone channel", "Recording quality", "Playback device"]
        for label in labels {
            let controls = exposed.filter {
                attribute($0, "accessibilityRole") as? String == "AXPopUpButton"
                    && attribute($0, "accessibilityLabel") as? String == label
            }
            #expect(controls.count == 1, "Expected one native Picker named \(label)")
        }
        let volumeSlider = try #require(exposed.first {
            attribute($0, "accessibilityRole") as? String == "AXSlider"
                && attribute($0, "accessibilityLabel") as? String == "Microphone volume"
        })
        #expect(attribute(volumeSlider, "accessibilityValue") is NSNumber)
        #expect(volumeSlider.responds(to: NSSelectorFromString("accessibilityPerformIncrement")))
        #expect(volumeSlider.responds(to: NSSelectorFromString("accessibilityPerformDecrement")))
        for label in labels + ["Microphone volume"] {
            #expect(!exposed.contains {
                attribute($0, "accessibilityRole") as? String == "AXStaticText"
                    && attribute($0, "accessibilityValue") as? String == label
            }, "Control label must not be a separate VoiceOver stop: \(label)")
        }
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
    var failNextSettle = false
    var lastInputUID: String?
    var prepareCount = 0
    var settleCount = 0
    var beginCount = 0
    var finishCount = 0
    func prepare(_ request: AudioCaptureRequest) async throws {
        prepareCount += 1
        lastInputUID = request.inputUID
        if notifyDuringPreparation { configurationChanged?() }
    }
    func settle() async throws {
        settleCount += 1
        if failNextSettle {
            failNextSettle = false
            throw AudioCaptureError.message("The microphone changed during preparation.")
        }
        isReady = true
    }
    func begin() async throws { beginCount += 1 }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(), nil) }
    func finish(playCue: Bool) async -> AudioCaptureResult { finishCount += 1; isReady = false; return AudioCaptureResult() }
}
