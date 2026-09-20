import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
#if DEBUG
import Synchronization
#endif
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
        AudioCaptureSession(routes: AudioOutputManager(observeHardware: false), backend: backend, preparationDelay: .zero, playCue: playCue)
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

    private func waitUntilPrepared(_ session: AudioCaptureSession) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !session.isInputPrepared, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.isInputPrepared)
        #expect(session.canStartRecording)
        #expect(!session.isRecordingRequested)
    }

    @Test func openingPreparesWithoutSavingAndRecordReusesTheInput() async throws {
        let backend = TestCaptureBackend()
        var cues = 0
        let session = makeSession(backend) { _, _ in cues += 1 }
        session.prepareInput { request }
        #expect(!session.canStartRecording)
        session.record(request: request)
        try await waitUntilPrepared(session)
        #expect(backend.prepareCount == 1)
        #expect(backend.beginCount == 0)
        #expect(cues == 0)
        #expect(session.testURL == nil)
        session.record(request: request)
        try await waitUntilRecording(session)
        #expect(backend.prepareCount == 1)
        #expect(backend.settleCount == 1)
        #expect(backend.beginCount == 1)
        #expect(cues == 1)
        session.stop()
        try await waitUntilPrepared(session)
        #expect(backend.finishCount == 1)
        #expect(backend.prepareCount == 2)
        session.record(request: request)
        try await waitUntilRecording(session)
        #expect(backend.prepareCount == 2)
        #expect(backend.beginCount == 2)
        session.close()
        try await waitUntilIdle(session)
        #expect(!session.isInputPrepared)
        #expect(backend.finishCount == 2)
    }

    @Test func closeBeforePreparationRunsNeverOpensTheMicrophone() async throws {
        let backend = TestCaptureBackend()
        let session = makeSession(backend)
        session.prepareInput { request }
        session.close()
        try await waitUntilIdle(session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.prepareCount == 0)
        #expect(backend.beginCount == 0)
        #expect(!session.isInputPrepared)
        #expect(!session.canStartRecording)
    }

    @Test func closeWhilePreparationIsSuspendedCleansUpWithoutRearming() async throws {
        let backend = TestCaptureBackend()
        backend.pausePreparation = true
        let session = makeSession(backend)
        session.prepareInput { request }
        for _ in 0..<100 where backend.prepareCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        session.close()
        backend.resumePreparation?()
        try await waitUntilIdle(session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.prepareCount == 1)
        #expect(backend.beginCount == 0)
        #expect(backend.finishCount == 1)
        #expect(!session.isInputPrepared)
    }

    @Test func changingDevicesPreparesReplacementBeforeRecordAndPreservesTake() async throws {
        let backend = TestCaptureBackend()
        let session = makeSession(backend)
        var selected = request
        session.prepareInput { selected }
        try await waitUntilPrepared(session)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-take-\(UUID()).wav")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        backend.nextResult = AudioCaptureResult(url: url, summary: AudioRecordingSummary(frames: 480, sampleRate: 48_000))
        session.record(request: selected)
        try await waitUntilRecording(session)
        session.stop()
        try await waitUntilPrepared(session)
        #expect(session.testURL == url)
        selected = AudioCaptureRequest(inputDeviceID: 30, inputUID: "replacement", outputDeviceID: 40,
            outputUID: "replacement-output", channel: 0, bitDepth: 16)
        try await Task.sleep(for: .milliseconds(350))
        try await waitUntilPrepared(session)
        #expect(backend.lastInputUID == "replacement")
        #expect(session.testURL == url)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        let prepared = backend.prepareCount
        session.record(request: selected)
        try await waitUntilRecording(session)
        #expect(backend.prepareCount == prepared)
        session.close()
        try await waitUntilIdle(session)
    }

    @Test func failedPreparationDoesNotLoopAndRecoversOnDeviceChange() async throws {
        let backend = TestCaptureBackend()
        backend.failNextSettle = true
        let session = makeSession(backend)
        var selected = request
        session.prepareInput { selected }
        for _ in 0..<100 where session.message == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(350))
        #expect(session.message != nil)
        #expect(!session.canStartRecording)
        #expect(backend.prepareCount == 1)
        selected = AudioCaptureRequest(inputDeviceID: 30, inputUID: "replacement", outputDeviceID: 40,
            outputUID: "replacement-output", channel: 0, bitDepth: 16)
        try await waitUntilPrepared(session)
        #expect(backend.prepareCount == 2)
        session.close()
        try await waitUntilIdle(session)
    }

    @Test func waitingWindowDoesNotStealInputAndPreparesAfterOwnerCloses() async throws {
        let firstBackend = TestCaptureBackend(), secondBackend = TestCaptureBackend()
        let first = makeSession(firstBackend), second = makeSession(secondBackend)
        first.prepareInput { request }
        try await waitUntilPrepared(first)
        var messages = 0
        let observation = second.$message.sink { if $0 != nil { messages += 1 } }
        defer { observation.cancel() }
        second.prepareInput { request }
        try await Task.sleep(for: .milliseconds(550))
        #expect(secondBackend.prepareCount == 0)
        #expect(first.isInputPrepared)
        #expect(messages == 1)
        first.close()
        try await waitUntilIdle(first)
        try await waitUntilPrepared(second)
        #expect(secondBackend.prepareCount == 1)
        second.close()
        try await waitUntilIdle(second)
    }

    @Test func losingPreparedInputDisablesRecordUntilItIsPreparedAgain() async throws {
        let backend = TestCaptureBackend()
        let session = makeSession(backend)
        session.prepareInput { request }
        try await waitUntilPrepared(session)
        backend.isReady = false
        try await Task.sleep(for: .milliseconds(350))
        try await waitUntilPrepared(session)
        #expect(backend.prepareCount == 2)
        #expect(backend.beginCount == 0)
        session.close()
        try await waitUntilIdle(session)
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

    @Test func cueCompletesBeforeSamplesAreRetainedWithoutAnotherPreparationWait() async throws {
        let backend = TestCaptureBackend()
        var cues = 0
        let session = makeSession(backend) { _, _ in
            cues += 1
            #expect(backend.beginCount == 0)
            if cues == 1 {
                backend.configurationChanged?()
            }
        }
        defer { session.close() }
        session.record(request: request)
        try await waitUntilRecording(session)
        #expect(cues == 1)
        #expect(backend.settleCount == 1)
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
        #expect(session.state == .finishing)
        #expect(session.message == nil)
        #expect(AudioCaptureSession.suppressesAnnouncements)
        try await waitUntilIdle(session)
        #expect(session.message != nil)
        #expect(backend.finishCount == 1)
    }

    @Test func queuedApplicationMessageCannotOpenDuringQuietPreparation() async throws {
        let quietID = UUID()
        AudioCaptureSession.beginQuietPreparation(quietID)
        defer { AudioCaptureSession.endQuietPreparation(quietID) }
        let coordinator = ApplicationMessageWindowCoordinator()
        let windows = Set(NSApp.windows.map(\.windowNumber))
        let key = NSApp.keyWindow
        var dismissed = false
        let id = coordinator.present(ApplicationMessageDescriptor(title: "Deferred test", message: "Test")) {
            dismissed = true
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(Set(NSApp.windows.map(\.windowNumber)) == windows)
        #expect(NSApp.keyWindow === key)
        #expect(!dismissed)
        coordinator.dismiss(id: id)
        #expect(dismissed)
        AudioCaptureSession.endQuietPreparation(quietID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(NSApp.windows.map(\.windowNumber)) == windows)
    }

    @Test func quietPreparationRemainsActiveUntilEveryOwnerFinishes() {
        let first = UUID(), second = UUID()
        AudioCaptureSession.beginQuietPreparation(first)
        AudioCaptureSession.beginQuietPreparation(second)
        #expect(AudioCaptureSession.suppressesAnnouncements)
        AudioCaptureSession.endQuietPreparation(first)
        #expect(AudioCaptureSession.suppressesAnnouncements)
        AudioCaptureSession.endQuietPreparation(second)
        #expect(!AudioCaptureSession.suppressesAnnouncements)
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
            #expect(AudioCaptureSession.suppressesAnnouncements)
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
    var pausePreparation = false
    var resumePreparation: (() -> Void)?
    var nextResult = AudioCaptureResult()
    var prepareCount = 0
    var settleCount = 0
    var beginCount = 0
    var finishCount = 0
    func prepare(_ request: AudioCaptureRequest) async throws {
        prepareCount += 1
        lastInputUID = request.inputUID
        isReady = false
        if pausePreparation {
            await withCheckedContinuation { continuation in resumePreparation = { continuation.resume() } }
            try Task.checkCancellation()
        }
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
    func begin() async throws {
        guard isReady else { throw AudioCaptureError.message("Input was lost during the cue.") }
        beginCount += 1
    }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(), nil) }
    func finish(playCue: Bool) async -> AudioCaptureResult {
        finishCount += 1; isReady = false
        let result = nextResult; nextResult = AudioCaptureResult()
        return result
    }
}

#if DEBUG
@Suite("Recording timing diagnostics")
struct AudioCaptureTimingTests {
    @Test func contiguousSamplesRemainContinuousAcrossCallbackDelays() {
        guard #available(macOS 15.0, *) else { return }
        let timing = AudioCaptureTiming()
        timing.receive(hostTime: 100, sampleTime: 0, frames: 480)
        timing.receive(hostTime: 200, sampleTime: 480, frames: 480)
        timing.receive(hostTime: 900, sampleTime: 960, frames: 480)
        #expect(timing.callbacks.load(ordering: .relaxed) == 3)
        #expect(timing.largestHostGap.load(ordering: .relaxed) == 700)
        #expect(timing.discontinuities.load(ordering: .relaxed) == 0)
    }

    @Test func missingAndRepeatedSamplesAreCountedSeparatelyFromDeliveryDelay() {
        guard #available(macOS 15.0, *) else { return }
        let timing = AudioCaptureTiming()
        timing.receive(hostTime: 100, sampleTime: 0, frames: 480)
        timing.receive(hostTime: 200, sampleTime: 960, frames: 480)
        timing.receive(hostTime: 300, sampleTime: 960, frames: 480)
        #expect(timing.discontinuities.load(ordering: .relaxed) == 2)
        #expect(timing.largestHostGap.load(ordering: .relaxed) == 100)
    }

    @Test func unavailableTimestampsDoNotInventDiscontinuities() {
        guard #available(macOS 15.0, *) else { return }
        let timing = AudioCaptureTiming()
        timing.receive(hostTime: 100, sampleTime: 0, frames: 480)
        timing.receive(hostTime: 200, sampleTime: nil, frames: 480)
        timing.receive(hostTime: 300, sampleTime: 4800, frames: 480)
        timing.receive(hostTime: 400, sampleTime: .nan, frames: 480)
        timing.receive(hostTime: 500, sampleTime: 9600, frames: 480)
        #expect(timing.discontinuities.load(ordering: .relaxed) == 0)
        #expect(timing.latestHostTime.load(ordering: .relaxed) == 500)
    }
}
#endif
