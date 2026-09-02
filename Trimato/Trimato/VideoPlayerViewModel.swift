import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

enum StandaloneProjectCreationError: LocalizedError {
    case clipNotReady

    var errorDescription: String? {
        "Wait for the clip to finish preparing and set a valid selection before creating a project."
    }
}

enum AudioPreviewPlaybackError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The processed audio preview could not be prepared for playback."
    }
}

nonisolated enum ClipEditorKeyboardRouting {
    static func reservesArrowKeys(accessibilityIdentifier: String?, accessibilityActions: [String]) -> Bool {
        ClipEditorAccessibilityIdentifier.isAudioSlider(accessibilityIdentifier) &&
            accessibilityActions.contains("AXIncrement") &&
            accessibilityActions.contains("AXDecrement")
    }

    static func reservesSpace(isEditableText: Bool, accessibilityActions: [String]) -> Bool {
        isEditableText || accessibilityActions.contains("AXPress")
    }

    @MainActor
    static func focusedControlReservesSpace(in window: NSWindow?) -> Bool {
        let resolvedWindow = window ?? NSApp.keyWindow
        let isEditableText = (resolvedWindow?.firstResponder as? NSTextView)?.isEditable == true
        if isEditableText { return true }
        return reservesSpace(
            isEditableText: false,
            accessibilityActions: focusedAccessibilityInfo().actions
        )
    }

    @MainActor
    static func focusedControlReservesArrowKeys() -> Bool {
        let info = focusedAccessibilityInfo()
        return reservesArrowKeys(
            accessibilityIdentifier: info.identifier,
            accessibilityActions: info.actions
        )
    }

    @MainActor
    private static func focusedAccessibilityInfo() -> (identifier: String?, actions: [String]) {
        guard let focusedElement = NSApp.accessibilityFocusedUIElement as? NSObject else {
            return (nil, [])
        }
        let actionSelector = NSSelectorFromString("accessibilityActionNames")
        let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
        let identifier = focusedElement.responds(to: identifierSelector)
            ? focusedElement.value(forKey: "accessibilityIdentifier") as? String
            : nil
        guard focusedElement.responds(to: actionSelector) else { return (identifier, []) }
        let rawActions: [String]
        if let actions = focusedElement.value(forKey: "accessibilityActionNames") as? [NSAccessibility.Action] {
            rawActions = actions.map(\.rawValue)
        } else {
            rawActions = focusedElement.value(forKey: "accessibilityActionNames") as? [String] ?? []
        }
        return (identifier, rawActions)
    }
}

nonisolated enum ClipEditorAccessibilityIdentifier {
    static let playhead = "trimato.clip-editor.playhead"
    private static let audioSliderPrefix = "trimato.clip-editor.audio-slider."

    static func audioSlider(_ name: String) -> String {
        audioSliderPrefix + name
    }

    static func isAudioSlider(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(audioSliderPrefix) == true
    }
}

@MainActor
enum StandaloneClipProjectBuilder {
    static func build(
        asset: MediaAssetRecord,
        timelineSegments: [SourceSegment]
    ) throws -> TrimatoProject {
        var project = TrimatoProject(name: "\(asset.name) Project")
        project.media.append(asset)
        _ = try project.append(asset: asset, segments: timelineSegments)
        return project
    }
}

final class VideoPlayerViewModel: ObservableObject {
    struct TimelinePoint: Equatable {
        enum Kind: Int, Equatable {
            case start
            case inMarker
            case outMarker
            case end

            var spokenName: String {
                switch self {
                case .start: "Start"
                case .inMarker: "In"
                case .outMarker: "Out"
                case .end: "End"
                }
            }
        }

        let kind: Kind
        let time: CMTime
    }

    let player = AVPlayer()

    @Published var displayTimecode: String = "00:00:00.000"
    @Published var isPlaying: Bool = false
    @Published var playbackRate: Float = 0
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var sourceFilename: String?
    @Published private(set) var hasMedia = false
    @Published private(set) var hasVideo = false
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var isPreparingWaveform = false
    @Published var showingFrames: Bool = false
    @Published var currentFrame: Int = 0
    @Published private(set) var accessibilityTimecodeLabel: String = "0 seconds, 0 milliseconds"
    @Published private(set) var inMarker: CMTime?
    @Published private(set) var outMarker: CMTime?
    @Published private(set) var isExporting = false
    @Published private(set) var exportStatus: String?
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportErrorMessage: String?
    @Published private(set) var mediaOpenErrorMessage: String?
    @Published private(set) var isPresentingExportPanel = false
    @Published private(set) var isLoadingMedia = false
    @Published private(set) var mediaStatus: String?
    @Published private(set) var mediaProgress: Double?
    @Published private(set) var mediaFilename = ""
    @Published private(set) var isApplyingEdit = false
    @Published private(set) var projectSourceSegments: [SourceSegment] = []
    @Published private(set) var placementSourceSegments: [SourceSegment] = []

    private var frameRate: Float = 0
    private var minFrameDuration: CMTime = .invalid  // exact frame duration from track
    private var mediaDuration: CMTime = .zero
    private var mediaSource: MediaSource?
    private var editTimeline: ClipEditTimeline?
    private var basePlaybackAsset: AVAsset?
    private var activeAudioPreviewURL: URL?
    private var filteredPreviewIsAudio: Bool?
    private var editedFrameTimestamps: [CMTime] = []
    private var proxyURL: URL?
    private var timeObserver: Any?
    private var rateObserver: AnyCancellable?
    private var keyEventMonitor: Any?
    private var keyboardCommandsAreActive: (() -> Bool)?
    private var createProjectFromClipAction: (() -> Void)?
    private var isScrubbing = false
    private var scrubTask: Task<Void, Never>?
    private var frameStepPosition: CMTime?
    private var exportTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var frameIndexTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var sourceWaveform: AudioWaveformData?
    private var editTask: Task<Void, Never>?
    private var editID: UUID?
    private var loadID: UUID?
    private var announcedImportProgress = 0
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
        exportTask?.cancel()
        loadTask?.cancel()
        frameIndexTask?.cancel()
        waveformID = UUID()
        waveformTask?.cancel()
        editTask?.cancel()
        editID = nil
        removeActiveAudioPreview()
        ProxyMediaManager.removeProxy(at: proxyURL)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
    }

    // MARK: - Public

    func scopeKeyboardCommands(to isActive: @escaping () -> Bool) {
        keyboardCommandsAreActive = isActive
    }

    func configureCreateProjectFromClipAction(_ action: @escaping () -> Void) {
        createProjectFromClipAction = action
    }

    var inMarkerDisplay: String {
        guard let inMarker else { return "Not set" }
        return Self.formatTimecode(inMarker)
    }

    var playbackFractionStep: Double {
        Self.playbackFractionStep(
            duration: duration,
            frameRate: Double(frameRate)
        )
    }

    nonisolated static func playbackFractionStep(duration: Double, frameRate: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 1 }
        let timeStep = frameRate.isFinite && frameRate > 0 ? 1 / frameRate : 0.1
        return min(max(timeStep / duration, 0.000_001), 1)
    }

    var outMarkerDisplay: String {
        guard let outMarker else { return "Not set" }
        return Self.formatTimecode(outMarker)
    }

    var canExport: Bool {
        guard hasMedia, clipEffectsReady, !isExporting, !isPresentingExportPanel, !isApplyingEdit else { return false }
        if inMarker == nil, outMarker == nil { return true }
        return Self.validExportRange(inMarker: inMarker, outMarker: outMarker) != nil
    }

    var canDeleteSelection: Bool {
        Self.validExportRange(inMarker: inMarker, outMarker: outMarker) != nil &&
            hasMedia && !isExporting && !isApplyingEdit
    }

    var canCreateProjectFromClip: Bool {
        hasMedia && !isLoadingMedia && !isExporting && !isApplyingEdit && !placementSourceSegments.isEmpty
    }

    var audioPreviewSegments: [SourceSegment] {
        projectSourceSegments
    }

    func makeProjectFromCurrentClip() async throws -> TrimatoProject {
        guard canCreateProjectFromClip, let mediaSource else {
            throw StandaloneProjectCreationError.clipNotReady
        }

        let originalURL = mediaSource.originalURL
        let originalAsset = mediaSource.originalAsset
        let duration = try await originalAsset.load(.duration)
        guard duration.isValid, duration.isNumeric, duration > .zero else {
            throw MediaSourceError.unreadable("The selected media does not have a usable duration.")
        }
        let videoTrack = try await originalAsset.loadTracks(withMediaType: .video).first
        let displayedSize: CGSize?
        let sourceFrameRate: Float?
        if let videoTrack {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            displayedSize = naturalSize.applying(transform)
            sourceFrameRate = try await videoTrack.load(.nominalFrameRate)
        } else {
            displayedSize = nil
            sourceFrameRate = nil
        }
        let fingerprint = try MediaCacheManager.sourceFingerprint(for: originalURL)
        let bookmark = try? originalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )

        let playbackMode: ProjectMediaPlaybackMode
        let proxyCacheKey: UUID?
        switch mediaSource.mode {
        case .nativePassthrough:
            playbackMode = .nativePassthrough
            proxyCacheKey = nil
        case .nativePlaybackMP4Export:
            playbackMode = .nativeMP4Export
            proxyCacheKey = nil
        case .proxyPlaybackMP4Export:
            let cacheKey = UUID()
            _ = try await MediaCacheManager.shared.adoptProxy(
                at: mediaSource.playbackURL,
                cacheKey: cacheKey,
                fingerprint: fingerprint
            )
            playbackMode = .cachedProxy
            proxyCacheKey = cacheKey
        }

        let asset = MediaAssetRecord(
            name: originalURL.deletingPathExtension().lastPathComponent,
            originalPath: originalURL.path,
            bookmarkData: bookmark,
            duration: ProjectTime(duration),
            naturalWidth: displayedSize.map { Int(abs($0.width.rounded())) },
            naturalHeight: displayedSize.map { Int(abs($0.height.rounded())) },
            frameRate: sourceFrameRate.flatMap { $0 > 0 ? Double($0) : nil },
            hasAudio: mediaSource.hasAudio,
            sourceEdit: projectSourceSegments,
            playbackMode: playbackMode,
            proxyCacheKey: proxyCacheKey,
            sourceFingerprint: fingerprint
        )
        return try StandaloneClipProjectBuilder.build(
            asset: asset,
            timelineSegments: placementSourceSegments
        )
    }

    var canTrimStart: Bool {
        hasMedia && !isExporting && !isApplyingEdit &&
            CMTimeCompare(effectivePlayheadTime, .zero) > 0
    }

    var canTrimEnd: Bool {
        hasMedia && !isExporting && !isApplyingEdit &&
            CMTimeCompare(effectivePlayheadTime, mediaDuration) < 0
    }

    func openFile() {
        guard NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .data]
        panel.title = "Open Media File"
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func load(
        url: URL,
        sourceSegments: [SourceSegment]? = nil,
        preparedSource: MediaSource? = nil,
        initialInMarker: ProjectTime? = nil,
        initialOutMarker: ProjectTime? = nil
    ) {
        sourceFilename = url.lastPathComponent
        loadID = nil
        loadTask?.cancel()
        frameIndexTask?.cancel()
        frameIndexTask = nil
        waveformID = UUID()
        waveformTask?.cancel()
        waveformTask = nil
        sourceWaveform = nil
        waveformSamples = []
        isPreparingWaveform = false
        editTask?.cancel()
        editTask = nil
        editID = nil
        isApplyingEdit = false
        cancelScrub()
        arrowHolding = false
        jklIndex = 0
        ProxyMediaManager.removeProxy(at: proxyURL)
        proxyURL = nil
        removeActiveAudioPreview()
        basePlaybackAsset = nil
        mediaSource = nil
        editTimeline = nil
        editedFrameTimestamps = []
        projectSourceSegments = []
        placementSourceSegments = []
        mediaDuration = .zero
        inMarker = nil
        outMarker = nil
        exportStatus = nil
        exportProgress = nil
        exportErrorMessage = nil
        mediaOpenErrorMessage = nil
        mediaStatus = "Inspecting \(url.lastPathComponent)"
        mediaFilename = url.lastPathComponent
        mediaProgress = nil
        isLoadingMedia = true
        player.replaceCurrentItem(with: nil)
        hasMedia = false
        hasVideo = false
        displayTimecode = "00:00:00.000"
        currentTime = 0; currentFrame = 0; frameRate = 0; duration = 0
        minFrameDuration = .invalid
        accessibilityTimecodeLabel = "0 seconds, 0 milliseconds"
        announcedImportProgress = 0
        let operationID = UUID()
        loadID = operationID
        loadTask = Task { @MainActor in
            var preparedProxyURL: URL?
            do {
                let source: MediaSource
                if let preparedSource {
                    source = preparedSource
                } else {
                    source = try await self.prepareMediaSource(url: url)
                }
                preparedProxyURL = preparedSource == nil && source.usesProxy ? source.playbackURL : nil
                try Task.checkCancellation()
                guard self.loadID == operationID else {
                    throw CancellationError()
                }
                self.mediaSource = source
                self.hasVideo = source.hasVideo
                self.proxyURL = preparedSource == nil && source.usesProxy ? source.playbackURL : nil
                preparedProxyURL = nil
                if let track = try await source.playbackAsset.loadTracks(withMediaType: .video).first {
                    self.frameRate = try await track.load(.nominalFrameRate)
                    self.minFrameDuration = try await track.load(.minFrameDuration)
                }
                let loadedDuration = try await source.playbackAsset.load(.duration)
                try Task.checkCancellation()
                let requestedRanges = sourceSegments?.map(\.sourceRange.cmTimeRange)
                    .filter { $0.isValid && $0.duration > .zero } ?? []
                let timeline = requestedRanges.isEmpty
                    ? ClipEditTimeline(sourceDuration: loadedDuration)
                    : ClipEditTimeline(sourceRanges: requestedRanges)
                let playbackAsset: AVAsset
                if requestedRanges.isEmpty {
                    playbackAsset = source.playbackAsset
                } else {
                    playbackAsset = try await EditedCompositionBuilder.build(
                        asset: source.playbackAsset,
                        sourceRanges: timeline.sourceRanges
                    )
                }
                self.basePlaybackAsset = playbackAsset
                self.player.replaceCurrentItem(with: AVPlayerItem(asset: playbackAsset))
                self.mediaDuration = timeline.duration
                self.duration = CMTimeGetSeconds(timeline.duration)
                self.editTimeline = timeline
                self.projectSourceSegments = timeline.sourceRanges.map {
                    SourceSegment(sourceRange: ProjectTimeRange($0))
                }
                self.inMarker = initialInMarker?.cmTime
                self.outMarker = initialOutMarker?.cmTime
                self.refreshPlacementSourceSegments()
                self.editedFrameTimestamps = EditedCompositionBuilder.editedFrameTimestamps(
                    sourceTimestamps: source.frameTimestamps,
                    sourceRanges: timeline.sourceRanges
                )
                self.hasMedia = true
                self.isLoadingMedia = false
                self.mediaProgress = nil
                self.mediaStatus = source.usesProxy
                    ? "Ready using a playback proxy"
                    : "Ready"
                self.loadID = nil
                self.loadTask = nil
                if source.hasVideo && source.frameTimestamps.isEmpty {
                    self.indexFramesInBackground(
                        at: source.playbackURL,
                        sourceRanges: timeline.sourceRanges
                    )
                }
                if source.hasAudio && !source.hasVideo {
                    self.prepareWaveform(asset: source.playbackAsset)
                }
            } catch is CancellationError {
                ProxyMediaManager.removeProxy(at: preparedProxyURL)
                guard self.loadID == operationID else { return }
                self.isLoadingMedia = false
                self.mediaProgress = nil
                self.loadID = nil
                self.loadTask = nil
            } catch {
                ProxyMediaManager.removeProxy(at: preparedProxyURL)
                guard self.loadID == operationID else { return }
                self.isLoadingMedia = false
                self.mediaProgress = nil
                self.mediaStatus = "Open failed: \(error.localizedDescription)"
                self.mediaOpenErrorMessage = error.localizedDescription
                self.loadID = nil
                self.loadTask = nil
                self.announce("Open failed. \(error.localizedDescription)")
            }
        }
    }

    func cancelMediaLoad() {
        guard isLoadingMedia || isPreparingWaveform else { return }
        waveformID = UUID()
        waveformTask?.cancel()
        waveformTask = nil
        isPreparingWaveform = false
        loadID = nil
        loadTask?.cancel()
        loadTask = nil
        isLoadingMedia = false
        mediaProgress = nil
        mediaStatus = "Import canceled"
        announce("Import canceled")
    }

    func closeMedia() {
        loadID = nil
        loadTask?.cancel()
        loadTask = nil
        frameIndexTask?.cancel()
        frameIndexTask = nil
        waveformID = UUID()
        waveformTask?.cancel()
        waveformTask = nil
        editTask?.cancel()
        editTask = nil
        editID = nil
        isApplyingEdit = false
        exportTask?.cancel()
        isLoadingMedia = false
        mediaProgress = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        ProxyMediaManager.removeProxy(at: proxyURL)
        proxyURL = nil
        removeActiveAudioPreview()
        basePlaybackAsset = nil
        mediaSource = nil
        editTimeline = nil
        editedFrameTimestamps = []
        projectSourceSegments = []
        placementSourceSegments = []
        sourceWaveform = nil
        waveformSamples = []
        isPreparingWaveform = false
        hasMedia = false
        hasVideo = false
    }

    func applyFilteredPreview(at url: URL, audio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: audio ? .audio : .video).first != nil else {
            throw AudioPreviewPlaybackError.unavailable
        }
        try Task.checkCancellation()
        installFilteredPreview(asset: asset, url: url, audio: audio)
    }

    /// Called synchronously after the coordinator verifies the prepared request is current.
    func installFilteredPreview(asset: AVAsset, url: URL, audio: Bool) {
        filteredPreviewIsAudio = audio
        replacePlaybackAsset(asset, previewURL: url)
    }

    func applyAudioPreview(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw AudioPreviewPlaybackError.unavailable
        }
        replacePlaybackAsset(asset, previewURL: url)
    }

    func restoreUnprocessedAudioPreview() {
        filteredPreviewIsAudio = nil
        guard let basePlaybackAsset else { return }
        replacePlaybackAsset(basePlaybackAsset, previewURL: nil)
    }

    func togglePlayPause() {
        cancelScrub()
        if isPlaying { jklIndex = 0; player.pause() }
        else          { jklIndex = 1; player.rate = 1.0 }
    }

    func stepForward() {
        guard hasMedia, !arrowHolding else { return }
        cancelScrub(preservingFrameStepPosition: true)
        isSteppingFrames = true
        scheduleStepEnd()
        seekOneFrame(forward: true) { [weak self] target in
            self?.scheduleScrubAudio(returningTo: target)
        }
    }

    func stepBackward() {
        guard hasMedia, !arrowHolding else { return }
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
        guard hasVideo else { return }
        showingFrames.toggle()
        accessibilityTimecodeLabel = buildAccessibilityLabel()
    }

    func markIn() {
        guard hasMedia, NSApp.modalWindow == nil else { return }
        let time = effectivePlayheadTime
        setInMarker(at: time)
        announce("In marked at \(spokenTime(time))")
    }

    func markOut() {
        guard hasMedia, NSApp.modalWindow == nil else { return }
        let time = effectivePlayheadTime
        setOutMarker(at: time)
        announce("Out marked at \(spokenTime(time))")
    }

    func setInMarker(at time: CMTime) {
        inMarker = time
        refreshPlacementSourceSegments()
    }

    func setOutMarker(at time: CMTime) {
        outMarker = time
        refreshPlacementSourceSegments()
    }

    func clearIn() {
        guard inMarker != nil else { return }
        inMarker = nil
        refreshPlacementSourceSegments()
        announce("In marker cleared")
    }

    func clearOut() {
        guard outMarker != nil else { return }
        outMarker = nil
        refreshPlacementSourceSegments()
        announce("Out marker cleared")
    }

    func deleteSelection() {
        guard let range = Self.validExportRange(inMarker: inMarker, outMarker: outMarker) else {
            announce("Set an In marker earlier than the Out marker before deleting")
            return
        }
        applyDeletion(
            range,
            targetTime: range.start,
            actionDescription: "Selection deleted"
        )
    }

    func trimStartToPlayhead() {
        let playhead = effectivePlayheadTime
        guard CMTimeCompare(playhead, .zero) > 0 else {
            announce("The playhead is already at the start")
            return
        }
        applyDeletion(
            CMTimeRange(start: .zero, end: playhead),
            targetTime: .zero,
            actionDescription: "Start trimmed to playhead"
        )
    }

    func trimEndFromPlayhead() {
        let playhead = effectivePlayheadTime
        guard CMTimeCompare(playhead, mediaDuration) < 0 else {
            announce("The playhead is already at the end")
            return
        }
        applyDeletion(
            CMTimeRange(start: playhead, end: mediaDuration),
            targetTime: playhead,
            actionDescription: "End trimmed from playhead"
        )
    }

    func goToStart() {
        jump(to: .init(kind: .start, time: .zero))
    }

    func goToEnd() {
        guard mediaDuration.isValid, mediaDuration > .zero else { return }
        jump(to: .init(kind: .end, time: mediaDuration))
    }

    func goToPreviousTimelinePoint() {
        guard let point = Self.timelineDestination(
            from: effectivePlayheadTime,
            movingForward: false,
            duration: mediaDuration,
            inMarker: inMarker,
            outMarker: outMarker
        ) else { return }
        jump(to: point)
    }

    func goToNextTimelinePoint() {
        guard let point = Self.timelineDestination(
            from: effectivePlayheadTime,
            movingForward: true,
            duration: mediaDuration,
            inMarker: inMarker,
            outMarker: outMarker
        ) else { return }
        jump(to: point)
    }

    @Published var clipEffectsReady = true

    func exportTrimmedClip() {
        guard clipEffectsReady else { announce("Wait for a valid clip preview before exporting"); return }
        guard NSApp.modalWindow == nil, !isExporting, !isPresentingExportPanel, !isApplyingEdit else { return }
        guard var mediaSource, let editTimeline else {
            announce("Open a media file before exporting")
            return
        }

        let editedExportRange: CMTimeRange?
        if inMarker == nil, outMarker == nil {
            editedExportRange = nil
        } else if let selection = Self.validExportRange(inMarker: inMarker, outMarker: outMarker) {
            editedExportRange = selection
        } else {
            announce("Set both In and Out, with In earlier than Out, or clear both markers")
            return
        }
        var sourceRanges = editTimeline.sourceRanges(in: editedExportRange)
        if let previewURL = activeAudioPreviewURL {
            let filteredAsset = AVURLAsset(url: previewURL)
            mediaSource = .native(url: previewURL, asset: filteredAsset, contentType: .quickTimeMovie, mode: .nativePlaybackMP4Export, hasVideo: filteredPreviewIsAudio == false, hasAudio: filteredPreviewIsAudio == true)
            sourceRanges = [editedExportRange ?? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))]
        }
        guard !sourceRanges.isEmpty else {
            announce("The selected portion does not contain exportable media")
            return
        }

        var formats = ExportFormat.projectFormats.filter { format in
            (format.isAudioOnly && mediaSource.hasAudio) || (!format.isAudioOnly && mediaSource.hasVideo)
        }
        if mediaSource.mode == .nativePassthrough,
           let sourceContentType = mediaSource.contentType,
           ClipExporter.canPassthrough(asset: mediaSource.originalAsset, sourceContentType: sourceContentType) {
            formats.insert(.original, at: 0)
        }
        let baseName = mediaSource.originalURL.deletingPathExtension().lastPathComponent + "-trimmed"
        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let savePanel = ExportSavePanel(
            title: "Export Clip",
            baseName: baseName,
            formats: formats,
            originalExtension: mediaSource.originalURL.pathExtension,
            originalContentType: mediaSource.contentType
        )
        isPresentingExportPanel = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await savePanel.selection(parentWindow: parentWindow)
            self.isPresentingExportPanel = false
            guard let selection else { return }
            self.startClipExport(
                mediaSource: mediaSource,
                sourceRanges: sourceRanges,
                format: selection.format,
                outputURL: selection.url
            )
        }
    }

    private func startClipExport(
        mediaSource: MediaSource,
        sourceRanges: [CMTimeRange],
        format: ExportFormat,
        outputURL: URL
    ) {
        isExporting = true
        exportStatus = "Exporting clip"
        exportProgress = format == .original ? nil : 0
        exportErrorMessage = nil
        announce("Export started")
        exportTask = Task { @MainActor in
            do {
                switch mediaSource.mode {
                case .nativePassthrough:
                    try await ClipExporter.export(
                        asset: mediaSource.originalAsset,
                        sourceRanges: sourceRanges,
                        sourceContentType: mediaSource.contentType,
                        format: format,
                        to: outputURL
                    ) { [weak self] progress in
                        self?.exportProgress = progress
                    }
                case .nativePlaybackMP4Export, .proxyPlaybackMP4Export:
                    try await FFmpegClipExporter.export(
                        sourceURL: mediaSource.originalURL,
                        sourceRanges: sourceRanges,
                        hasAudio: mediaSource.hasAudio,
                        format: format,
                        to: outputURL
                    ) { [weak self] progress in
                        self?.exportProgress = progress
                    }
                }
                self.isExporting = false
                self.exportProgress = nil
                self.exportTask = nil
                self.exportStatus = "Export complete: \(outputURL.lastPathComponent)"
                ExportNotificationCenter.postExportCompleted(filename: outputURL.lastPathComponent)
                self.announce("Export complete")
            } catch is CancellationError {
                self.isExporting = false
                self.exportProgress = nil
                self.exportTask = nil
                self.exportStatus = "Export canceled"
                self.announce("Export canceled")
            } catch {
                self.isExporting = false
                self.exportProgress = nil
                self.exportTask = nil
                if Task.isCancelled {
                    self.exportStatus = "Export canceled"
                    self.announce("Export canceled")
                } else {
                    let message = ProjectExporter.userFacingMessage(for: error)
                    self.exportStatus = "Export failed"
                    self.exportErrorMessage = message
                    self.announce("Clip could not be exported. \(message)")
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportTask?.cancel()
        exportStatus = "Canceling export"
        announce("Canceling export")
    }

    func dismissExportError() {
        exportErrorMessage = nil
    }

    func reportMediaOpenFailure(_ error: Error) {
        isLoadingMedia = false
        mediaProgress = nil
        mediaStatus = "Open failed: \(error.localizedDescription)"
        mediaOpenErrorMessage = error.localizedDescription
        announce("Open failed. \(error.localizedDescription)")
    }

    func dismissMediaOpenError() {
        mediaOpenErrorMessage = nil
    }

    static func validExportRange(inMarker: CMTime?, outMarker: CMTime?) -> CMTimeRange? {
        guard let inMarker, let outMarker,
              inMarker.isValid, outMarker.isValid,
              CMTimeCompare(inMarker, outMarker) < 0 else { return nil }
        return CMTimeRange(start: inMarker, end: outMarker)
    }

    static func trimmedFilename(for sourceURL: URL) -> String {
        trimmedFilename(for: sourceURL, convertingToMP4: false)
    }

    static func trimmedFilename(for sourceURL: URL, convertingToMP4: Bool) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = convertingToMP4 ? "mp4" : sourceURL.pathExtension
        return fileExtension.isEmpty
            ? "\(baseName)-trimmed"
            : "\(baseName)-trimmed.\(fileExtension)"
    }

    static func orderedTimelinePoints(
        duration: CMTime,
        inMarker: CMTime?,
        outMarker: CMTime?
    ) -> [TimelinePoint] {
        guard duration.isValid, CMTimeCompare(duration, .zero) > 0 else { return [] }
        var points = [TimelinePoint(kind: .start, time: .zero)]
        if let inMarker, inMarker.isValid {
            points.append(.init(kind: .inMarker, time: inMarker))
        }
        if let outMarker, outMarker.isValid {
            points.append(.init(kind: .outMarker, time: outMarker))
        }
        points.append(.init(kind: .end, time: duration))
        points.sort {
            let comparison = CMTimeCompare($0.time, $1.time)
            return comparison == 0 ? $0.kind.rawValue < $1.kind.rawValue : comparison < 0
        }

        return points.reduce(into: []) { result, point in
            guard result.last.map({ CMTimeCompare($0.time, point.time) == 0 }) != true else { return }
            result.append(point)
        }
    }

    static func timelineDestination(
        from currentTime: CMTime,
        movingForward: Bool,
        duration: CMTime,
        inMarker: CMTime?,
        outMarker: CMTime?
    ) -> TimelinePoint? {
        let points = orderedTimelinePoints(
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker
        )
        if movingForward {
            return points.first { CMTimeCompare($0.time, currentTime) > 0 }
        }
        return points.last { CMTimeCompare($0.time, currentTime) < 0 }
    }

    // MARK: - JKL

    func pressJ() {
        cancelScrub()
        jklIndex = jklIndex > 0 ? -1 : max(jklIndex - 1, -jklSpeeds.count)
        applyJKLRate()
    }

    func pressK() {
        togglePlayPause()
    }

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
        if !editedFrameTimestamps.isEmpty {
            let timestamps = editedFrameTimestamps
            let current = frameStepPosition ?? player.currentTime()
            let target: CMTime
            if forward {
                target = timestamps.first { CMTimeCompare($0, current) > 0 } ?? mediaDuration
            } else {
                target = timestamps.last { CMTimeCompare($0, current) < 0 } ?? .zero
            }
            frameStepPosition = target
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                guard finished else { return }
                completion(target)
            }
            return
        }

        let frameDur: CMTime
        if minFrameDuration.isValid, minFrameDuration.value > 0 {
            frameDur = minFrameDuration
        } else if frameRate > 0 {
            frameDur = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        } else {
            frameDur = CMTime(value: 1, timescale: 30)
        }

        let current = frameStepPosition ?? player.currentTime()
        let unclampedTarget: CMTime = forward
            ? CMTimeAdd(current, frameDur)
            : CMTimeSubtract(current, frameDur)
        let nonnegativeTarget = CMTimeMaximum(unclampedTarget, .zero)
        let target = mediaDuration.isValid && mediaDuration > .zero
            ? CMTimeMinimum(nonnegativeTarget, mediaDuration)
            : nonnegativeTarget
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

    private func replacePlaybackAsset(_ asset: AVAsset, previewURL: URL?) {
        let position = player.currentTime()
        let rate = player.rate
        let previousPreviewURL = activeAudioPreviewURL
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        activeAudioPreviewURL = previewURL
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, rate != 0 else { return }
            self?.player.rate = rate
        }
        if previousPreviewURL != previewURL, let previousPreviewURL {
            try? FileManager.default.removeItem(at: previousPreviewURL)
        }
    }

    private func removeActiveAudioPreview() {
        if let activeAudioPreviewURL {
            try? FileManager.default.removeItem(at: activeAudioPreviewURL)
        }
        activeAudioPreviewURL = nil
    }

    private func applyDeletion(
        _ range: CMTimeRange,
        targetTime: CMTime,
        actionDescription: String
    ) {
        guard hasMedia, !isExporting, !isApplyingEdit,
              let mediaSource, var updatedTimeline = editTimeline else { return }
        do {
            try updatedTimeline.delete(editedRange: range)
        } catch {
            announce(error.localizedDescription)
            return
        }

        player.pause()
        cancelScrub()
        isApplyingEdit = true
        announce("Applying edit")
        let operationID = UUID()
        editID = operationID
        editTask = Task { @MainActor in
            do {
                let composition = try await EditedCompositionBuilder.build(
                    asset: mediaSource.playbackAsset,
                    sourceRanges: updatedTimeline.sourceRanges
                )
                try Task.checkCancellation()
                guard self.editID == operationID else { return }

                self.editTimeline = updatedTimeline
                self.projectSourceSegments = updatedTimeline.sourceRanges.map {
                    SourceSegment(sourceRange: ProjectTimeRange($0))
                }
                self.editedFrameTimestamps = EditedCompositionBuilder.editedFrameTimestamps(
                    sourceTimestamps: mediaSource.frameTimestamps,
                    sourceRanges: updatedTimeline.sourceRanges
                )
                self.mediaDuration = updatedTimeline.duration
                self.duration = CMTimeGetSeconds(updatedTimeline.duration)
                self.inMarker = nil
                self.outMarker = nil
                self.refreshPlacementSourceSegments()
                self.refreshWaveformSamples()
                self.removeActiveAudioPreview()
                self.basePlaybackAsset = composition
                self.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                let destination = CMTimeMinimum(targetTime, updatedTimeline.duration)
                await self.player.seek(to: destination, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = max(CMTimeGetSeconds(destination), 0)
                if self.frameRate > 0 {
                    self.currentFrame = Int(self.currentTime * Double(self.frameRate))
                }
                self.displayTimecode = Self.formatTimecode(destination)
                self.accessibilityTimecodeLabel = self.buildAccessibilityLabel()
                self.isApplyingEdit = false
                self.editID = nil
                self.editTask = nil
                self.announce(actionDescription)
            } catch is CancellationError {
                guard self.editID == operationID else { return }
                self.isApplyingEdit = false
                self.editID = nil
                self.editTask = nil
            } catch {
                guard self.editID == operationID else { return }
                self.isApplyingEdit = false
                self.editID = nil
                self.editTask = nil
                self.announce("Edit failed. \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: markers and navigation

    private var effectivePlayheadTime: CMTime {
        frameStepPosition ?? player.currentTime()
    }

    private func jump(to point: TimelinePoint) {
        guard hasMedia else { return }
        cancelScrub()
        player.seek(to: point.time, toleranceBefore: .zero, toleranceAfter: .zero)
        announce("\(point.kind.spokenName), \(spokenTime(point.time))")
    }

    private func spokenTime(_ time: CMTime) -> String {
        let parts = Self.formatTimecode(time).split(separator: ":")
        guard parts.count == 3 else { return Self.formatTimecode(time) }
        let h = Int(parts[0]) ?? 0
        let m = Int(parts[1]) ?? 0
        let secMs = parts[2].split(separator: ".")
        let s = Int(secMs.first ?? "0") ?? 0
        let ms = Int(secMs.last ?? "0") ?? 0
        var components: [String] = []
        if h > 0 { components.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { components.append("\(m) minute\(m == 1 ? "" : "s")") }
        components.append("\(s) second\(s == 1 ? "" : "s")")
        components.append("\(ms) millisecond\(ms == 1 ? "" : "s")")
        return components.joined(separator: ", ")
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

    private func indexFramesInBackground(at url: URL, sourceRanges: [CMTimeRange]) {
        frameIndexTask?.cancel()
        frameIndexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let timestamps = (try? await FFmpegMediaProbe.frameTimestamps(url: url)) ?? []
            guard !Task.isCancelled, self.mediaSource?.playbackURL == url else { return }
            self.editedFrameTimestamps = EditedCompositionBuilder.editedFrameTimestamps(
                sourceTimestamps: timestamps,
                sourceRanges: sourceRanges
            )
            self.frameIndexTask = nil
        }
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
            guard let self, !self.isLoadingMedia, !self.isExporting, !self.isApplyingEdit,
                  self.hasMedia, NSApp.modalWindow == nil,
                  event.window?.sheetParent == nil, event.window?.attachedSheet == nil,
                  self.keyboardCommandsAreActive?() != false else {
                return event
            }

            if let editor = event.window?.firstResponder as? NSTextView, editor.isEditable { return event }
            let commandSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let commandModifiers = event.modifierFlags.intersection(commandSet)
            let unmodified = event.modifierFlags.intersection([.command, .control, .option]).isEmpty

            switch event.type {
            case .keyDown:
                if commandModifiers == .command {
                    if event.charactersIgnoringModifiers == "[" {
                        if !event.isARepeat { self.trimStartToPlayhead() }
                        return nil
                    }
                    if event.charactersIgnoringModifiers == "]" {
                        if !event.isARepeat { self.trimEndFromPlayhead() }
                        return nil
                    }
                    if event.charactersIgnoringModifiers?.lowercased() == "e" {
                        if !event.isARepeat {
                            DispatchQueue.main.async { [weak self] in
                                self?.exportTrimmedClip()
                            }
                        }
                        return nil
                    }
                    if event.charactersIgnoringModifiers?.lowercased() == "r",
                       let createProjectFromClipAction = self.createProjectFromClipAction {
                        if !event.isARepeat {
                            DispatchQueue.main.async {
                                createProjectFromClipAction()
                            }
                        }
                        return nil
                    }
                    switch event.keyCode {
                    case 123: // Command+Left arrow
                        if !event.isARepeat { self.goToPreviousTimelinePoint() }
                        return nil
                    case 124: // Command+Right arrow
                        if !event.isARepeat { self.goToNextTimelinePoint() }
                        return nil
                    case 126: // Command+Up arrow
                        if !event.isARepeat { self.goToStart() }
                        return nil
                    case 125: // Command+Down arrow
                        if !event.isARepeat { self.goToEnd() }
                        return nil
                    default:
                        break
                    }
                }

                switch event.keyCode {
                case 51, 117: // Delete and Forward Delete
                    guard unmodified else { return event }
                    if !event.isARepeat { self.deleteSelection() }
                    return nil
                case 49: // Space — toggle, ignore repeat
                    guard unmodified else { return event }
                    guard !ClipEditorKeyboardRouting.focusedControlReservesSpace(in: event.window) else {
                        return event
                    }
                    if !event.isARepeat { self.togglePlayPause() }
                    return nil
                case 123: // Left arrow
                    guard unmodified else { return event }
                    guard !ClipEditorKeyboardRouting.focusedControlReservesArrowKeys() else { return event }
                    if event.isARepeat { self.arrowHeld(forward: false) }
                    else               { self.stepBackward() }
                    return nil
                case 124: // Right arrow
                    guard unmodified else { return event }
                    guard !ClipEditorKeyboardRouting.focusedControlReservesArrowKeys() else { return event }
                    if event.isARepeat { self.arrowHeld(forward: true) }
                    else               { self.stepForward() }
                    return nil
                default: break
                }
                // Letter shortcuts — ignore key repeat.
                if !event.isARepeat, unmodified {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "i": self.markIn(); return nil
                    case "o": self.markOut(); return nil
                    case "j": self.pressJ(); return nil
                    case "k": self.pressK(); return nil
                    case "l": self.pressL(); return nil
                    default: return event
                    }
                }
                return event

            case .keyUp:
                switch event.keyCode {
                case 123, 124:
                    guard !ClipEditorKeyboardRouting.focusedControlReservesArrowKeys() else { return event }
                    self.arrowKeyUp()
                    return nil
                default: return event
                }

            default:
                return event
            }
        }
    }

    private func refreshPlacementSourceSegments() {
        guard let editTimeline else {
            placementSourceSegments = []
            return
        }
        let selectedRanges: [CMTimeRange]
        if inMarker == nil, outMarker == nil {
            selectedRanges = editTimeline.sourceRanges
        } else if let range = Self.validExportRange(inMarker: inMarker, outMarker: outMarker) {
            selectedRanges = editTimeline.sourceRanges(in: range)
        } else {
            selectedRanges = []
        }
        placementSourceSegments = selectedRanges.map {
            SourceSegment(sourceRange: ProjectTimeRange($0))
        }
    }

    private var waveformID = UUID()

    private func prepareWaveform(asset: AVAsset) {
        let requestID = UUID()
        waveformID = requestID
        waveformTask?.cancel()
        sourceWaveform = nil
        waveformSamples = []
        isPreparingWaveform = true
        waveformTask = Task { @MainActor [weak self] in
            do {
                let waveform = try await AudioWaveformAnalyzer.analyze(asset: asset)
                try Task.checkCancellation()
                guard let self, self.waveformID == requestID else { return }
                self.sourceWaveform = waveform
                self.refreshWaveformSamples()
                self.isPreparingWaveform = false
                self.waveformTask = nil
            } catch is CancellationError {
                guard self?.waveformID == requestID else { return }
                self?.isPreparingWaveform = false
                self?.waveformTask = nil
            } catch {
                guard self?.waveformID == requestID else { return }
                self?.waveformSamples = []
                self?.isPreparingWaveform = false
                self?.waveformTask = nil
            }
        }
    }

    private func refreshWaveformSamples() {
        guard let sourceWaveform, let editTimeline else {
            waveformSamples = []
            return
        }
        waveformSamples = sourceWaveform.samples(for: editTimeline.sourceRanges)
    }

    // MARK: - Private: media preparation

    private func prepareMediaSource(url: URL) async throws -> MediaSource {
        let asset = AVURLAsset(url: url)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        let isProtected = (try? await asset.load(.hasProtectedContent)) ?? false
        if isProtected { throw MediaSourceError.protectedContent }
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let hasNativeVideo = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
        let hasNativeAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        let nativeDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)

        if isPlayable, let contentType,
           ClipExporter.canPassthrough(asset: asset, sourceContentType: contentType) {
            let timestamps: [CMTime]
            if hasNativeVideo {
                beginFrameIndexing()
                timestamps = (try? await FFmpegMediaProbe.frameTimestamps(
                    url: url,
                    duration: nativeDuration,
                    progress: { [weak self] progress in
                        self?.updateFrameIndexProgress(progress)
                    }
                )) ?? []
            } else {
                timestamps = []
            }
            return .native(
                url: url,
                asset: asset,
                contentType: contentType,
                mode: .nativePassthrough,
                frameTimestamps: timestamps,
                hasVideo: hasNativeVideo,
                hasAudio: hasNativeAudio
            )
        }

        if isPlayable, !hasNativeVideo, hasNativeAudio {
            return .native(
                url: url,
                asset: asset,
                contentType: contentType,
                mode: .nativePlaybackMP4Export,
                hasVideo: false,
                hasAudio: true
            )
        }

        updateImportStatus("Analyzing media compatibility")
        let report = try await FFmpegMediaProbe.inspect(url: url)
        try FFmpegMediaProbe.validateForMP4Conversion(report)
        let timestamps: [CMTime]
        if report.videoStream != nil {
            beginFrameIndexing()
            timestamps = try await FFmpegMediaProbe.frameTimestamps(
                url: url,
                duration: report.duration,
                progress: { [weak self] progress in
                    self?.updateFrameIndexProgress(progress)
                }
            )
        } else {
            timestamps = []
        }

        if isPlayable {
            return .native(
                url: url,
                asset: asset,
                contentType: contentType,
                mode: .nativePlaybackMP4Export,
                frameTimestamps: timestamps,
                hasVideo: report.videoStream != nil,
                hasAudio: report.hasAudio
            )
        }

        updateImportStatus("Creating playback proxy")
        announcedImportProgress = 0
        mediaProgress = 0
        let generatedProxy = try await ProxyMediaManager.createProxy(
            sourceURL: url,
            duration: report.duration,
            hasVideo: report.videoStream != nil
        ) { [weak self] progress in
            self?.updateImportProgress(progress)
        }
        do {
            try Task.checkCancellation()
            let proxyAsset = AVURLAsset(url: generatedProxy)
            return MediaSource(
                originalURL: url,
                playbackURL: generatedProxy,
                originalAsset: asset,
                playbackAsset: proxyAsset,
            contentType: contentType,
                mode: .proxyPlaybackMP4Export,
                frameTimestamps: timestamps,
                hasVideo: report.videoStream != nil,
                hasAudio: report.hasAudio
            )
        } catch {
            ProxyMediaManager.removeProxy(at: generatedProxy)
            throw error
        }
    }

    private func updateImportStatus(_ status: String) {
        mediaStatus = status
        announce(status)
    }

    private func beginFrameIndexing() {
        announcedImportProgress = 0
        mediaProgress = 0
        updateImportStatus("Indexing frames")
    }

    private func updateFrameIndexProgress(_ progress: Double) {
        mediaProgress = progress
    }

    private func updateImportProgress(_ progress: Double) {
        mediaProgress = progress
    }

    static func importProgressMilestone(for progress: Double) -> Int {
        let clamped = min(max(progress, 0), 1)
        return Int(clamped * 100) / 25 * 25
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
