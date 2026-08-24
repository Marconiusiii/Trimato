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

    var canControlPlayback: Bool { player.currentItem != nil && !isPreparing }

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
            .sink { [weak self] rate in self?.isPlaying = rate != 0 }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = ProjectTime(time)
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
        currentTime = bounded
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
