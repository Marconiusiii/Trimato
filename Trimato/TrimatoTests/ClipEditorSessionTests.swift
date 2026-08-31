import AppKit
import SwiftUI
import CoreMedia
import Testing
@testable import Trimato

@Suite("Clip editor sessions", .serialized)
struct ClipEditorSessionTests {
    @Test func entryFocusWaitsForLoadingAndSheetsAndDoesNotRepeatDuringEditing() {
        var focus = ClipEditorEntryFocusPolicy()
        let loading = focus.consume(ready: false, isKeyWindow: true, hasSheet: false)
        #expect(!loading)
        let sheet = focus.consume(ready: true, isKeyWindow: false, hasSheet: true)
        #expect(!sheet)
        let entry = focus.consume(ready: true, isKeyWindow: true, hasSheet: false)
        #expect(entry)
        let editing = focus.consume(ready: true, isKeyWindow: true, hasSheet: false)
        #expect(!editing)
        let inactive = focus.consume(ready: true, isKeyWindow: false, hasSheet: false)
        #expect(!inactive)
        let laterDialog = focus.consume(ready: true, isKeyWindow: true, hasSheet: false)
        #expect(!laterDialog)
        let reentry = focus.consume(ready: true, isKeyWindow: true, hasSheet: false)
        #expect(!reentry)
        let rebuilding = focus.consume(ready: false, isKeyWindow: true, hasSheet: false)
        #expect(!rebuilding)
        let rebuilt = focus.consume(ready: true, isKeyWindow: true, hasSheet: false)
        #expect(!rebuilt)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIMATO_INTERACTION_TESTS"] == "1",
                   "Requires an unlocked macOS session with VoiceOver; set TRIMATO_INTERACTION_TESTS=1."),
          arguments: [true, false], ["source", "timeline", "editor"])
    @MainActor func nativeClipCommandsPreserveFocusThroughPreviewRebuilds(hasVideo: Bool, origin: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent(hasVideo ? "clip.mov" : "clip.m4a")
        var arguments = ["-hide_banner", "-nostdin", "-y"]
        if hasVideo { arguments += ["-f", "lavfi", "-i", "color=c=red:size=320x180:rate=24"] }
        arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1"]
        if hasVideo { arguments += ["-c:v", "mpeg4"] }
        arguments += ["-c:a", "aac", mediaURL.path]
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments)

        var project = TrimatoProject()
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 24)
        let source = MediaAssetRecord(name: "Focus regression", originalPath: mediaURL.path,
                                     duration: ProjectTime(seconds: 1), naturalWidth: hasVideo ? 320 : nil,
                                     naturalHeight: hasVideo ? 180 : nil, frameRate: hasVideo ? 24 : nil,
                                     hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                                        start: .zero, duration: ProjectTime(seconds: 1)))])
        project.media = [source]
        let clipID = try project.append(asset: source)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let editors = ClipEditorWindowCoordinator(controller: controller)
        let projectPreview = ProjectPlayerViewModel()
        let projectWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        projectWindow.isReleasedWhenClosed = false
        projectWindow.contentViewController = NSHostingController(rootView: ClipSessionProjectViewer(
            controller: controller, preview: projectPreview, openClipEditor: editors.open))
        defer { projectWindow.close() }
        projectWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        for _ in 0..<100 {
            if projectWindow.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Do not bypass macOS shielding or count an inactive-window test as interaction proof.
        try #require(projectWindow.isKeyWindow, "macOS did not allow the test window to become key.")
        try #require(NSWorkspace.shared.isVoiceOverEnabled, "VoiceOver must be running for this interaction test.")
        let selection: EditorSelection
        switch origin {
        case "source": selection = .asset(source.id)
        case "timeline": selection = .timelineClip(clipID)
        default: selection = try #require(controller.editorClipSelection(at: .zero))
        }
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        defer {
            for window in NSApp.windows where !existingWindows.contains(window.windowNumber) { window.close() }
        }
        editors.open(selection)
        let router = ClipEditorCommandRouter.shared
        for _ in 0..<1000 {
            if router.activeContext?.canPlace == true,
               focusedAccessibilityIdentifier() == ClipEditorAccessibilityIdentifier.playhead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try #require(router.activeContext)
        let editorWindow = try #require(context.hostWindow)
        try #require(context.editSelection == selection && context.canPlace)
        try #require(focusedAccessibilityIdentifier() == ClipEditorAccessibilityIdentifier.playhead)
        let responder = try #require(editorWindow.firstResponder)

        func checkFocus() throws {
            try #require(editorWindow.isKeyWindow)
            try #require(editorWindow.firstResponder === responder)
            try #require(focusedAccessibilityIdentifier() == ClipEditorAccessibilityIdentifier.playhead)
            try #require(projectWindow.attachedSheet == nil && editorWindow.attachedSheet == nil)
            try #require(router.activeContext === context && context.canPlace)
        }
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: editorWindow.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        // Exercise native shuttling and markers before repeating native menu placements.
        try key("l", code: 37)
        try key("k", code: 40)
        try key("j", code: 38)
        try key("k", code: 40)
        try key("", code: 126, modifiers: .command)
        try await Task.sleep(for: .milliseconds(50))
        try key("i", code: 34)
        try key("", code: 125, modifiers: .command)
        try await Task.sleep(for: .milliseconds(50))
        try key("o", code: 31)
        try checkFocus()

        for (characters, code) in [("e", UInt16(14)), ("w", UInt16(13)), ("e", UInt16(14)), ("w", UInt16(13))] {
            let before = controller.project.tracks.flatMap(\.clips).count
            try key(characters, code: code)
            try #require(controller.project.tracks.flatMap(\.clips).count > before)
            // Sample throughout the rebuild, including SwiftUI's delayed updates.
            for tick in 0..<500 {
                try checkFocus()
                if tick >= 10 && !projectPreview.isPreparing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!projectPreview.isPreparing && projectPreview.errorMessage == nil)
        }
        projectPreview.prepare(project: controller.project, mediaURLs: [:])
        for _ in 0..<500 {
            try checkFocus()
            if !projectPreview.isPreparing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!projectPreview.isPreparing && projectPreview.errorMessage != nil)
        #expect(projectPreview.presentedPreviewFailure == nil)
        try checkFocus()
    }

    @MainActor private func focusedAccessibilityIdentifier() -> String? {
        guard let element = NSApp.accessibilityFocusedUIElement as? NSObject,
              element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    @Test @MainActor func clipMenuCommandsUseOnlyTheCurrentEditorAndRecoverAfterPreparation() throws {
        func makeContext() -> ClipPlacementCommandContext {
            var project = TrimatoProject()
            let source = MediaAssetRecord(name: "Imported", originalPath: "/tmp/imported.mov",
                duration: ProjectTime(seconds: 5), naturalWidth: 640, naturalHeight: 480, frameRate: 30,
                hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                    start: .zero, duration: ProjectTime(seconds: 5)))])
            project.media = [source]
            let controller = ProjectController(document: ProjectDocument(project: project))
            return ClipPlacementCommandContext(controller: controller, editSelection: .asset(source.id),
                                                segments: source.sourceEdit)
        }
        let router = ClipEditorCommandRouter()
        let first = makeContext()
        let second = makeContext()
        first.setKeyWindow(true)
        router.activate(first)
        router.perform(.append)
        #expect(first.controller.project.primaryTimeline.count == 1)
        first.setKeyWindow(false)
        second.setKeyWindow(true)
        router.activate(second)
        router.deactivate(first)
        second.effectsReady = false
        #expect(!router.isAvailable(.append))
        router.perform(.append)
        #expect(second.controller.project.primaryTimeline.isEmpty)
        second.effectsReady = true
        #expect(router.isAvailable(.append))
        router.perform(.append)
        #expect(second.controller.project.primaryTimeline.count == 1)
        #expect(first.controller.project.primaryTimeline.count == 1)
        for (command, action) in [(ClipEditorPlacementCommand.appendToTrack, PlacementAction.append),
                                  (.insertToTrack, .insert), (.overwriteOnTrack, .replaceRemainder)] {
            router.perform(command)
            #expect(second.trackPlacementAction == action)
            second.dismissTrackPlacement()
        }
        second.setKeyWindow(false)
        router.deactivate(second)
        #expect(ClipEditorPlacementCommand.allCases.allSatisfy { !router.isAvailable($0) })
    }

    @Test(arguments: [ClipEditorPlacementCommand.insert, .overwrite, .insertOnTopWithAudio, .insertOnTopOverAudio])
    @MainActor func clipMenuPlacementCommandsDispatchTheirActions(command: ClipEditorPlacementCommand) throws {
        var project = TrimatoProject()
        let source = MediaAssetRecord(name: "Imported", originalPath: "/tmp/imported.mov",
            duration: ProjectTime(seconds: 5), naturalWidth: 640, naturalHeight: 480, frameRate: 30,
            hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero, duration: ProjectTime(seconds: 5)))])
        project.media = [source]
        _ = try project.append(asset: source)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .asset(source.id),
                                                 segments: [SourceSegment(sourceRange: ProjectTimeRange(
                                                    start: .zero, duration: ProjectTime(seconds: 1)))])
        let router = ClipEditorCommandRouter()
        context.setKeyWindow(true)
        router.activate(context)
        let before = controller.project
        router.perform(command)
        #expect(context.presentedError == nil)
        #expect(controller.project != before)
    }

    @Test func newTrackCommandsMatchTheSourceMediaStreams() {
        #expect(NewTrackSourceKind.availableKinds(hasVideo: true, hasAudio: true) == [.video, .audio])
        #expect(NewTrackSourceKind.availableKinds(hasVideo: true, hasAudio: false) == [.video])
        #expect(NewTrackSourceKind.availableKinds(hasVideo: false, hasAudio: true) == [.audio])
        #expect(NewTrackSourceKind.availableKinds(hasVideo: false, hasAudio: false).isEmpty)
        #expect(NewTrackSourceKind.audio.suggestedTrackName(
            sourceName: "Interview",
            sourceHasVideo: true
        ) == "Interview Audio")
    }

    @Test func spaceRemainsAvailableToNativeClipEditorControls() {
        #expect(ClipEditorKeyboardRouting.reservesSpace(
            isEditableText: false,
            accessibilityActions: ["AXPress"]
        ))
        #expect(ClipEditorKeyboardRouting.reservesSpace(
            isEditableText: true,
            accessibilityActions: []
        ))
        #expect(!ClipEditorKeyboardRouting.reservesSpace(
            isEditableText: false,
            accessibilityActions: ["AXIncrement", "AXDecrement"]
        ))
    }

    @Test func arrowKeysAdjustOnlyTheAudioFilterSliders() {
        let adjustableActions = ["AXIncrement", "AXDecrement"]
        #expect(ClipEditorKeyboardRouting.reservesArrowKeys(
            accessibilityIdentifier: ClipEditorAccessibilityIdentifier.audioSlider("gain"),
            accessibilityActions: adjustableActions
        ))
        #expect(!ClipEditorKeyboardRouting.reservesArrowKeys(
            accessibilityIdentifier: ClipEditorAccessibilityIdentifier.playhead,
            accessibilityActions: adjustableActions
        ))
        #expect(!ClipEditorKeyboardRouting.reservesArrowKeys(
            accessibilityIdentifier: ClipEditorAccessibilityIdentifier.audioSlider("gain"),
            accessibilityActions: ["AXPress"]
        ))
    }

    @Test func clipPlayheadUsesFrameOrAudioTimeSteps() {
        #expect(VideoPlayerViewModel.playbackFractionStep(duration: 10, frameRate: 25) == 0.004)
        #expect(VideoPlayerViewModel.playbackFractionStep(duration: 10, frameRate: 0) == 0.01)
        #expect(VideoPlayerViewModel.playbackFractionStep(duration: 0, frameRate: 25) == 1)
    }

    @Test func audioFilterSlidersUsePlainBoundedDecibelControls() {
        #expect(AudioClipControlSpecification.gainRange == -60...12)
        #expect(AudioClipControlSpecification.equalizerRange == -12...12)
        #expect(AudioClipControlSpecification.decibelStep == 1)
        #expect(AudioClipControlSpecification.visibleDecibels(-1) == "-1 dB")
        #expect(AudioClipControlSpecification.spokenDecibels(1) == "1 decibel")
        #expect(AudioClipControlSpecification.spokenDecibels(-2) == "-2 decibels")
    }

    @Test func editorNamesDistinguishAudioFromVideo() {
        #expect(ClipEditorMediaKind.name(hasVideo: false) == "Audio Clip Editor")
        #expect(ClipEditorMediaKind.name(hasVideo: true) == "Video Clip Editor")
    }

    @Test func neutralAudioSettingsRestoreTheOriginalPreview() {
        #expect(!AudioClipPreviewPlan.requiresRender(for: nil))
        #expect(!AudioClipPreviewPlan.requiresRender(for: .neutral))
        #expect(AudioClipPreviewPlan.requiresRender(for: AudioClipSettings(gainDecibels: 3)))
    }

    @Test @MainActor func sourceAudioFiltersAreCarriedIntoThePlacedTimelineClip() throws {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: .zero,
            duration: ProjectTime(seconds: 4)
        ))
        let asset = MediaAssetRecord(
            name: "Music",
            originalPath: "/tmp/music.wav",
            bookmarkData: nil,
            duration: ProjectTime(seconds: 4),
            naturalWidth: nil,
            naturalHeight: nil,
            frameRate: nil,
            hasAudio: true,
            sourceEdit: [segment]
        )
        var project = TrimatoProject()
        project.media = [asset]
        let trackID = project.createTrack(kind: .audio, name: "Music")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(
            controller: controller,
            editSelection: .asset(asset.id),
            segments: [segment]
        )
        context.audioSettings = AudioClipSettings(gainDecibels: 3)

        let clipID = try #require(context.place(.append, onTrack: trackID))

        #expect(controller.project.timelineClip(id: clipID)?.audioSettings.gainDecibels == 3)
    }

    @Test @MainActor func videoSourceCanPlaceOnlyItsAudioOnAnAudioTrack() throws {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))
        let asset = MediaAssetRecord(
            name: "Interview",
            originalPath: "/tmp/interview.mov",
            bookmarkData: nil,
            duration: ProjectTime(seconds: 8),
            naturalWidth: 1_920,
            naturalHeight: 1_080,
            frameRate: 30,
            hasAudio: true,
            sourceEdit: [segment]
        )
        var project = TrimatoProject()
        project.media = [asset]
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(
            controller: controller,
            editSelection: .asset(asset.id),
            segments: [segment]
        )

        let clipID = try #require(context.createTrackAndPlace(
            .append,
            kind: .audio,
            name: "Interview Audio"
        ))

        let track = try #require(controller.project.tracks.first { track in
            track.clips.contains { $0.id == clipID }
        })
        let clip = try #require(controller.project.timelineClip(id: clipID))
        #expect(track.kind == .audio)
        #expect(clip.displayName == "Interview Audio")
        #expect(clip.segments == [segment])
        #expect(controller.project.format.width == nil)
        #expect(controller.project.format.height == nil)
    }

    @Test @MainActor func creatingANamedTrackAndAppendingIsOneAtomicProjectChange() throws {
        let originalSegment = SourceSegment(sourceRange: ProjectTimeRange(
            start: .zero,
            duration: ProjectTime(seconds: 4)
        ))
        let trimmedSegment = SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 0.5),
            duration: ProjectTime(seconds: 2.5)
        ))
        let asset = MediaAssetRecord(
            name: "Music",
            originalPath: "/tmp/music.m4a",
            bookmarkData: nil,
            duration: ProjectTime(seconds: 4),
            naturalWidth: nil,
            naturalHeight: nil,
            frameRate: nil,
            hasAudio: true,
            sourceEdit: [originalSegment]
        )
        var project = TrimatoProject()
        project.media = [asset]
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(
            controller: controller,
            editSelection: .asset(asset.id),
            segments: [trimmedSegment]
        )
        context.audioSettings = AudioClipSettings(gainDecibels: -9)
        let initialRevision = controller.timelineContentRevision

        let clipID = try #require(context.createTrackAndPlace(
            .append,
            kind: .audio,
            name: "Music Bed"
        ))

        let track = try #require(controller.project.tracks.first { $0.name == "Music Bed" })
        #expect(track.kind == .audio)
        #expect(track.clips.map(\.id) == [clipID])
        #expect(track.clips.first?.segments == [trimmedSegment])
        #expect(track.clips.first?.audioSettings.gainDecibels == -9)
        #expect(controller.timelineContentRevision == initialRevision + 1)
    }

    @Test @MainActor func failedNamedTrackPlacementLeavesNoEmptyTrack() {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: .zero,
            duration: ProjectTime(seconds: 2)
        ))
        let asset = MediaAssetRecord(
            name: "Music",
            originalPath: "/tmp/music.m4a",
            bookmarkData: nil,
            duration: ProjectTime(seconds: 2),
            naturalWidth: nil,
            naturalHeight: nil,
            frameRate: nil,
            hasAudio: true,
            sourceEdit: [segment]
        )
        var project = TrimatoProject()
        project.media = [asset]
        _ = project.createTrack(kind: .audio, name: "Music Bed")
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(
            controller: controller,
            editSelection: .asset(asset.id),
            segments: [segment]
        )
        let initialTrackCount = controller.project.tracks.count

        #expect(context.createTrackAndPlace(.append, kind: .audio, name: "Music Bed") == nil)
        #expect(controller.project.tracks.count == initialTrackCount)
        #expect(context.presentedError?.message.contains("not already used") == true)
    }

    @Test @MainActor func failedTrackPlacementProducesANamedDetailedDialog() {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: .zero,
            duration: ProjectTime(seconds: 4)
        ))
        let controller = ProjectController(document: ProjectDocument())
        let context = ClipPlacementCommandContext(
            controller: controller,
            editSelection: .asset(UUID()),
            segments: [segment]
        )

        #expect(context.place(.append, onTrack: UUID()) == nil)
        #expect(context.presentedError?.title == "Clip Could Not Be Appended to Track")
        #expect(context.presentedError?.message.contains("source clip is no longer available") == true)
    }

    @Test func oneSourceRangeOpensTheFullSourceWithSavedMarkers() {
        let segment = SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))

        let opening = ClipEditorOpeningConfiguration.make(
            segments: [segment],
            sourceDuration: ProjectTime(seconds: 10)
        )

        #expect(opening.playbackSegments == nil)
        #expect(opening.inMarker == ProjectTime(seconds: 1))
        #expect(opening.outMarker == ProjectTime(seconds: 4))
    }

    @Test func multipleSourceRangesOpenAsTheCurrentEditedSequence() {
        let segments = [
            SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 2)
            )),
            SourceSegment(sourceRange: ProjectTimeRange(
                start: ProjectTime(seconds: 5),
                duration: ProjectTime(seconds: 3)
            )),
        ]

        let opening = ClipEditorOpeningConfiguration.make(
            segments: segments,
            sourceDuration: ProjectTime(seconds: 10)
        )

        #expect(opening.playbackSegments == segments)
        #expect(opening.inMarker == .zero)
        #expect(opening.outMarker == ProjectTime(seconds: 5))
    }

    @Test func markerSelectionMapsBackToTheOriginalSourceRange() {
        let timeline = ClipEditTimeline(sourceRanges: [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            CMTimeRange(
                start: CMTime(seconds: 5, preferredTimescale: 600),
                duration: CMTime(seconds: 3, preferredTimescale: 600)
            ),
        ])

        let selected = timeline.sourceRanges(in: CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 600),
            duration: CMTime(seconds: 3, preferredTimescale: 600)
        ))

        #expect(selected == [
            CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600),
                duration: CMTime(seconds: 1, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 5, preferredTimescale: 600),
                duration: CMTime(seconds: 2, preferredTimescale: 600)
            ),
        ])
    }

    @Test func draftTracksRangesWithoutTreatingNewSegmentIdentifiersAsEdits() {
        let range = ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 3))
        var draft = ClipEditorDraft(segments: [SourceSegment(sourceRange: range)])

        draft.replace(with: [SourceSegment(sourceRange: range)])
        #expect(!draft.hasChanges)

        draft.replace(with: [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 2),
            duration: ProjectTime(seconds: 2)
        ))])
        #expect(draft.hasChanges)

        draft.commit()
        #expect(!draft.hasChanges)
    }
}

private struct ClipSessionProjectViewer: View {
    let controller: ProjectController
    let preview: ProjectPlayerViewModel
    let openClipEditor: (EditorSelection) -> Void
    @Namespace private var links

    var body: some View {
        ProjectViewerView(controller: controller, openClipEditor: openClipEditor,
                          workspacePaneLinks: links, viewModel: preview)
    }
}
