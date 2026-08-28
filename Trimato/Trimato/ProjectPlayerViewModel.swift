import AVFoundation
import AppKit
import Combine
import Foundation

struct ProjectPreviewFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let transitionID: UUID?
}

private nonisolated enum ProjectPreviewPreparationError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation):
            "The transition render finished, but \(operation) did not complete in time. The project was not changed."
        }
    }
}

private nonisolated final class ProjectPreviewOperationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func value() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed() { resolve(.success(())) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
final class ProjectPlayerViewModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var presentedPreviewFailure: ProjectPreviewFailure?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = ProjectTime.zero
    @Published private(set) var currentFrame = 0
    @Published private(set) var displayTimecode = "00:00:00.000"
    @Published private(set) var accessibilityTimecodeLabel = "0 seconds, 0 milliseconds"
    @Published private(set) var showingFrames = false
    @Published private(set) var playbackRate: Float = 0
    @Published private(set) var inMarker: ProjectTime?
    @Published private(set) var outMarker: ProjectTime?

    var canControlPlayback: Bool { player.currentItem != nil && !isPreparing }
    var duration: ProjectTime { projectDuration }
    var playbackFraction: Double {
        guard projectDuration > .zero else { return 0 }
        return min(max(currentTime.seconds / projectDuration.seconds, 0), 1)
    }
    var playbackFractionStep: Double {
        Self.playbackFractionStep(duration: projectDuration, frameRate: projectFrameRate)
    }
    var inMarkerDisplay: String { inMarker.map(ProjectTimecodeFormatter.string) ?? "Not set" }
    var outMarkerDisplay: String { outMarker.map(ProjectTimecodeFormatter.string) ?? "Not set" }
    var canExport: Bool {
        if inMarker == nil, outMarker == nil { return projectDuration > .zero }
        return exportRange != nil
    }
    var hasValidExportSelection: Bool {
        if inMarker == nil, outMarker == nil { return true }
        return exportRange != nil
    }
    var exportRange: ProjectTimeRange? {
        Self.validExportRange(inMarker: inMarker, outMarker: outMarker)
    }

    private var buildTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var rateObserver: AnyCancellable?
    private var timeObserver: Any?
    private var temporaryMediaURLs: [URL] = []
    private var projectDuration = ProjectTime.zero
    private var projectFrameRate = 30.0
    private var editPoints: [ProjectTime] = []
    private var jklIndex = 0
    private let jklSpeeds: [Float] = [1, 2, 4, 8]
    private var arrowHolding = false
    private var scrubTask: Task<Void, Never>?
    private var stepEndTask: Task<Void, Never>?
    private var frameStepPosition: ProjectTime?
    private var isScrubbing = false
    private var isSteppingFrames = false
    private var keyEventMonitor: Any?
    private var keyboardCommandsAreActive: (() -> Bool)?
    private var bladeAtPlayhead: (() -> Void)?
    private var standardTransition: (() -> Void)?
    private var quickCrossTransition: (() -> Void)?
    private var quickFade: (() -> Void)?
    private var openClipAtPlayhead: (() -> Void)?
    private var currentPreviewFailure: ProjectPreviewFailure?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        rateObserver = player.publisher(for: \.rate)
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in
                guard let self else { return }
                self.isPlaying = rate != 0
                self.playbackRate = rate
                if rate == 0, !self.isScrubbing, !self.isSteppingFrames {
                    self.refreshAccessibilityTimecode()
                }
            }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.updateDisplayedTime(ProjectTime(time))
            }
        }
        setupKeyEventMonitor()
    }

    deinit {
        buildTask?.cancel()
        scrubTask?.cancel()
        stepEndTask?.cancel()
        for url in temporaryMediaURLs { ProxyMediaManager.removeProxy(at: url) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
    }

    func scopeKeyboardCommands(to isActive: @escaping () -> Bool) {
        keyboardCommandsAreActive = isActive
    }

    func onBladeAtPlayhead(_ handler: @escaping () -> Void) {
        bladeAtPlayhead = handler
    }

    func onStandardTransition(_ handler: @escaping () -> Void) {
        standardTransition = handler
    }

    func onQuickCrossTransition(_ handler: @escaping () -> Void) {
        quickCrossTransition = handler
    }

    func onQuickFade(_ handler: @escaping () -> Void) {
        quickFade = handler
    }

    func onOpenClipAtPlayhead(_ handler: @escaping () -> Void) {
        openClipAtPlayhead = handler
    }

    func dismissPreviewFailure() {
        presentedPreviewFailure = nil
    }

    func showPreviewFailure() {
        presentedPreviewFailure = currentPreviewFailure
    }

    func prepare(
        project: TrimatoProject,
        mediaURLs: [UUID: URL],
        initialTime: ProjectTime = .zero
    ) {
        buildTask?.cancel()
        cancelFrameStepping()
        let preparationID = UUID()
        self.preparationID = preparationID
        player.pause()
        jklIndex = 0
        arrowHolding = false
        projectDuration = project.duration
        projectFrameRate = max(project.format.frameRate ?? 30, 1)
        let boundedInitialTime = min(max(initialTime, .zero), projectDuration)
        updateDisplayedTime(boundedInitialTime)
        if let inMarker, inMarker > projectDuration { self.inMarker = nil }
        if let outMarker, outMarker > projectDuration { self.outMarker = nil }
        editPoints = Self.editPoints(in: project)
        removeTemporaryMedia()
        guard project.tracks.contains(where: { !$0.clips.isEmpty }) else {
            player.replaceCurrentItem(with: nil)
            isPreparing = false
            errorMessage = nil
            currentPreviewFailure = nil
            presentedPreviewFailure = nil
            return
        }
        isPreparing = true
        errorMessage = nil
        currentPreviewFailure = nil
        presentedPreviewFailure = nil
        buildTask = Task { @MainActor in
            var pendingTemporaryMediaURLs: [URL] = []
            do {
                let result = try await ProjectCompositionBuilder.build(
                    project: project,
                    mediaURLs: mediaURLs,
                    purpose: .preview
                )
                pendingTemporaryMediaURLs = result.temporaryMediaURLs
                try Task.checkCancellation()
                guard self.preparationID == preparationID else {
                    Self.removeTemporaryMedia(at: pendingTemporaryMediaURLs)
                    return
                }
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                player.replaceCurrentItem(with: item)
                await player.seek(
                    to: boundedInitialTime.cmTime,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                try Task.checkCancellation()
                guard self.preparationID == preparationID else {
                    Self.removeTemporaryMedia(at: pendingTemporaryMediaURLs)
                    return
                }
                temporaryMediaURLs = pendingTemporaryMediaURLs
                pendingTemporaryMediaURLs.removeAll()
                isPreparing = false
                currentPreviewFailure = nil
                presentedPreviewFailure = nil
            } catch is CancellationError {
                Self.removeTemporaryMedia(at: pendingTemporaryMediaURLs)
                if self.preparationID == preparationID {
                    isPreparing = false
                }
            } catch {
                Self.removeTemporaryMedia(at: pendingTemporaryMediaURLs)
                if self.preparationID == preparationID {
                    player.replaceCurrentItem(with: nil)
                    isPreparing = false
                    errorMessage = error.localizedDescription
                    let failure: ProjectPreviewFailure
                    if let transitionError = error as? ProjectTransitionRenderError {
                        failure = ProjectPreviewFailure(
                            title: "Project Preview Failed",
                            message: transitionError.localizedDescription,
                            transitionID: transitionError.transitionID
                        )
                    } else {
                        failure = ProjectPreviewFailure(
                            title: "Project Preview Failed",
                            message: error.localizedDescription,
                            transitionID: nil
                        )
                    }
                    currentPreviewFailure = failure
                    presentedPreviewFailure = failure
                }
            }
        }
    }

    func prepareTransitionPreview(
        project: TrimatoProject,
        mediaURLs: [UUID: URL],
        initialTime: ProjectTime,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        buildTask?.cancel()
        cancelFrameStepping()
        let requestID = UUID()
        preparationID = requestID
        player.pause()
        isPreparing = true
        errorMessage = nil
        currentPreviewFailure = nil
        presentedPreviewFailure = nil

        var pendingTemporaryMediaURLs: [URL] = []
        let previousPlayerItem = player.currentItem
        var replacedPlayerItem = false
        var stagingPlayer: AVPlayer?
        do {
            let result = try await ProjectCompositionBuilder.build(
                project: project,
                mediaURLs: mediaURLs,
                purpose: .preview,
                progress: progress
            )
            pendingTemporaryMediaURLs = result.temporaryMediaURLs
            try Task.checkCancellation()
            guard preparationID == requestID else { throw CancellationError() }

            let stagedItem = Self.makeTransitionPreviewItem(from: result)
            let duration = project.duration
            let boundedInitialTime = min(max(initialTime, .zero), duration)
            let stagedPlayer = AVPlayer(playerItem: stagedItem)
            stagingPlayer = stagedPlayer
            stagedPlayer.automaticallyWaitsToMinimizeStalling = false
            try await waitUntilReadyToPlay(stagedItem)
            try await seekForTransitionPreview(
                player: stagedPlayer,
                to: boundedInitialTime.cmTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard stagedItem.status == .readyToPlay else {
                throw stagedItem.error ?? ProjectTimelineError.transitionNotAvailable(
                    "The transition preview could not be prepared for playback."
                )
            }
            try Task.checkCancellation()
            guard preparationID == requestID else { throw CancellationError() }
            stagedPlayer.replaceCurrentItem(with: nil)
            stagingPlayer = nil

            let committedItem = Self.makeTransitionPreviewItem(from: result)
            player.replaceCurrentItem(with: committedItem)
            replacedPlayerItem = true
            try await waitUntilReadyToPlay(committedItem)
            progress(0.95)
            try await seekForTransitionPreview(
                player: player,
                to: boundedInitialTime.cmTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            try Task.checkCancellation()
            guard preparationID == requestID else { throw CancellationError() }

            removeTemporaryMedia()
            temporaryMediaURLs = pendingTemporaryMediaURLs
            pendingTemporaryMediaURLs.removeAll()
            projectDuration = duration
            projectFrameRate = max(project.format.frameRate ?? 30, 1)
            editPoints = Self.editPoints(in: project)
            updateDisplayedTime(boundedInitialTime)
            isPreparing = false
            progress(1)
        } catch {
            stagingPlayer?.replaceCurrentItem(with: nil)
            if replacedPlayerItem {
                player.replaceCurrentItem(with: previousPlayerItem)
            }
            Self.removeTemporaryMedia(at: pendingTemporaryMediaURLs)
            if preparationID == requestID { isPreparing = false }
            throw error
        }
    }

    static func makeTransitionPreviewItem(
        from result: ProjectCompositionResult
    ) -> AVPlayerItem {
        let item = AVPlayerItem(asset: result.composition)
        item.videoComposition = result.videoComposition
        item.audioMix = result.audioMix
        return item
    }

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        if item.status == .readyToPlay { return }
        if item.status == .failed {
            throw item.error ?? ProjectTimelineError.transitionNotAvailable(
                "The transition preview could not be prepared for playback."
            )
        }
        let waiter = ProjectPreviewOperationWaiter()
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            switch item.status {
            case .readyToPlay:
                waiter.succeed()
            case .failed:
                waiter.fail(item.error ?? ProjectTimelineError.transitionNotAvailable(
                    "The transition preview could not be prepared for playback."
                ))
            case .unknown:
                break
            @unknown default:
                break
            }
        }
        defer { observation.invalidate() }
        try await waitForTransitionPreviewOperation(waiter, operation: "the project preview")
    }

    private func seekForTransitionPreview(
        player: AVPlayer,
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) async throws {
        let waiter = ProjectPreviewOperationWaiter()
        player.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { finished in
            if finished {
                waiter.succeed()
            } else {
                waiter.fail(CancellationError())
            }
        }
        try await waitForTransitionPreviewOperation(waiter, operation: "positioning the project playhead")
    }

    private func waitForTransitionPreviewOperation(
        _ waiter: ProjectPreviewOperationWaiter,
        operation: String
    ) async throws {
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            waiter.fail(ProjectPreviewPreparationError.timedOut(operation))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            waiter.fail(CancellationError())
        }
    }

    func togglePlayback() {
        guard canControlPlayback else { return }
        cancelFrameStepping()
        if isPlaying {
            stop()
        } else {
            jklIndex = 1
            player.rate = 1
        }
    }

    func seek(to time: ProjectTime) {
        cancelFrameStepping()
        seekPrecisely(to: time)
    }

    func seek(toFraction fraction: Double) {
        guard projectDuration > .zero else { return }
        cancelFrameStepping()
        seekPrecisely(to: ProjectTime(seconds: min(max(fraction, 0), 1) * projectDuration.seconds))
    }

    func toggleTimecodeDisplay() {
        showingFrames.toggle()
        refreshAccessibilityTimecode()
    }

    func markIn() {
        guard canControlPlayback else { return }
        inMarker = currentTime
        announce("In marked at \(Self.accessibilityTimeLabel(time: currentTime, showingFrames: false, frameRate: projectFrameRate))")
    }

    func markOut() {
        guard canControlPlayback else { return }
        outMarker = currentTime
        announce("Out marked at \(Self.accessibilityTimeLabel(time: currentTime, showingFrames: false, frameRate: projectFrameRate))")
    }

    func clearIn() {
        guard inMarker != nil else { return }
        inMarker = nil
        announce("In marker cleared")
    }

    func clearOut() {
        guard outMarker != nil else { return }
        outMarker = nil
        announce("Out marker cleared")
    }

    func seekBackward() {
        cancelFrameStepping()
        seekPrecisely(to: max(currentTime - ProjectTime(seconds: 10), .zero))
    }

    func seekForward() {
        cancelFrameStepping()
        seekPrecisely(to: min(currentTime + ProjectTime(seconds: 10), projectDuration))
    }

    func pressJ() {
        guard canControlPlayback else { return }
        cancelFrameStepping()
        jklIndex = jklIndex > 0 ? -1 : max(jklIndex - 1, -jklSpeeds.count)
        applyJKLRate()
    }

    func pressK() {
        togglePlayback()
    }

    func pressL() {
        guard canControlPlayback else { return }
        cancelFrameStepping()
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
        cancelFrameStepping()
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
        navigate(to: timelinePoints.last(where: { $0 < currentTime }) ?? .zero)
    }

    func goToNextEdit() {
        navigate(to: timelinePoints.first(where: { $0 > currentTime }) ?? projectDuration)
    }

    func goToStart() {
        navigate(to: .zero)
    }

    func goToEnd() {
        navigate(to: projectDuration)
    }

    private func removeTemporaryMedia() {
        Self.removeTemporaryMedia(at: temporaryMediaURLs)
        temporaryMediaURLs.removeAll()
    }

    private nonisolated static func removeTemporaryMedia(at urls: [URL]) {
        for url in urls { ProxyMediaManager.removeProxy(at: url) }
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

    private var timelinePoints: [ProjectTime] {
        var points = Set(editPoints)
        if let inMarker { points.insert(inMarker) }
        if let outMarker { points.insert(outMarker) }
        return points.sorted()
    }

    private func stepFrame(forward: Bool) {
        guard canControlPlayback, !arrowHolding else { return }
        cancelScrub(preservingFrameStepPosition: true)
        isSteppingFrames = true
        scheduleStepEnd()
        jklIndex = 0
        player.pause()
        let destination = Self.frameStepDestination(
            current: frameStepPosition ?? currentTime,
            duration: projectDuration,
            frameRate: projectFrameRate,
            forward: forward
        )
        frameStepPosition = destination
        updateDisplayedTime(destination)
        player.seek(
            to: destination.cmTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                self?.scheduleScrubAudio(returningTo: destination)
            }
        }
    }

    private func seekPrecisely(to time: ProjectTime) {
        let bounded = min(max(time, .zero), projectDuration)
        player.seek(to: bounded.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        updateDisplayedTime(bounded)
    }

    private func navigate(to destination: ProjectTime) {
        cancelFrameStepping()
        seekPrecisely(to: destination)
        announce(Self.navigationAnnouncement(
            destination: destination,
            duration: projectDuration,
            inMarker: inMarker,
            outMarker: outMarker,
            frameRate: projectFrameRate
        ))
    }

    private func updateDisplayedTime(_ time: ProjectTime) {
        currentTime = time
        currentFrame = max(Int((time.seconds * projectFrameRate).rounded(.towardZero)), 0)
        displayTimecode = ProjectTimecodeFormatter.string(time)
        if !isPlaying, !isScrubbing, !isSteppingFrames {
            refreshAccessibilityTimecode()
        }
    }

    private func scheduleScrubAudio(returningTo target: ProjectTime) {
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
            await self.player.seek(
                to: target.cmTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func cancelScrub(preservingFrameStepPosition: Bool = false) {
        scrubTask?.cancel()
        scrubTask = nil
        if isScrubbing {
            isScrubbing = false
            player.pause()
        }
        if !preservingFrameStepPosition {
            frameStepPosition = nil
        }
    }

    private func cancelFrameStepping() {
        stepEndTask?.cancel()
        stepEndTask = nil
        isSteppingFrames = false
        cancelScrub()
    }

    private func scheduleStepEnd() {
        stepEndTask?.cancel()
        stepEndTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.isSteppingFrames = false
            self.refreshAccessibilityTimecode()
        }
    }

    private func refreshAccessibilityTimecode() {
        accessibilityTimecodeLabel = Self.accessibilityTimeLabel(
            time: currentTime,
            showingFrames: showingFrames,
            frameRate: projectFrameRate
        )
    }

    private func announce(_ message: String) {
        let element: Any = NSApp.mainWindow?.contentView ?? NSApp!
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
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

    nonisolated static func frameStepDestination(
        current: ProjectTime,
        duration: ProjectTime,
        frameRate: Double,
        forward: Bool
    ) -> ProjectTime {
        let frameDuration = ProjectTime(seconds: 1 / max(frameRate, 1))
        return forward
            ? min(current + frameDuration, duration)
            : max(current - frameDuration, .zero)
    }

    nonisolated static func playbackFractionStep(
        duration: ProjectTime,
        frameRate: Double
    ) -> Double {
        guard duration > .zero else { return 1 }
        return min(max(1 / (duration.seconds * max(frameRate, 1)), 0.000_001), 1)
    }

    nonisolated static func validExportRange(
        inMarker: ProjectTime?,
        outMarker: ProjectTime?
    ) -> ProjectTimeRange? {
        guard let inMarker, let outMarker, inMarker < outMarker else { return nil }
        return ProjectTimeRange(start: inMarker, duration: outMarker - inMarker)
    }

    nonisolated static func navigationAnnouncement(
        destination: ProjectTime,
        duration: ProjectTime,
        inMarker: ProjectTime?,
        outMarker: ProjectTime?,
        frameRate: Double
    ) -> String {
        let pointName: String
        if destination == .zero {
            pointName = "Start"
        } else if destination == duration {
            pointName = "End"
        } else if destination == inMarker {
            pointName = "In"
        } else if destination == outMarker {
            pointName = "Out"
        } else {
            pointName = "Edit point"
        }
        var timeLabel = accessibilityTimeLabel(
            time: destination,
            showingFrames: false,
            frameRate: frameRate
        )
        let zeroMilliseconds = ", 0 milliseconds"
        if timeLabel.hasSuffix(zeroMilliseconds) {
            timeLabel.removeLast(zeroMilliseconds.count)
        }
        return "\(pointName), \(timeLabel)"
    }

    nonisolated static func editPoints(in project: TrimatoProject) -> [ProjectTime] {
        var points: Set<ProjectTime> = [.zero, project.duration]
        var cursor = ProjectTime.zero
        for clip in project.primaryTimeline {
            cursor = cursor + clip.duration
            points.insert(cursor)
        }
        for track in project.tracks {
            for clip in track.clips {
                points.insert(clip.timelineStart)
                points.insert(clip.timelineEnd)
            }
        }
        for cutaway in project.cutaways {
            points.insert(cutaway.start)
            points.insert(cutaway.end)
        }
        return points.sorted()
    }

    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.canControlPlayback, NSApp.modalWindow == nil,
                  self.keyboardCommandsAreActive?() == true,
                  !self.isEditingText(in: event.window) else { return event }

            let commandSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let modifiers = event.modifierFlags.intersection(commandSet)
            let unmodified = event.modifierFlags.intersection([.command, .control, .option]).isEmpty

            switch event.type {
            case .keyDown:
                if modifiers == .command {
                    switch event.keyCode {
                    case 123:
                        if !event.isARepeat { self.goToPreviousEdit() }
                        return nil
                    case 124:
                        if !event.isARepeat { self.goToNextEdit() }
                        return nil
                    case 126:
                        if !event.isARepeat { self.goToStart() }
                        return nil
                    case 125:
                        if !event.isARepeat { self.goToEnd() }
                        return nil
                    default:
                        break
                    }
                    if event.charactersIgnoringModifiers?.lowercased() == "b" {
                        if !event.isARepeat { self.bladeAtPlayhead?() }
                        return nil
                    }
                    if event.charactersIgnoringModifiers?.lowercased() == "t" {
                        if !event.isARepeat { self.standardTransition?() }
                        return nil
                    }
                }
                switch event.keyCode {
                case 49:
                    guard unmodified else { return event }
                    if !event.isARepeat { self.togglePlayback() }
                    return nil
                case 123:
                    guard unmodified else { return event }
                    event.isARepeat ? self.arrowHeld(forward: false) : self.stepBackward()
                    return nil
                case 124:
                    guard unmodified else { return event }
                    event.isARepeat ? self.arrowHeld(forward: true) : self.stepForward()
                    return nil
                default:
                    break
                }
                guard !event.isARepeat, unmodified else { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": self.openClipAtPlayhead?(); return nil
                case "x": self.quickCrossTransition?(); return nil
                case "f": self.quickFade?(); return nil
                case "i": self.markIn(); return nil
                case "o": self.markOut(); return nil
                case "j": self.pressJ(); return nil
                case "k": self.pressK(); return nil
                case "l": self.pressL(); return nil
                default: return event
                }
            case .keyUp:
                guard unmodified else { return event }
                switch event.keyCode {
                case 123, 124:
                    self.arrowKeyUp()
                    return nil
                default:
                    return event
                }
            default:
                return event
            }
        }
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }
}
