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
    private var keyEventMonitor: Any?
    private var keyboardCommandsAreActive: (() -> Bool)?
    private var bladeAtPlayhead: (() -> Void)?
    private var quickCrossTransition: (() -> Void)?
    private var quickFade: (() -> Void)?
    private var currentPreviewFailure: ProjectPreviewFailure?

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
        setupKeyEventMonitor()
    }

    deinit {
        buildTask?.cancel()
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

    func onQuickCrossTransition(_ handler: @escaping () -> Void) {
        quickCrossTransition = handler
    }

    func onQuickFade(_ handler: @escaping () -> Void) {
        quickFade = handler
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

    func copyTimecode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayTimecode, forType: .string)
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
        seekPrecisely(to: max(currentTime - ProjectTime(seconds: 10), .zero))
    }

    func seekForward() {
        seekPrecisely(to: min(currentTime + ProjectTime(seconds: 10), projectDuration))
    }

    func pressJ() {
        guard canControlPlayback else { return }
        jklIndex = jklIndex > 0 ? -1 : max(jklIndex - 1, -jklSpeeds.count)
        applyJKLRate()
    }

    func pressK() {
        togglePlayback()
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

    private func navigate(to destination: ProjectTime) {
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
        if !isPlaying { refreshAccessibilityTimecode() }
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
                case "c": self.copyTimecode(); return nil
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
