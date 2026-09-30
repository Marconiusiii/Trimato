import AppKit
import SwiftUI
import AVFoundation
@testable import Trimato

@MainActor final class InvisibleSheetWindow: NSWindow {
    var attachments = 0
    var onAttach: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        // Prevent native sheet presentation from displaying anything on screen.
        // Do not replace beginSheet, endSheet, SwiftUI dismissal, or onDismiss.
        sheetWindow.alphaValue = 0
        sheetWindow.ignoresMouseEvents = true
        attachments += 1
        super.beginSheet(sheetWindow, completionHandler: handler)
        onAttach?()
    }
}

@main struct AudioEditorHandoffCheck {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("movie.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=32x32:r=30:d=2", "-f", "lavfi", "-i",
            "anullsrc=r=48000:cl=stereo", "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", url.path])
        let range = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 2)))
        let movie = MediaAssetRecord(name: "Movie", originalPath: url.path, duration: ProjectTime(seconds: 2),
            naturalWidth: 32, naturalHeight: 32, frameRate: 30, hasAudio: true, sourceEdit: [range])
        var project = TrimatoProject()
        project.media = [movie]
        let audio = TimelineClip(assetID: movie.id, name: "Sound", segments: [range])
        var extra = TimelineClip(assetID: movie.id, name: "Other sound", segments: [range])
        extra.filters = [ClipFilter(kind: .plateReverb)]
        let video = TimelineClip(assetID: movie.id, name: "Picture", segments: [range])
        project.tracks = [TimelineTrack(name: "Primary Audio", kind: .audio, role: .primaryAudio, clips: [audio]),
            TimelineTrack(name: "Other audio", kind: .audio, role: .additional, clips: [extra]),
            TimelineTrack(name: "Primary Video", kind: .video, role: .primaryVideo, clips: [video])]
        if CommandLine.arguments.count > 1 {
            project = try JSONDecoder().decode(TrimatoProject.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        }
        let controller = ProjectController(document: ProjectDocument(project: project))
        let candidates = CommandLine.arguments.count > 1
            ? project.tracks.filter { $0.kind == .audio && $0.role == .primaryAudio }.flatMap { $0.clips }
            : [video, audio, extra, audio, extra]
        for clip in candidates {
            let openingAsset = project.asset(id: clip.assetID)!
            let openingSegments = clip.segments
            let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(clip.id), segments: openingSegments)
            let window = InvisibleSheetWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            context.hostWindow = window
            window.contentViewController = NSHostingController(rootView: SourceClipEditorView(controller: controller,
                asset: openingAsset, editSelection: .timelineClip(clip.id), initialSegments: openingSegments, commandContext: context))
            window.orderBack(nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while window.attachments == 0 || window.attachedSheet != nil {
                precondition(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
                precondition(ContinuousClock.now < deadline, "Handoff stuck for \(clip.name), effects ready=\(context.effectsReady)")
                try await Task.sleep(for: .milliseconds(20))
            }
            print("PASS: actual editor preparation sheet dismissed for \(clip.name)")
            window.orderOut(nil)
            window.close()
        }
    }
}
