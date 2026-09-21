import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct MarkerAccessibilityTests {
    private func project() throws -> TrimatoProject {
        var definition = GeneratorDefinition()
        definition.kind = .black
        definition.width = 320
        definition.height = 180
        definition.frameRate = 30
        definition.duration = ProjectTime(seconds: 8)
        let asset = definition.assetRecord()
        var project = TrimatoProject(name: "Marker feedback")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 30)
        project.media = [asset]
        _ = try project.append(asset: asset)
        return project
    }

    private func ready(_ player: ProjectPlayerViewModel) async throws {
        for _ in 0..<300 where !player.canControlPlayback {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(player.canControlPlayback)
    }

    private func attribute(_ item: NSObject, _ key: String) -> Any? {
        item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
    }

    private func descendants(_ item: NSObject) -> [NSObject] {
        [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
    }

    private func host<Content: View>(_ view: Content) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func preservePreference(_ key: String) -> () -> Void {
        let previous = UserDefaults.standard.object(forKey: key)
        return {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func markerEvent(_ type: NSEvent.EventType, window: NSWindow? = nil,
                             repeating: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window?.windowNumber ?? 0, context: nil,
                                     characters: ";", charactersIgnoringModifiers: ";",
                                     isARepeat: repeating, keyCode: 41))
    }

    @Test(arguments: [true, false])
    func markerNamesTakePriorityAtStartEndAndInOut(includeTimecode: Bool) {
        for seconds in [0.0, 2, 5, 8] {
            let time = ProjectTime(seconds: seconds)
            let point = ProjectEditPoint(time: time, hasVideo: false, hasAudio: false, markerTitle: "Opening chapter")
            let result = ProjectPlayerViewModel.navigationAnnouncement(
                destination: time, duration: ProjectTime(seconds: 8),
                inMarker: ProjectTime(seconds: 2), outMarker: ProjectTime(seconds: 5),
                frameRate: 30, editPoint: point, includeTimecode: includeTimecode)
            #expect(includeTimecode ? result.hasPrefix("Opening chapter, ") : result == "Opening chapter")
        }
    }

    @Test func markerNavigationKeepsSliderValueAsTimeAfterSeekAndFocusRefresh() async throws {
        let restore = preservePreference(AppPreferenceKey.timecodeFeedback)
        defer { restore() }
        UserDefaults.standard.set(TimecodeFeedback.live.rawValue, forKey: AppPreferenceKey.timecodeFeedback)
        var project = try project()
        _ = project.insertMarker(at: .zero)
        let second = project.insertMarker(at: ProjectTime(seconds: 2))
        _ = project.insertMarker(at: project.duration)
        let trackIndex = try #require(project.tracks.firstIndex { $0.kind == .markers })
        let markerIndex = try #require(project.tracks[trackIndex].markers.firstIndex { $0.id == second.id })
        project.tracks[trackIndex].markers[markerIndex].title = "Music begins"
        let player = ProjectPlayerViewModel()
        player.prepare(project: project, mediaURLs: [:])
        try await ready(player)
        player.selectEditPointTrack(project.markerTrack?.id, in: project)
        var values: [String] = []
        let observation = player.$accessibilityTimecodeLabel.dropFirst().sink { values.append($0) }
        defer { withExtendedLifetime(observation) {}; player.player.pause() }
        for (forward, title, seconds) in [(true, "Music begins", 2.0), (true, "Marker 3", 8.0),
                                          (false, "Music begins", 2.0), (false, "Marker 1", 0.0)] {
            values.removeAll()
            if forward { player.goToNextEdit() } else { player.goToPreviousEdit() }
            try await Task.sleep(for: .milliseconds(250))
            player.refreshAccessibilityValueForFocus()
            #expect(abs(player.currentTime.seconds - seconds) < 0.02)
            #expect(player.accessibilityTimecodeLabel == player.currentTimecodeForAnnouncement)
            #expect(!values.isEmpty)
            #expect(values.allSatisfy { !$0.contains(title) }, "Marker announcements must not become the slider value")
        }
        UserDefaults.standard.set(TimecodeFeedback.onDemand.rawValue, forKey: AppPreferenceKey.timecodeFeedback)
        player.goToNextEdit()
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.accessibilityTimecodeLabel == player.currentTimecodeForAnnouncement)
        player.seek(to: ProjectTime(seconds: 3.5))
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.accessibilityTimecodeLabel == player.currentTimecodeForAnnouncement)
        #expect(!player.accessibilityTimecodeLabel.contains("Music begins"))
    }

    @Test(arguments: [true, false])
    func repeatedMarkerCreationPreservesNativePlayheadAndPlayback(playing: Bool) async throws {
        let restore = preservePreference(AppPreferenceKey.markerAudio)
        defer { restore() }
        UserDefaults.standard.set(false, forKey: AppPreferenceKey.markerAudio)
        let controller = ProjectController(document: ProjectDocument(project: try project()))
        let player = ProjectPlayerViewModel()
        let (host, window) = host(MarkerViewerFixture(controller: controller, player: player))
        defer { player.player.pause(); window.close() }
        try await ready(player)
        try await Task.sleep(for: .milliseconds(150))
        func playhead() throws -> NSObject {
            try #require(descendants(host).first {
                attribute($0, "accessibilityRole") as? String == "AXSlider" &&
                attribute($0, "accessibilityLabel") as? String == "Project playhead"
            })
        }
        let original = try playhead()
        #expect(attribute(original, "accessibilityRole") as? String == "AXSlider")
        let originalValue = try #require(attribute(original, "accessibilityValueDescription") as? String)
        #expect(originalValue == player.accessibilityTimecodeLabel)
        let item = player.player.currentItem
        let focusRevision = controller.editorFocusRestoreRequest
        player.scopeKeyboardCommands { true }
        if playing { player.player.play() }
        try await Task.sleep(for: .milliseconds(200))
        let beginning = player.precisePlayhead
        let controlNames = ["Go to beginning", "Next edit point", "Mark In"]
        let originalControls = try controlNames.map { name in
            try #require(descendants(host).first { item in
                attribute(item, "accessibilityRole") as? String == "AXButton" &&
                ["accessibilityLabel", "accessibilityTitle"].contains { attribute(item, $0) as? String == name }
            }, "Missing control: \(name)")
        }
        let timelineFocusRevision = controller.timelineFocusRestoreRequest
        let timelineListFocusRevision = controller.timelineListFocusRestoreRequest
        var spokenUpdates: [String] = []
        let observation = player.$accessibilityTimecodeLabel.dropFirst().sink { spokenUpdates.append($0) }
        defer { withExtendedLifetime(observation) {} }
        for _ in 0..<4 {
            let tapped = player.precisePlayhead
            #expect(player.handleEditorKeyEvent(try markerEvent(.keyDown, window: window)) == nil)
            #expect(player.handleEditorKeyEvent(try markerEvent(.keyUp, window: window)) == nil)
            try await Task.sleep(for: .milliseconds(150))
            let current = try playhead()
            #expect(current === original, "Creating markers must preserve the native slider element")
            #expect(attribute(current, "accessibilityValueDescription") as? String == originalValue)
            let markerTime = try #require(controller.project.markerTrack?.markers.last?.time)
            #expect(abs(markerTime.seconds - tapped.seconds) < 0.1)
            for (name, originalControl) in zip(controlNames, originalControls) {
                let currentControl = try #require(descendants(host).first { item in
                    attribute(item, "accessibilityRole") as? String == "AXButton" &&
                    ["accessibilityLabel", "accessibilityTitle"].contains { attribute(item, $0) as? String == name }
                })
                #expect(currentControl === originalControl)
            }
            #expect(controller.timelineFocusRestoreRequest == timelineFocusRevision)
            #expect(controller.timelineListFocusRestoreRequest == timelineListFocusRevision)
            #expect(player.player.currentItem === item && player.player.rate == (playing ? 1 : 0))
            #expect(controller.editorFocusRestoreRequest == focusRevision)
        }
        #expect(playing ? player.precisePlayhead > beginning : player.precisePlayhead == beginning)
        #expect(spokenUpdates.isEmpty)
        #expect(controller.project.markerTrack?.markers.count == 4)
        player.player.pause()
        try await Task.sleep(for: .milliseconds(150))
        var renamed = try #require(controller.project.markerTrack?.markers.first)
        renamed.title = "First cue"
        controller.saveMarker(renamed)
        player.seek(to: .zero)
        try await Task.sleep(for: .milliseconds(150))
        if playing { player.goToNextEdit() } else { player.goToStart() }
        try await Task.sleep(for: .milliseconds(250))
        let navigatedValue = try #require(attribute(try playhead(), "accessibilityValueDescription") as? String)
        #expect(navigatedValue == player.currentTimecodeForAnnouncement)
        #expect(!navigatedValue.contains("First cue"))
    }

    @Test func markerDrawingRendersAtTimelinePositions() throws {
        let duration = ProjectTime(seconds: 10)
        func coloredColumns(_ markers: [TimelineMarker]) throws -> Set<Int> {
            let renderer = ImageRenderer(content: ProjectMarkerIndicators(markers: markers, duration: duration)
                .frame(width: 200, height: 12))
            let image = try #require(renderer.cgImage)
            #expect(image.width == 200 && image.height == 12)
            var pixels = [UInt8](repeating: 0, count: 200 * 12 * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 200, height: 12,
                    bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 12))
            }
            return Set((0..<200).filter { x in (0..<12).contains { y in pixels[(y * 200 + x) * 4 + 3] > 0 } })
        }
        #expect(try coloredColumns([]).isEmpty)
        let markers = [0.0, 5, 10].enumerated().map { index, seconds in
            TimelineMarker(index: index + 1, time: ProjectTime(seconds: seconds), title: "Cue", type: index == 1 ? .chapter : .marker)
        }
        let columns = try coloredColumns(markers)
        for center in [8, 100, 192] {
            #expect(columns.contains { abs($0 - center) <= 4 })
        }
        #expect(columns.allSatisfy { x in [8, 100, 192].contains { abs(x - $0) <= 6 } })
    }

    @Test func markerShortcutConsumesOnlyItsOwnKeySequence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: 48_000)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let asset = MediaAssetRecord(name: "Silent marker fixture", originalPath: url.path,
            duration: ProjectTime(seconds: 1), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))],
            playbackMode: .nativePassthrough)
        var project = TrimatoProject(name: "Marker key sequence")
        project.media = [asset]
        _ = try project.append(asset: asset)
        let player = ProjectPlayerViewModel()
        player.prepare(project: project, mediaURLs: [asset.id: url])
        try await ready(player)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.installProjectPlayer(player)
        var active = true
        player.scopeKeyboardCommands { active }
        let focusRevision = controller.editorFocusRestoreRequest
        let item = player.player.currentItem

        let unmatchedRelease = try markerEvent(.keyUp)
        #expect(player.handleEditorKeyEvent(unmatchedRelease) === unmatchedRelease)
        let modifiedPress = try markerEvent(.keyDown, modifiers: .command)
        #expect(player.handleEditorKeyEvent(modifiedPress) === modifiedPress)
        #expect(player.handleEditorKeyEvent(try markerEvent(.keyDown)) == nil)
        #expect(controller.project.markerTrack?.markers.count == 1)
        #expect(player.handleEditorKeyEvent(try markerEvent(.keyDown, repeating: true)) == nil)
        #expect(controller.project.markerTrack?.markers.count == 1)
        active = false
        #expect(player.handleEditorKeyEvent(try markerEvent(.keyUp, modifiers: .shift)) == nil)
        let outsideEditor = try markerEvent(.keyDown)
        #expect(player.handleEditorKeyEvent(outsideEditor) === outsideEditor)
        active = true
        #expect(player.handleEditorKeyEvent(try markerEvent(.keyDown)) == nil)
        #expect(player.handleEditorKeyEvent(try markerEvent(.keyUp)) == nil)
        #expect(controller.project.markerTrack?.markers.count == 2)
        #expect(controller.project.markerTrack?.markers.allSatisfy { $0.time == .zero } == true)
        #expect(controller.editorFocusRestoreRequest == focusRevision)
        #expect(player.player.currentItem === item && player.player.rate == 0)
        player.goToStart()
        try await Task.sleep(for: .milliseconds(100))
        player.refreshAccessibilityValueForFocus()
        #expect(player.accessibilityTimecodeLabel == player.currentTimecodeForAnnouncement)
        #expect(!player.accessibilityTimecodeLabel.contains("Marker"))
    }

    @Test func markerDialogLabelsPositionAndRespondsToPrecisionSetting() async throws {
        let restore = preservePreference(AppPreferenceKey.precisionTimecode)
        defer { restore() }
        var project = try project()
        let marker = project.insertMarker(at: ProjectTime(seconds: 5.125))
        let (host, window) = host(MarkerEditorSheet(marker: marker, save: { _ in }, cancel: {}))
        defer { window.close() }
        for (precision, expected) in [(true, "00:00:05.125"), (false, "0:05"), (true, "00:00:05.125")] {
            UserDefaults.standard.set(precision, forKey: AppPreferenceKey.precisionTimecode)
            try await Task.sleep(for: .milliseconds(250))
            let strings = descendants(host).flatMap { item in
                ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].compactMap {
                    attribute(item, $0) as? String
                }
            }
            #expect(strings.contains("Marker position: \(expected)"))
            #expect(!strings.contains(expected), "The position must not be an unqualified timecode")
        }
        #expect(marker.time.seconds == 5.125)
    }
}

private struct MarkerViewerFixture: View {
    @Namespace private var panes
    @ObservedObject var controller: ProjectController
    let player: ProjectPlayerViewModel
    var body: some View {
        HSplitView {
            MacEditorPane("Project") {
                ProjectBrowserView(controller: controller, openClipEditor: { _ in },
                                   workspacePaneLinks: panes, initialImportFocusRequest: 0)
            }.frame(width: 240)
            VSplitView {
                MacEditorPane("Editor") {
                    ProjectViewerView(controller: controller, openClipEditor: { _ in },
                                      workspacePaneLinks: panes, viewModel: player)
                }.frame(minHeight: 500)
                MacEditorPane("Timeline") {
                    ProjectTimelineView(controller: controller, openClipEditor: { _ in },
                                        workspacePaneLinks: panes)
                }.frame(minHeight: 240)
            }
        }
    }
}
