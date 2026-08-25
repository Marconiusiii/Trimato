import AVFoundation
import Combine
import Foundation

@MainActor
final class ProjectPlayerViewModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = ProjectTime.zero
    @Published private(set) var currentFrame = 0
    @Published private(set) var displayTimecode = "00:00:00.000"
    @Published private(set) var accessibilityTimecodeLabel = "0 seconds, 0 milliseconds"
    @Published private(set) var showingFrames = false
    @Published private(set) var playbackRate: Float = 0

    var canControlPlayback: Bool { player.currentItem != nil && !isPreparing }
    var duration: ProjectTime { projectDuration }
    var playbackFraction: Double {
        guard projectDuration > .zero else { return 0 }
        return min(max(currentTime.seconds / projectDuration.seconds, 0), 1)
    }

    private var buildTask: Task<Void, Never>?
    private var rateObserver: AnyCancellable?
    private var timeObserver: Any?
    private var temporaryMediaURLs: [URL] = []
    private var projectDuration = ProjectTime.zero
    private var projectFrameRate = 30.0
    private var editPoints: [ProjectTime] = []
    private var jklIndex = 0
    private let jklSpeeds: [Float] = [1, 2, 4, 8]
    private var arrowHolding = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        rateObserver = player.publisher(for: \.rate)
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in
                guard let self else { return }
                self.isPlaying = rate != 0
                self.playbackRate = rate
                if rate == 0 { self.refreshAccessibilityTimecode() }
            }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.updateDisplayedTime(ProjectTime(time))
            }
        }
    }

    deinit {
        buildTask?.cancel()
        for url in temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func prepare(project: TrimatoProject, mediaURLs: [UUID: URL]) {
        buildTask?.cancel()
        player.pause()
        jklIndex = 0
        arrowHolding = false
        projectDuration = project.duration
        projectFrameRate = max(project.format.frameRate ?? 30, 1)
        updateDisplayedTime(.zero)
        editPoints = Self.editPoints(in: project)
        removeTemporaryMedia()
        guard !project.primaryTimeline.isEmpty else {
            player.replaceCurrentItem(with: nil)
            errorMessage = nil
            return
        }
        isPreparing = true
        errorMessage = nil
        buildTask = Task { @MainActor in
            do {
                let result = try await ProjectCompositionBuilder.build(
                    project: project,
                    mediaURLs: mediaURLs,
                    purpose: .preview
                )
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                player.replaceCurrentItem(with: item)
                temporaryMediaURLs = result.temporaryMediaURLs
                isPreparing = false
            } catch is CancellationError {
                isPreparing = false
            } catch {
                player.replaceCurrentItem(with: nil)
                isPreparing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard canControlPlayback else { return }
        if isPlaying {
            stop()
        } else {
            jklIndex = 1
            player.rate = 1
        }
    }

    func seek(to time: ProjectTime) {
        seekPrecisely(to: time)
    }

    func seek(toFraction fraction: Double) {
        guard projectDuration > .zero else { return }
        seekPrecisely(to: ProjectTime(seconds: min(max(fraction, 0), 1) * projectDuration.seconds))
    }

    func toggleTimecodeDisplay() {
        showingFrames.toggle()
        refreshAccessibilityTimecode()
    }

    func pressJ() {
        guard canControlPlayback else { return }
        jklIndex = jklIndex > 0 ? -1 : max(jklIndex - 1, -jklSpeeds.count)
        applyJKLRate()
    }

    func pressK() {
        guard canControlPlayback else { return }
        stop()
    }

    func pressL() {
        guard canControlPlayback else { return }
        jklIndex = jklIndex < 0 ? 1 : min(jklIndex + 1, jklSpeeds.count)
        applyJKLRate()
    }

    func stepBackward() {
        stepFrame(forward: false)
    }

    func stepForward() {
        stepFrame(forward: true)
    }

    func arrowHeld(forward: Bool) {
        guard canControlPlayback else { return }
        if !arrowHolding {
            arrowHolding = true
            jklIndex = forward ? 1 : -1
        }
        player.rate = forward ? 1 : -1
    }

    func arrowKeyUp() {
        guard arrowHolding else { return }
        arrowHolding = false
        stop()
    }

    func goToPreviousEdit() {
        guard let destination = editPoints.last(where: { $0 < currentTime }) else {
            seekPrecisely(to: .zero)
            return
        }
        seekPrecisely(to: destination)
    }

    func goToNextEdit() {
        guard let destination = editPoints.first(where: { $0 > currentTime }) else {
            seekPrecisely(to: projectDuration)
            return
        }
        seekPrecisely(to: destination)
    }

    func goToStart() {
        seekPrecisely(to: .zero)
    }

    func goToEnd() {
        seekPrecisely(to: projectDuration)
    }

    func clearError() {
        errorMessage = nil
    }

    private func removeTemporaryMedia() {
        for url in temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        temporaryMediaURLs.removeAll()
    }

    private func stop() {
        jklIndex = 0
        player.pause()
    }

    private func applyJKLRate() {
        guard jklIndex != 0 else {
            player.pause()
            return
        }
        let speed = jklSpeeds[min(abs(jklIndex) - 1, jklSpeeds.count - 1)]
        player.rate = jklIndex > 0 ? speed : -speed
    }

    private func stepFrame(forward: Bool) {
        guard canControlPlayback, !arrowHolding else { return }
        stop()
        let frameDuration = ProjectTime(seconds: 1 / projectFrameRate)
        let destination = forward
            ? min(currentTime + frameDuration, projectDuration)
            : max(currentTime - frameDuration, .zero)
        seekPrecisely(to: destination)
    }

    private func seekPrecisely(to time: ProjectTime) {
        let bounded = min(max(time, .zero), projectDuration)
        player.seek(to: bounded.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        updateDisplayedTime(bounded)
    }

    private func updateDisplayedTime(_ time: ProjectTime) {
        currentTime = time
        currentFrame = max(Int((time.seconds * projectFrameRate).rounded(.towardZero)), 0)
        displayTimecode = ProjectTimecodeFormatter.string(time)
        if !isPlaying { refreshAccessibilityTimecode() }
    }

    private func refreshAccessibilityTimecode() {
        accessibilityTimecodeLabel = Self.accessibilityTimeLabel(
            time: currentTime,
            showingFrames: showingFrames,
            frameRate: projectFrameRate
        )
    }

    nonisolated static func accessibilityTimeLabel(
        time: ProjectTime,
        showingFrames: Bool,
        frameRate: Double
    ) -> String {
        if showingFrames {
            let frame = max(Int((time.seconds * max(frameRate, 1)).rounded(.towardZero)), 0)
            return "Frame \(frame)"
        }

        let milliseconds = max(Int((time.seconds * 1_000).rounded()), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        var components: [String] = []
        if hours > 0 { components.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { components.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        components.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        components.append("\(remainder) millisecond\(remainder == 1 ? "" : "s")")
        return components.joined(separator: ", ")
    }

    nonisolated static func editPoints(in project: TrimatoProject) -> [ProjectTime] {
        var points: Set<ProjectTime> = [.zero, project.duration]
        var cursor = ProjectTime.zero
        for clip in project.primaryTimeline {
            cursor = cursor + clip.duration
            points.insert(cursor)
        }
        for cutaway in project.cutaways {
            points.insert(cutaway.start)
            points.insert(cutaway.end)
        }
        return points.sorted()
    }
}
