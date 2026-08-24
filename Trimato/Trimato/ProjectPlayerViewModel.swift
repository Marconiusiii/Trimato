import AVFoundation
import Combine
import Foundation

@MainActor
final class ProjectPlayerViewModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPreparing = false
    @Published private(set) var status: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = ProjectTime.zero

    private var buildTask: Task<Void, Never>?
    private var rateObserver: AnyCancellable?
    private var timeObserver: Any?
    private var temporaryMediaURLs: [URL] = []

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
        removeTemporaryMedia()
        guard !project.primaryTimeline.isEmpty else {
            player.replaceCurrentItem(with: nil)
            status = "Add a clip to the project timeline"
            return
        }
        isPreparing = true
        status = "Preparing project preview"
        buildTask = Task { @MainActor in
            do {
                let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: mediaURLs)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                player.replaceCurrentItem(with: item)
                temporaryMediaURLs = result.temporaryMediaURLs
                isPreparing = false
                status = nil
            } catch is CancellationError {
                isPreparing = false
            } catch {
                player.replaceCurrentItem(with: nil)
                isPreparing = false
                status = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        isPlaying ? player.pause() : player.play()
    }

    func seek(to time: ProjectTime) {
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func removeTemporaryMedia() {
        for url in temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        temporaryMediaURLs.removeAll()
    }
}
