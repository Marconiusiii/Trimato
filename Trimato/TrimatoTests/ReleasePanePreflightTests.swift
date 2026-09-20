import AppKit
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ReleasePanePreflightTests {
    @Test func populatedRecordingPaneFitsBeforeMarketingCapture() async throws {
        for purpose in [RecordingPurpose.audioDescription, .voiceOver] {
            let backend = PreflightCaptureBackend()
            let capture = AudioCaptureSession(routes: AudioOutputManager(observeHardware: false),
                backend: backend, preparationDelay: .zero, playCue: { _, _ in })
            capture.record(request: AudioCaptureRequest(inputDeviceID: 10, inputUID: "preflight",
                outputDeviceID: 20, outputUID: "preflight", channel: 0, bitDepth: 24))
            for _ in 0..<100 where capture.state != .recording { try await Task.sleep(for: .milliseconds(10)) }
            try #require(capture.state == .recording)
            capture.stop()
            for _ in 0..<100 where capture.summary == nil { try await Task.sleep(for: .milliseconds(10)) }
            try #require(capture.summary != nil)
            let controller = ProjectController(document: ProjectDocument())
            let session = ProjectRecordingSession(controller: controller, purpose: purpose, capture: capture, prepareCapture: {})
            session.start = 39.223; session.end = 44.282; session.position = 40.633
            session.name = purpose == .audioDescription ? "Scooping coffee beans" : "Making coffee introduction"
            session.text = "I scoop coffee beans into the grinder, then set the scoop beside the kettle."
            let host = NSHostingView(rootView: ProjectRecordingView(session: session))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 720),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderBack(nil)
            defer { window.close(); session.close() }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "\(purpose.toolTitle)-populated.png")
            try #require(host.frame.height <= 721, "Populated \(purpose.toolTitle) needs \(host.frame.height) points at the 720-point workspace minimum. Stop capture staging.")
            let tab = try #require(descendants(host).compactMap { $0 as? NSTabViewItem }.first { $0.label == "Voice Adjustments" })
            tab.tabView?.selectTabViewItem(tab)
            session.voice.evenOut = true
            try await Task.sleep(for: .milliseconds(300))
            try #require(host.frame.height <= 721, "Populated Voice Adjustments exceeds the workspace minimum. Stop capture staging.")
        }
    }

    private func descendants(_ object: NSObject) -> [NSObject] {
        let key = "accessibilityChildren"
        let children = object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? [NSObject] ?? [] : []
        return [object] + children.flatMap(descendants)
    }
}

@MainActor
private final class PreflightCaptureBackend: AudioCaptureBackend {
    var isReady = false
    var configurationChanged: (() -> Void)?
    func prepare(_ request: AudioCaptureRequest) async throws { }
    func settle() async throws { isReady = true }
    func begin() async throws { }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(), nil) }
    func finish(playCue: Bool) async -> AudioCaptureResult {
        isReady = false
        return AudioCaptureResult(url: FileManager.default.temporaryDirectory.appendingPathComponent("preflight-\(UUID()).wav"),
            summary: AudioRecordingSummary(frames: 288_000, sampleRate: 48_000))
    }
}
