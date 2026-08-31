import AVFoundation
import Combine

/// Owns preparation only. A successful commit transfers the output file to the player.
/// Until then, the existing player item and the last successful settings stay intact.
@MainActor
final class ClipPreviewCoordinator: ObservableObject {
    struct Request: Equatable {
        let source: URL
        let filters: [ClipFilter]
        let audio: Bool
        let segments: [SourceSegment]
        let audioSettings: AudioClipSettings?

        var requiresRender: Bool {
            AudioClipPreviewPlan.requiresRender(for: audioSettings) || filters.contains { $0.enabled }
        }
    }

    enum State: Equatable {
        case ready, preparing, cancelled, failed(String)
    }

    typealias Render = @MainActor (Request, @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL
    typealias Prepare = @MainActor (URL, Bool) async throws -> AVAsset

    @Published private(set) var state: State = .ready
    @Published private(set) var progress = 0.0
    @Published var errorMessage: String?
    private(set) var lastSuccessfulRequest: Request?
    private var currentRequest: Request?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private let render: Render
    private let prepare: Prepare
    private let remove: (URL) -> Void

    init(
        render: @escaping Render = { request, progress in
            try await ClipFilterRenderer.render(
                source: request.source, filters: request.filters, audio: request.audio,
                duration: request.segments.reduce(0) { $0 + $1.duration.seconds },
                segments: request.segments, audioSettings: request.audioSettings, progress: progress
            )
        },
        prepare: @escaping Prepare = { url, audio in
            let asset = AVURLAsset(url: url)
            guard try await asset.loadTracks(withMediaType: audio ? .audio : .video).first != nil else {
                throw AudioPreviewPlaybackError.unavailable
            }
            try Task.checkCancellation()
            return asset
        },
        remove: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    ) {
        self.render = render
        self.prepare = prepare
        self.remove = remove
    }

    func update(
        _ request: Request,
        debounce: Bool = true,
        force: Bool = false,
        readiness: @escaping @MainActor (Bool) -> Void,
        restoreOriginal: @MainActor () -> Void,
        commit: @escaping @MainActor (AVAsset, URL, Bool) -> Void
    ) {
        // Several observed properties can change together, including after recovery.
        if !force, currentRequest == request { return }
        invalidate()
        currentRequest = request
        errorMessage = nil
        if !request.requiresRender {
            restoreOriginal()
            lastSuccessfulRequest = request
            state = .ready
            readiness(true)
            return
        }

        let id = requestID
        state = .preparing
        progress = 0
        readiness(false)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var output: URL?
            defer { if let output { self.remove(output) } }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                let url = try await self.render(request) { [weak self] value in
                    guard let self, self.requestID == id else { return }
                    self.progress = min(max(value, 0), 1)
                }
                output = url
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                let asset = try await self.prepare(url, request.audio)
                // Preparation suspends. Check again before touching the live player.
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                commit(asset, url, request.audio)
                output = nil
                self.lastSuccessfulRequest = request
                self.state = .ready
                self.progress = 1
                self.task = nil
                readiness(true)
            } catch {
                guard self.requestID == id else { return }
                self.task = nil
                if error is CancellationError {
                    self.state = .cancelled
                } else {
                    self.state = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
                // The draft no longer matches the audible/visible preview. Keep
                // Update/Export unavailable until retry or an explicit revert.
                readiness(false)
            }
        }
    }

    func cancel() {
        guard state == .preparing else { return }
        invalidate()
        state = .cancelled
    }

    func reset() {
        invalidate()
        currentRequest = nil
        lastSuccessfulRequest = nil
        errorMessage = nil
        progress = 0
        state = .ready
    }

    private func invalidate() {
        requestID = UUID()
        task?.cancel()
        task = nil
    }
}
