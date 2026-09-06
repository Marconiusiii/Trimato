import AppKit
import Combine
import AVFoundation
import SwiftUI
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FilterPresentationTests {
    private func attribute(_ item: NSObject, _ key: String) -> Any? {
        item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
    }
    private func elements(_ item: NSObject) -> [NSObject] {
        [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func namedButton(_ name: String, in view: NSView) throws -> NSObject {
        try #require(elements(view).first {
            attribute($0, "accessibilityRole") as? String == "AXButton" &&
            (attribute($0, "accessibilityTitle") as? String == name || attribute($0, "accessibilityLabel") as? String == name)
        }, "Missing button: \(name)")
    }
    private func press(_ button: NSObject) throws {
        if let cell = button as? NSButtonCell, let control = cell.controlView as? NSButton {
            try #require(control.isEnabled)
            control.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(button.responds(to: selector))
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(button.method(for: selector), to: Action.self)
        #expect(action(button, selector))
    }
    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func sheet(_ window: NSWindow) async throws -> NSWindow {
        for _ in 0..<100 {
            if let sheet = window.attachedSheet, sheet.contentView != nil { return sheet }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderInvalidValue)
    }

    @Test(arguments: ClipFilterKind.allCases)
    func everyAudioAndVideoFilterPresentsAndReopens(kind: ClipFilterKind) async throws {
        let harness = FilterSheetHarnessState()
        let window = host(FilterSheetHarness(state: harness, kind: kind))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        try press(namedButton("Add Filter…", in: try #require(window.contentView)))
        let presented = try await sheet(window)
        presented.contentView?.layoutSubtreeIfNeeded()
        #expect(Date().timeIntervalSince(started) < 5)
        try await Task.sleep(for: .milliseconds(100))
        let content = try #require(presented.contentView)
        let controls = elements(content)
        #expect(controls.filter { attribute($0, "accessibilityRole") as? String == "AXSlider" }.count == kind.parameters.count)
        for parameter in kind.parameters {
            let labels = controls.filter { attribute($0, "accessibilityValue") as? String == parameter.label }
            let fields = labels.flatMap { label in
                (attribute(label, "accessibilityServesAsTitleForUIElements") as? [NSObject] ?? []).flatMap(elements)
            }
            let field = try #require(fields.first { attribute($0, "accessibilityRole") as? String == "AXTextField" })
            #expect((attribute(field, "accessibilityPlaceholderValue") as? String ?? "").isEmpty)
        }
        try press(namedButton("Cancel", in: content))
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(harness.added == nil)
        #expect(window.attachedSheet == nil)
        try press(namedButton("Add Filter…", in: try #require(window.contentView)))
        let reopened = try await sheet(window)
        try await Task.sleep(for: .milliseconds(100))
        try press(namedButton("Add", in: try #require(reopened.contentView)))
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(harness.added?.kind == kind)
    }

    @Test(arguments: [ClipFilterKind.tone, .cropOrientation])
    func editingExistingDenseRangeFiltersRemainsResponsive(kind: ClipFilterKind) async throws {
        let started = Date()
        let window = host(EditClipFilterView(filter: ClipFilter(kind: kind), apply: { _ in }, cancel: {}))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(elements(try #require(window.contentView)).filter { attribute($0, "accessibilityRole") as? String == "AXSlider" }.count == kind.parameters.count)
    }

    @Test func voiceChoicesUseRecordingMetadataAndDoNotDuplicateActiveSettings() {
        let all = AddFilterChoice.available(audio: true, existing: [], voice: VoiceAdjustment())
        #expect(all.contains(.voiceMatching))
        #expect(all.contains(.voiceSmoothing))
        #expect(!AddFilterChoice.available(audio: false, existing: [], voice: VoiceAdjustment()).contains(.voiceMatching))
        #expect(!AddFilterChoice.available(audio: true, existing: [], voice: nil).contains(.voiceSmoothing))
        let active = VoiceAdjustment(targetLoudness: -23, evenOut: true)
        #expect(!AddFilterChoice.available(audio: true, existing: [], voice: active).contains(.voiceMatching))
        #expect(!AddFilterChoice.available(audio: true, existing: [], voice: active).contains(.voiceSmoothing))
    }

    @Test(arguments: [true, false])
    func voiceFiltersCanBeAddedFromTheSheet(matching: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-filter-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3", url.path])
        var project = TrimatoProject()
        var source = MediaAssetRecord(name: "Show", originalPath: url.path, duration: ProjectTime(seconds: 3), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)))])
        project.media = [source]
        _ = try project.append(asset: source)
        source.id = UUID()
        source.name = "Narration"
        source.recordingPurpose = .audioDescription
        let id = project.putRecording(source, at: ProjectTime(seconds: 3))
        var audio = AudioClipSettings.neutral
        audio.voice = VoiceAdjustment(targetLoudness: matching ? nil : -23, referenceEnd: 3, evenOut: matching)
        try project.setClipEffects(id: id, audio: audio, filters: nil)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: source.sourceEdit)
        let state = FilterSheetHarnessState()
        let window = host(VoiceFilterSheetHarness(state: state, context: context))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        try press(namedButton("Add Filter…", in: try #require(window.contentView)))
        let presented = try await sheet(window)
        try await Task.sleep(for: .milliseconds(150))
        let content = try #require(presented.contentView)
        if matching {
            try press(namedButton("Match voice loudness to show", in: content))
            for _ in 0..<500 {
                if let cell = try? namedButton("Add", in: content) as? NSButtonCell,
                   (cell.controlView as? NSButton)?.isEnabled == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(context.audioSettings == audio)
        try press(namedButton("Add", in: content))
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        let result = try #require(state.addedVoice)
        #expect(result.evenOut)
        #expect(result.targetLoudness?.isFinite == true)
        #expect(!controller.document.hasUnsavedChanges)
        context.audioSettings?.voice = result
        #expect(context.performUpdate())
        #expect(controller.project.timelineClip(id: id)?.audioSettings.voice == result)
        #expect(controller.document.hasUnsavedChanges)
        let edit = host(EditRecordedVoiceFilterView(context: context, smoothingOnly: !matching, beforePlayback: {}, apply: { _ in }, cancel: {}))
        defer { edit.close() }
        edit.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        _ = try namedButton("Apply", in: try #require(edit.contentView))
    }

    @Test(arguments: [false, true])
    func filterComparisonPlaysWithoutChangingDraft(video: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audition-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=red:s=160x120:r=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-c:v", "prores_ks", "-c:a", "pcm_s16le", url.path])
        var project = TrimatoProject()
        let record = MediaAssetRecord(name: "Comparison", originalPath: url.path, duration: ProjectTime(seconds: 1), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
        var configured = record
        configured.naturalWidth = video ? 160 : nil
        configured.naturalHeight = video ? 120 : nil
        project.media = [configured]
        let id = try project.append(asset: configured)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: configured.sourceEdit)
        let work = VoiceAdjustmentWork()
        let window = host(FilterAuditionView(context: context, work: work,
            candidate: ClipFilter(kind: video ? .brightnessContrast : .tone), voice: nil, voiceMatching: false, beforePlayback: {}))
        defer { work.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let content = try #require(window.contentView)
        for title in ["Play without this filter", "Play with this filter"] {
            try press(namedButton(title, in: content))
            for _ in 0..<500 where work.busy { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!work.busy)
            #expect(work.message == nil)
            let item = try #require(work.player.currentItem)
            #expect(try await item.asset.loadTracks(withMediaType: .audio).count == 1)
            if video { #expect(try await item.asset.loadTracks(withMediaType: .video).count == 1) }
            try press(namedButton("Stop preview", in: content))
            #expect(work.player.currentItem == nil)
        }
        #expect(context.filters.isEmpty)
        #expect(!controller.document.hasUnsavedChanges)
    }

    @Test func actualAudioClipEditorOpensAddFilter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filter-editor-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", url.path])
        var project = TrimatoProject()
        let record = MediaAssetRecord(name: "Filter test", originalPath: url.path, duration: ProjectTime(seconds: 1), hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))])
        project.media = [record]
        let id = try project.append(asset: record)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let context = ClipPlacementCommandContext(controller: controller, editSelection: .timelineClip(id), segments: record.sourceEdit)
        let window = host(SourceClipEditorView(controller: controller, asset: record, editSelection: .timelineClip(id),
            initialSegments: record.sourceEdit, commandContext: context))
        context.hostWindow = window
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        let started = Date()
        try press(namedButton("Add Filter…", in: try #require(window.contentView)))
        let presented = try await sheet(window)
        presented.contentView?.layoutSubtreeIfNeeded()
        #expect(Date().timeIntervalSince(started) < 5)
        try await Task.sleep(for: .milliseconds(200))
        try press(namedButton("Cancel", in: try #require(presented.contentView)))
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.attachedSheet == nil)
        #expect(context.filters.isEmpty)
        #expect(!controller.document.hasUnsavedChanges)
    }
}

@MainActor
private final class FilterSheetHarnessState: ObservableObject {
    @Published var showing = false
    @Published var added: ClipFilter?
    @Published var addedVoice: VoiceAdjustment?
}

private struct FilterSheetHarness: View {
    @ObservedObject var state: FilterSheetHarnessState
    let kind: ClipFilterKind
    var body: some View {
        Button("Add Filter…") { state.showing = true }
            .sheet(isPresented: $state.showing) {
                AddClipFilterView(audio: kind.isAudio, existing: ClipFilterKind.allCases.filter { $0 != kind },
                    add: { state.added = $0; state.showing = false }, cancel: { state.showing = false })
            }
    }
}

private struct VoiceFilterSheetHarness: View {
    @ObservedObject var state: FilterSheetHarnessState
    let context: ClipPlacementCommandContext
    var body: some View {
        Button("Add Filter…") { state.showing = true }
            .sheet(isPresented: $state.showing) {
                AddClipFilterView(audio: true, existing: ClipFilterKind.allCases,
                    voiceContext: context, addVoice: { state.addedVoice = $0; state.showing = false },
                    add: { _ in }, cancel: { state.showing = false })
            }
    }
}
