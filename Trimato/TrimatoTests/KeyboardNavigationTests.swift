import AppKit
import AVFoundation
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct KeyboardNavigationTests {
    private func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false,
                       window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code))
    }

    @Test(arguments: [false, true])
    func cuttingBoardJumpsTenFramesAndEndpointsWithoutShuttle(video: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(video ? "navigation.mov" : "navigation.wav")
        let input = video ? ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=2", "-c:v", "prores_ks", "-an"]
            : ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "2", "-c:a", "pcm_s16le"]
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y"] + input + [url.path])
        let player = VideoPlayerViewModel()
        player.player.isMuted = true
        player.load(url: url)
        for _ in 0..<1000 where player.isLoadingMedia || !player.hasMedia {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(player.hasMedia && !player.isLoadingMedia)
        defer { player.player.pause() }
        let step = 10.0 / (video ? 24 : 30)
        func check(_ expected: Double) async throws {
            for _ in 0..<100 {
                if abs(player.player.currentTime().seconds - expected) < 0.005 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(abs(player.player.currentTime().seconds - expected) < 0.005)
            #expect(player.player.rate == 0)
        }
        #expect(player.handleKeyEvent(try event(124, modifiers: .shift)) == nil)
        try await check(step)
        #expect(player.handleKeyEvent(try event(124, modifiers: .shift, repeating: true)) == nil)
        try await check(step * 2)
        #expect(player.handleKeyEvent(try event(123, modifiers: .shift)) == nil)
        try await check(step)
        #expect(player.handleKeyEvent(try event(115, modifiers: .function)) == nil)
        try await check(0)
        #expect(player.handleKeyEvent(try event(123, modifiers: .shift)) == nil)
        try await check(0)
        #expect(player.handleKeyEvent(try event(119)) == nil)
        try await check(2)
        #expect(player.handleKeyEvent(try event(124, modifiers: .shift)) == nil)
        try await check(2)
        #expect(player.handleKeyEvent(try event(123, modifiers: .shift)) == nil)
        try await check(2 - step)
        let voiceOver = try event(124, modifiers: [.control, .option, .shift])
        #expect(player.handleKeyEvent(voiceOver) === voiceOver)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: window.contentLayoutRect)
        window.contentView = editor
        window.makeFirstResponder(editor)
        defer { window.close() }
        for code: UInt16 in [123, 124, 115, 119] {
            let editing = try event(code, modifiers: code == 123 || code == 124 ? .shift : [], window: window)
            #expect(player.handleKeyEvent(editing) === editing)
        }
    }

    @Test func projectKeyboardJumpsAndEndpointsKeepTheTimelineUnchanged() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-y", "-f", "lavfi",
            "-i", "anullsrc=r=48000:cl=stereo", "-t", "2", "-c:a", "pcm_s16le", url.path])
        let asset = MediaAssetRecord(name: "Navigation", originalPath: url.path,
            duration: ProjectTime(seconds: 2), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))],
            playbackMode: .nativePassthrough)
        var project = TrimatoProject()
        project.media = [asset]
        _ = try project.append(asset: asset)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let player = ProjectPlayerViewModel()
        player.player.isMuted = true
        player.prepare(project: project, mediaURLs: [asset.id: url])
        for _ in 0..<500 where !player.canControlPlayback { try await Task.sleep(for: .milliseconds(10)) }
        try #require(player.canControlPlayback)
        controller.installProjectPlayer(player)
        player.scopeKeyboardCommands { true }
        defer { player.player.pause() }
        let snapshot = controller.project
        let jumps: [(UInt16, NSEvent.ModifierFlags, Bool, Double)] = [
            (124, .shift, false, 1.0 / 3), (124, .shift, true, 2.0 / 3),
            (123, .shift, false, 1.0 / 3), (115, .function, false, 0),
            (123, .shift, false, 0), (119, [], false, 2),
            (124, .shift, false, 2), (123, .shift, false, 2 - 1.0 / 3)
        ]
        for (code, modifiers, repeatKey, seconds) in jumps {
            #expect(player.handleEditorKeyEvent(try event(code, modifiers: modifiers, repeating: repeatKey)) == nil)
            #expect(abs(player.currentTime.seconds - seconds) < 0.001)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.project == snapshot)
        let voiceOver = try event(124, modifiers: [.control, .option, .shift])
        #expect(player.handleEditorKeyEvent(voiceOver) === voiceOver)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: window.contentLayoutRect)
        window.contentView = editor
        window.makeFirstResponder(editor)
        defer { window.close() }
        for code: UInt16 in [123, 124, 115, 119] {
            let editing = try event(code, modifiers: code == 123 || code == 124 ? .shift : [], window: window)
            #expect(player.handleEditorKeyEvent(editing) === editing)
        }
    }

    @Test(arguments: [24.0, 30, 60, 120])
    func projectTenFrameDistanceUsesProjectRateAndStopsAtEndpoints(rate: Double) {
        let start = ProjectTime(seconds: 1)
        let duration = ProjectTime(seconds: 2)
        let forward = ProjectPlayerViewModel.frameStepDestination(current: start, duration: duration,
            frameRate: rate, forward: true, frames: 10)
        let backward = ProjectPlayerViewModel.frameStepDestination(current: start, duration: duration,
            frameRate: rate, forward: false, frames: 10)
        #expect(abs(forward.seconds - (1 + 10 / rate)) < 0.0001)
        #expect(abs(backward.seconds - (1 - 10 / rate)) < 0.0001)
        #expect(ProjectPlayerViewModel.frameStepDestination(current: .zero, duration: duration,
            frameRate: rate, forward: false, frames: 10) == .zero)
        #expect(ProjectPlayerViewModel.frameStepDestination(current: duration, duration: duration,
            frameRate: rate, forward: true, frames: 10) == duration)
        for code: UInt16 in [115, 119] {
            #expect(ProjectPlayerViewModel.recognizesEditorKeyboardCommand(type: .keyDown, keyCode: code,
                character: nil, modifiers: .function))
            #expect(!ProjectPlayerViewModel.recognizesEditorKeyboardCommand(type: .keyDown, keyCode: code,
                character: nil, modifiers: [.control, .option]))
        }
    }
}
