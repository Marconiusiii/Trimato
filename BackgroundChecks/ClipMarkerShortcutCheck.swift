import AppKit
import AVFoundation
@testable import Trimato

@main struct ClipMarkerShortcutCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let quiet = UUID()
        AudioCaptureSession.beginQuietPreparation(quiet)
        defer { AudioCaptureSession.endQuietPreparation(quiet) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for audioOnly in [false, true] {
            let url = directory.appendingPathComponent(audioOnly ? "marker.wav" : "marker.mov")
            let args = audioOnly
                ? ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "pcm_s16le"]
                : ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2", "-c:v", "prores_ks", "-an"]
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error"] + args + [url.path])
            for prepared in [false, true] {
                for firstKey in ["i", "o"] {
                    let clip = VideoPlayerViewModel()
                    clip.player.isMuted = true
                    clip.scopeKeyboardCommands { true }
                    let source: MediaSource? = prepared ? .native(url: url, asset: AVURLAsset(url: url), contentType: nil,
                        mode: .nativePassthrough, frameTimestamps: [], hasVideo: !audioOnly, hasAudio: audioOnly) : nil
                    clip.load(url: url, preparedSource: source)
                    for _ in 0..<2000 {
                        if !clip.isLoadingMedia { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    precondition(clip.hasMedia && !clip.isLoadingMedia)
                    func key(_ letter: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
                        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                            timestamp: 0, windowNumber: 0, context: nil, characters: letter,
                            charactersIgnoringModifiers: letter, isARepeat: false, keyCode: letter == "i" ? 34 : 31)!
                    }
                    for letter in [firstKey, firstKey == "i" ? "o" : "i"] {
                        precondition(clip.handleKeyEvent(key(letter)) == nil, "Mark key was not consumed")
                        let marker = letter == "i" ? clip.inMarker : clip.outMarker
                        precondition(marker?.isNumeric == true, "First mark key did not set a valid marker")
                    }
                    let originalIn = clip.inMarker, originalOut = clip.outMarker
                    try await Task.sleep(for: .milliseconds(300))
                    precondition(clip.inMarker == originalIn && clip.outMarker == originalOut, "Later preparation erased a marker")
                    precondition(clip.handleKeyEvent(key("i", modifiers: .control)) != nil, "Control-modified input was consumed")
                    clip.scopeKeyboardCommands { false }
                    precondition(clip.handleKeyEvent(key("i")) != nil, "Inactive editor consumed input")
                    clip.closeMedia()
                    print("PASS first \(firstKey), audioOnly=\(audioOnly), prepared=\(prepared)")
                }
            }
        }
        precondition(application.windows.allSatisfy { !$0.isVisible })
        print("PASS marker key routing and state persistence without visible windows or audible feedback")
    }
}
