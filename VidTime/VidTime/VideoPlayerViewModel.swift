import AVFoundation
import AppKit
import Combine

final class VideoPlayerViewModel: ObservableObject {
    let player = AVPlayer()

    @Published var displayTimecode: String = "00:00:00.000"
    @Published var isPlaying: Bool = false
    @Published var playbackRate: Float = 0
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var hasVideo: Bool = false
    @Published var showingFrames: Bool = false
    @Published var currentFrame: Int = 0
    @Published private(set) var accessibilityTimecodeLabel: String = "0 seconds, 0 milliseconds"

    private var frameRate: Float = 0
    private var minFrameDuration: CMTime = .invalid  // exact frame duration from track
    private var timeObserver: Any?
    private var rateObserver: AnyCancellable?
    private var keyEventMonitor: Any?
    private var isScrubbing = false
    private var scrubTask: Task<Void, Never>?
    private var frameStepPosition: CMTime?
    private var isSteppingFrames = false
    private var stepEndTask: Task<Void, Never>?
    private var arrowHolding = false
    // JKL state: 0=paused, +N=forward at jklSpeeds[N-1], -N=backward at jklSpeeds[N-1]
    private var jklIndex = 0
    private let jklSpeeds: [Float] = [1, 2, 4, 8, 16]

    init() {
        // Disable stall-avoidance so play() starts outputting audio immediately after a seek —
        // essential for short audio preview windows during frame stepping.
        player.automaticallyWaitsToMinimizeStalling = false
        setupTimeObserver()
        setupRateObserver()
        setupKeyEventMonitor()
    }

    deinit {
        scrubTask?.cancel()
        stepEndTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
    }

    // MARK: - Public

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.title = "Open Video File"
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func load(url: URL) {
        cancelScrub()
        arrowHolding = false
        jklIndex = 0
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        hasVideo = true
        displayTimecode = "00:00:00.000"
        currentTime = 0; currentFrame = 0; frameRate = 0; duration = 0
        minFrameDuration = .invalid
        accessibilityTimecodeLabel = "0 seconds, 0 milliseconds"
        Task { @MainActor in
            do {
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    self.frameRate = try await track.load(.nominalFrameRate)
                    self.minFrameDuration = try await track.load(.minFrameDuration)
                }
                self.duration = CMTimeGetSeconds(try await asset.load(.duration))
            } catch {}
        }
    }

    func togglePlayPause() {
        cancelScrub()
        if isPlaying { jklIndex = 0; player.pause() }
        else          { jklIndex = 1; player.rate = 1.0 }
    }

    func stepForward() {
        guard !arrowHolding else { return }
        cancelScrub(preservingFrameStepPosition: true)
        isSteppingFrames = true
        scheduleStepEnd()
        seekOneFrame(forward: true) { [weak self] target in
            self?.scheduleScrubAudio(returningTo: target)
        }
    }

    func stepBackward() {
        guard !arrowHolding else { return }
        cancelScrub(preservingFrameStepPosition: true)
        isSteppingFrames = true
        scheduleStepEnd()
        seekOneFrame(forward: false) { [weak self] target in
            self?.scheduleScrubAudio(returningTo: target)
        }
    }

    func seekForward()  { cancelScrub(); seekTo(seconds: min(currentTime + 10, duration)) }
    func seekBackward() { cancelScrub(); seekTo(seconds: max(currentTime - 10, 0)) }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        cancelScrub()
        seekTo(seconds: fraction * duration)
    }

    func toggleTimecodeDisplay() {
        showingFrames.toggle()
        accessibilityTimecodeLabel = buildAccessibilityLabel()
    }

    func copyTimecode() {
        let timecode = Self.formatTimecode(frameStepPosition ?? player.currentTime())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(timecode, forType: .string)
    }

    // MARK: - JKL

    func pressJ() {
        cancelScrub()
        jklIndex = jklIndex > 0 ? -1 : max(jklIndex - 1, -jklSpeeds.count)
        applyJKLRate()
    }

    func pressK() { togglePlayPause() }

    func pressL() {
        cancelScrub()
        jklIndex = jklIndex < 0 ? 1 : min(jklIndex + 1, jklSpeeds.count)
        applyJKLRate()
    }

    // MARK: - Private: arrow key held / released

    private func arrowHeld(forward: Bool) {
        if !arrowHolding {
            arrowHolding = true
            cancelScrub()
            jklIndex = forward ? 1 : -1
        }
        let rate: Float = forward ? 1.0 : -1.0
        if player.rate != rate { player.rate = rate }
    }

    private func arrowKeyUp() {
        guard arrowHolding else { return }
        arrowHolding = false
        cancelScrub()
        jklIndex = 0
        player.pause()
    }

    // MARK: - Private: frame seeking

    // Seeks forward or backward by exactly one frame using the track's minFrameDuration
    // (or a computed fallback) and calls the completion handler once the seek has landed.
    // This ensures player.play() starts from the correct frame, not the pre-seek position.
    private func seekOneFrame(forward: Bool, completion: @escaping (CMTime) -> Void) {
        let frameDur: CMTime
        if minFrameDuration.isValid, minFrameDuration.value > 0 {
            frameDur = minFrameDuration
        } else if frameRate > 0 {
            frameDur = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        } else {
            frameDur = CMTime(value: 1, timescale: 30)
        }

        let current = frameStepPosition ?? player.currentTime()
        let target: CMTime = forward
            ? CMTimeAdd(current, frameDur)
            : CMTimeMaximum(CMTimeSubtract(current, frameDur), .zero)
        frameStepPosition = target

        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            completion(target)
        }
    }

    // MARK: - Private: audio scrub

    // Plays briefly so the user hears the audio at the current frame.
    // 200 ms ensures the clip survives audio output latency (~50 ms) and
    // AVPlayer's internal buffer fill time after a seek.
    private func scheduleScrubAudio(returningTo target: CMTime) {
        guard frameStepPosition == target else { return }
        isScrubbing = true
        player.play()
        scrubTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, self.isScrubbing,
                  self.frameStepPosition == target else { return }
            self.isScrubbing = false
            self.player.pause()
            await self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func cancelScrub(preservingFrameStepPosition: Bool = false) {
        scrubTask?.cancel()
        scrubTask = nil
        if isScrubbing { isScrubbing = false; player.pause() }
        if !preservingFrameStepPosition { frameStepPosition = nil }
    }

    private func scheduleStepEnd() {
        stepEndTask?.cancel()
        stepEndTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.isSteppingFrames = false
            self.accessibilityTimecodeLabel = self.buildAccessibilityLabel()
        }
    }

    private func seekTo(seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func applyJKLRate() {
        guard jklIndex != 0 else { player.pause(); return }
        let speed = jklSpeeds[min(abs(jklIndex) - 1, jklSpeeds.count - 1)]
        player.rate = jklIndex > 0 ? speed : -speed
    }

    // MARK: - Private: observers & key monitor

    private func setupTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let formatted = Self.formatTimecode(time)
            self.displayTimecode = formatted
            let secs = CMTimeGetSeconds(time)
            self.currentTime = secs.isFinite ? secs : 0
            if self.frameRate > 0 { self.currentFrame = Int(self.currentTime * Double(self.frameRate)) }
            if !self.isPlaying && !self.isScrubbing && !self.isSteppingFrames {
                self.accessibilityTimecodeLabel = self.buildAccessibilityLabel()
            }
        }
    }

    private func setupRateObserver() {
        rateObserver = player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.isPlaying = rate != 0
                self?.playbackRate = rate
            }
    }

    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.hasVideo else { return event }

            switch event.type {
            case .keyDown:
                switch event.keyCode {
                case 49: // Space — toggle, ignore repeat
                    if !event.isARepeat { self.togglePlayPause() }
                    return nil
                case 123: // Left arrow
                    if event.isARepeat { self.arrowHeld(forward: false) }
                    else               { self.stepBackward() }
                    return nil
                case 124: // Right arrow
                    if event.isARepeat { self.arrowHeld(forward: true) }
                    else               { self.stepForward() }
                    return nil
                default: break
                }
                // Letter shortcuts — ignore key repeat.
                if !event.isARepeat {
                    let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
                    if event.modifierFlags.intersection(commandModifiers).isEmpty,
                       event.charactersIgnoringModifiers?.lowercased() == "c" {
                        self.copyTimecode()
                        return nil
                    }
                    switch event.characters?.lowercased() {
                    case "j": self.pressJ(); return nil
                    case "k": self.pressK(); return nil
                    case "l": self.pressL(); return nil
                    default: return event
                    }
                }
                return event

            case .keyUp:
                switch event.keyCode {
                case 123, 124: self.arrowKeyUp(); return nil
                default: return event
                }

            default:
                return event
            }
        }
    }

    // MARK: - Private: accessibility & timecode formatting

    private func buildAccessibilityLabel() -> String {
        if showingFrames { return "Frame \(currentFrame)" }
        let parts = displayTimecode.split(separator: ":")
        guard parts.count == 3 else { return displayTimecode }
        let h = Int(parts[0]) ?? 0
        let m = Int(parts[1]) ?? 0
        let secMs = parts[2].split(separator: ".")
        let s  = Int(secMs.first ?? "0") ?? 0
        let ms = Int(secMs.last  ?? "0") ?? 0
        var c: [String] = []
        if h > 0 { c.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { c.append("\(m) minute\(m == 1 ? "" : "s")") }
        c.append("\(s) second\(s == 1 ? "" : "s")")
        c.append("\(ms) millisecond\(ms == 1 ? "" : "s")")
        return c.joined(separator: ", ")
    }

    static func formatTimecode(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else { return "00:00:00.000" }
        let totalSeconds = CMTimeGetSeconds(time)
        guard totalSeconds.isFinite, totalSeconds >= 0 else { return "00:00:00.000" }
        let totalMs = Int((totalSeconds * 1000).rounded(.towardZero))
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        return String(format: "%02d:%02d:%02d.%03d",
                      totalSec / 3600, (totalSec / 60) % 60, totalSec % 60, ms)
    }
}
