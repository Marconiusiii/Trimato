import AVFoundation

/// Keep one exact seek in flight and chase the newest requested frame (Apple QA1820).
@MainActor
final class FrameSeekCoordinator {
    private struct Request {
        let id = UUID()
        let time: CMTime
        let player: AVPlayer
        let item: AVPlayerItem?
        let completion: @MainActor () -> Void
    }
    private var latest: Request?
    private var seeking = false

    func seek(_ player: AVPlayer, to time: CMTime, completion: @escaping @MainActor () -> Void) {
        latest = Request(time: time, player: player, item: player.currentItem, completion: completion)
        startLatest()
    }

    func cancel() { latest = nil }

    private func startLatest() {
        guard !seeking, let request = latest else { return }
        seeking = true
        request.player.seek(to: request.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seeking = false
                if self.latest?.id == request.id {
                    self.latest = nil
                    if finished, request.player.currentItem === request.item { request.completion() }
                }
                self.startLatest()
            }
        }
    }
}
