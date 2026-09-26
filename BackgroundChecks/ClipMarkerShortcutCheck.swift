import AppKit
import AVFoundation
import Combine
@testable import Trimato

@main struct ClipMarkerShortcutCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain(
            [AppPreferenceKey.timecodeFeedback: TimecodeFeedback.onDemand.rawValue],
            forName: UserDefaults.argumentDomain)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for audioOnly in [false, true] {
            let url = directory.appendingPathComponent(audioOnly ? "marker.wav" : "marker.mov")
            let args = audioOnly
                ? ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "pcm_s16le"]
                : ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2", "-c:v", "prores_ks", "-an"]
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error"] + args + [url.path])
            for prepared in [false, true] {
                for firstKey in ["i", "o"] {
                    var announcements: [String] = []
                    var announcedTimes: [Double] = []
                    weak var observedClip: VideoPlayerViewModel?
                    let clip = VideoPlayerViewModel(announcementHandler: { message in
                        announcements.append(message)
                        announcedTimes.append(observedClip?.player.currentTime().seconds ?? -1)
                    })
                    observedClip = clip
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
                    announcements.removeAll()
                    precondition(clip.handleKeyEvent(key("k")) == nil)
                    for _ in 0..<500 {
                        if clip.player.currentTime().seconds > 0.05 { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    precondition(clip.player.rate != 0 && clip.player.currentTime().seconds > 0, "K did not start muted playback")
                    precondition(clip.handleKeyEvent(key("k")) == nil)
                    precondition(clip.player.rate == 0 && !clip.isPlaying, "Pause was not synchronized before marking")
                    var latePlaybackUpdates = 0
                    let playObservation = clip.$isPlaying.dropFirst().sink { _ in latePlaybackUpdates += 1 }
                    let rateObservation = clip.$playbackRate.dropFirst().sink { _ in latePlaybackUpdates += 1 }
                    for letter in [firstKey, firstKey == "i" ? "o" : "i"] {
                        precondition(clip.handleKeyEvent(key(letter)) == nil, "Mark key was not consumed")
                        let marker = letter == "i" ? clip.inMarker : clip.outMarker
                        precondition(marker?.isNumeric == true, "First mark key did not set a valid marker")
                    }
                    let originalIn = clip.inMarker, originalOut = clip.outMarker
                    try await Task.sleep(for: .milliseconds(300))
                    precondition(clip.inMarker == originalIn && clip.outMarker == originalOut, "Later preparation erased a marker")
                    precondition(announcements.count == 2 && announcements[0].hasPrefix(firstKey == "i" ? "In marked" : "Out marked"),
                        "First marking command did not request its confirmation")
                    precondition(latePlaybackUpdates == 0, "Queued playback updates followed marker confirmation")
                    withExtendedLifetime((playObservation, rateObservation)) {}
                    var stoppedClockUpdates = 0
                    let clockObservation = clip.playbackClock.objectWillChange.sink { _ in stoppedClockUpdates += 1 }
                    // A frame step advances beyond the Out point and is intentionally avoided here.
                    try await Task.sleep(for: .milliseconds(120))
                    precondition(stoppedClockUpdates == 0, "Unchanged stopped clock was republished")
                    withExtendedLifetime(clockObservation) {}
                    clip.clearIn(); clip.clearOut()
                    announcements.removeAll(); announcedTimes.removeAll()
                    clip.goToStart()
                    clip.goToEnd()
                    precondition(announcements.isEmpty, "Navigation spoke before seek completion")
                    for _ in 0..<500 {
                        if !announcements.isEmpty { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    precondition(announcements == ["End"], "Superseded navigation spoke, or On Demand included a timecode")
                    precondition(abs(announcedTimes.last! - clip.duration) < 0.04, "End spoke before reaching the end")
                    announcements.removeAll(); announcedTimes.removeAll()
                    clip.goToStart()
                    for _ in 0..<500 {
                        if !announcements.isEmpty { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    precondition(announcements == ["Start"] && abs(announcedTimes.last!) < 0.04)
                    announcements.removeAll()
                    clip.goToEnd()
                    clip.markIn()
                    try await Task.sleep(for: .milliseconds(200))
                    precondition(announcements.count == 1 && announcements[0].hasPrefix("In marked"), "Stale navigation followed a marker")
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
