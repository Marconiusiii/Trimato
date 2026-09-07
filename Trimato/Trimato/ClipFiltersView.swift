import SwiftUI
import AVKit

nonisolated enum AppliedFilterSelection: Hashable, Identifiable {
    case filter(UUID)
    case voiceMatching
    case voiceSmoothing
    var id: Self { self }
}

struct ClipFiltersView: View {
    @ObservedObject var context: ClipPlacementCommandContext
    var beforePlayback: () -> Void = {}
    @State private var selection: AppliedFilterSelection?
    @State private var editing: AppliedFilterSelection?
    @State private var pending: ClipFilter?
    @State private var pendingVoice: VoiceAdjustment?
    private enum FocusTarget: Hashable { case list, edit }
    @FocusState private var keyboardFocus: FocusTarget?
    @AccessibilityFocusState private var voiceOverFocus: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(context.filters) { filter in
                    Text("\(filter.kind.title), \(filter.enabled ? "Enabled" : "Disabled")")
                        .tag(AppliedFilterSelection.filter(filter.id))
                }
                if context.audioSettings?.voice?.targetLoudness != nil {
                    Text("Match voice loudness to show, Enabled").tag(AppliedFilterSelection.voiceMatching)
                }
                if context.audioSettings?.voice?.evenOut == true {
                    Text("Even out voice, Enabled").tag(AppliedFilterSelection.voiceSmoothing)
                }
            }
            .accessibilityLabel("Applied Filters")
            .focused($keyboardFocus, equals: .list)
            .accessibilityFocused($voiceOverFocus, equals: .list)
            HStack {
                Button("Edit Filter…") { beforePlayback(); editing = selection }
                    .disabled(selection == nil)
                    .focused($keyboardFocus, equals: .edit)
                    .accessibilityFocused($voiceOverFocus, equals: .edit)
                Button("Remove Filter") {
                    guard let selection else { return }
                    switch selection {
                    case .filter(let id): context.filters.removeAll { $0.id == id }
                    case .voiceMatching: context.audioSettings?.voice?.targetLoudness = nil
                    case .voiceSmoothing: context.audioSettings?.voice?.evenOut = false
                    }
                    self.selection = nil
                    restoreFocus()
                }.disabled(selection == nil)
            }
        }
        .onChange(of: context.audioSettings?.voice) { validateSelection() }
        .onChange(of: context.filters) { validateSelection() }
        .sheet(item: $editing, onDismiss: finishEditingFilter) { request in
            switch request {
            case .filter(let id):
                if let filter = context.filters.first(where: { $0.id == id }) {
                    EditClipFilterView(filter: filter, context: context, beforePlayback: beforePlayback,
                        apply: { pending = $0; editing = nil }, cancel: { editing = nil })
                }
            case .voiceMatching, .voiceSmoothing:
                EditRecordedVoiceFilterView(context: context, smoothingOnly: request == .voiceSmoothing, beforePlayback: beforePlayback,
                    apply: { pendingVoice = $0; editing = nil }, cancel: { editing = nil })
            }
        }
    }

    private func finishEditingFilter() {
        if let pending, let index = context.filters.firstIndex(where: { $0.id == pending.id }) {
            context.filters[index] = pending
        }
        if let pendingVoice { context.audioSettings?.voice = pendingVoice }
        pending = nil
        pendingVoice = nil
        validateSelection()
        restoreFocus()
    }

    private func validateSelection() {
        switch selection {
        case .filter(let id): if !context.filters.contains(where: { $0.id == id }) { selection = nil }
        case .voiceMatching: if context.audioSettings?.voice?.targetLoudness == nil { selection = nil }
        case .voiceSmoothing: if context.audioSettings?.voice?.evenOut != true { selection = nil }
        case nil: break
        }
    }

    private func restoreFocus() {
        Task { @MainActor in
            await Task.yield()
            keyboardFocus = selection == nil ? .list : .edit
            voiceOverFocus = keyboardFocus
        }
    }
}

struct EditRecordedVoiceFilterView: View {
    let context: ClipPlacementCommandContext
    let smoothingOnly: Bool
    let beforePlayback: () -> Void
    let apply: (VoiceAdjustment) -> Void
    let cancel: () -> Void
    @State private var voice: VoiceAdjustment
    @StateObject private var work = VoiceAdjustmentWork()

    init(context: ClipPlacementCommandContext, smoothingOnly: Bool, beforePlayback: @escaping () -> Void,
         apply: @escaping (VoiceAdjustment) -> Void, cancel: @escaping () -> Void) {
        self.context = context
        self.smoothingOnly = smoothingOnly
        self.beforePlayback = beforePlayback
        self.apply = apply
        self.cancel = cancel
        _voice = State(initialValue: context.audioSettings?.voice ?? VoiceAdjustment())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if smoothingOnly {
                Text("Even out voice").font(.headline).accessibilityAddTraits(.isHeader)
                VoiceSmoothingControls(settings: $voice)
            } else {
                VoiceAdjustmentControls(settings: $voice, controller: context.controller, work: work,
                    track: nil, validateTake: context.validateVoice, applyTrack: { _ in }, beforePlayback: beforePlayback)
            }
            FilterAuditionView(context: context, work: work, candidate: nil, voice: voice,
                voiceMatching: !smoothingOnly, beforePlayback: { work.cancel(); beforePlayback() })
            NativeModalActions(primaryTitle: "Apply", primaryEnabled: !work.busy, cancel: cancel, primary: { apply(voice) })
        }
        .padding(20).frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .applicationMessage(work.message) { work.message = nil }
        .onDisappear { work.cancel() }
    }
}

nonisolated enum AddFilterChoice: Hashable, Identifiable {
    case filter(ClipFilterKind)
    case voiceMatching
    case voiceSmoothing
    var id: Self { self }
    var title: String {
        switch self {
        case .filter(let kind): kind.title
        case .voiceMatching: "Match voice loudness to show"
        case .voiceSmoothing: "Even out voice"
        }
    }
    static func available(audio: Bool, existing: [ClipFilterKind], voice: VoiceAdjustment?) -> [Self] {
        var choices = ClipFilterKind.allCases.filter { $0.isAudio == audio && $0 != .tone && !existing.contains($0) }.map(Self.filter)
        if audio, let voice {
            if voice.targetLoudness == nil { choices.append(.voiceMatching) }
            if !voice.evenOut { choices.append(.voiceSmoothing) }
        }
        return choices
    }
}

struct AddClipFilterView: View {
    let available: [AddFilterChoice]
    let add: (ClipFilter) -> Void
    let cancel: () -> Void
    let voiceContext: ClipPlacementCommandContext?
    let addVoice: (VoiceAdjustment) -> Void
    let beforePlayback: () -> Void
    let initialVoice: VoiceAdjustment
    @State private var selection: AddFilterChoice
    @State private var draft: ClipFilter
    @State private var voiceDraft: VoiceAdjustment
    @StateObject private var voiceWork = VoiceAdjustmentWork()
    @FocusState private var pickerKeyboardFocused: Bool
    @AccessibilityFocusState private var pickerVoiceOverFocused: Bool
    @State private var focusRequest = UUID()

    init(
        audio: Bool,
        existing: [ClipFilterKind],
        voiceContext: ClipPlacementCommandContext? = nil,
        addVoice: @escaping (VoiceAdjustment) -> Void = { _ in },
        beforePlayback: @escaping () -> Void = {},
        add: @escaping (ClipFilter) -> Void,
        cancel: @escaping () -> Void
    ) {
        let supportsVoice = voiceContext?.narrationTrack != nil
        var voice = voiceContext?.audioSettings?.voice ?? VoiceAdjustment()
        if voiceContext?.audioSettings?.voice == nil, let controller = voiceContext?.controller {
            if let range = controller.captionDraftRange {
                voice.referenceStart = range.start.seconds
                voice.referenceEnd = range.end.seconds
            } else { voice.referenceEnd = min(5, controller.project.duration.seconds) }
        }
        available = AddFilterChoice.available(audio: audio, existing: existing, voice: supportsVoice ? voice : nil)
        let initial = available.first ?? .filter(audio ? .tone : .brightnessContrast)
        _selection = State(initialValue: initial)
        if case .filter(let kind) = initial { _draft = State(initialValue: ClipFilter(kind: kind)) }
        else { _draft = State(initialValue: ClipFilter(kind: .tone)) }
        initialVoice = voice
        if initial == .voiceSmoothing { voice.evenOut = true }
        _voiceDraft = State(initialValue: voice)
        self.voiceContext = voiceContext
        self.addVoice = addVoice
        self.beforePlayback = beforePlayback
        self.add = add
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Filter").font(.headline).accessibilityAddTraits(.isHeader)
            if available.isEmpty {
                Text("All available filters have been added to this clip.")
            } else {
                Picker("Filter", selection: $selection) {
                    ForEach(available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .focused($pickerKeyboardFocused)
                .accessibilityFocused($pickerVoiceOverFocused)
                .disabled(voiceWork.busy)
                switch selection {
                case .filter(let kind):
                    Text(kind.description)
                    ClipFilterParameters(filter: $draft)
                case .voiceMatching:
                    if let context = voiceContext {
                        VoiceAdjustmentControls(settings: $voiceDraft, controller: context.controller, work: voiceWork,
                            track: nil, validateTake: context.validateVoice, applyTrack: { _ in }, beforePlayback: beforePlayback)
                    }
                case .voiceSmoothing:
                    Text("Reduce differences between louder and quieter words in this recording.")
                    VoiceSmoothingControls(settings: $voiceDraft)
                }
            }
            if let context = voiceContext, !available.isEmpty {
                FilterAuditionView(context: context, work: voiceWork,
                    candidate: { if case .filter = selection { return draft }; return nil }(),
                    voice: selection == .voiceMatching || selection == .voiceSmoothing ? voiceDraft : nil,
                    voiceMatching: selection == .voiceMatching,
                    beforePlayback: { voiceWork.cancel(); beforePlayback() })
                    .disabled(voiceWork.busy)
            }
            NativeModalActions(
                primaryTitle: "Add",
                primaryEnabled: !available.isEmpty && !voiceWork.busy &&
                    (selection != .voiceMatching || voiceDraft.targetLoudness != nil) &&
                    (selection != .voiceSmoothing || voiceDraft.evenOut),
                cancel: cancel,
                primary: {
                    if case .filter = selection { add(draft) }
                    else { addVoice(voiceDraft) }
                }
            )
        }
        .padding(20)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .applicationMessage(voiceWork.message) { voiceWork.message = nil }
        .task {
            await Task.yield()
            guard !available.isEmpty else { return }
            pickerKeyboardFocused = true
            pickerVoiceOverFocused = true
        }
        .onChange(of: selection) { _, choice in
            voiceWork.cancel()
            if case .filter(let kind) = choice { draft = ClipFilter(kind: kind) }
            if choice == .voiceMatching || choice == .voiceSmoothing { voiceDraft = initialVoice }
            if choice == .voiceSmoothing { voiceDraft.evenOut = true }
            // Keep the Picker identity and restore its local focus after native menu dismissal.
            let request = UUID()
            focusRequest = request
            pickerVoiceOverFocused = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard focusRequest == request else { return }
                pickerVoiceOverFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard focusRequest == request else { return }
                pickerVoiceOverFocused = true
            }
        }
        .onDisappear { focusRequest = UUID(); voiceWork.cancel() }
    }
}

struct EditClipFilterView: View {
    @State var filter: ClipFilter
    @StateObject private var previewWork = VoiceAdjustmentWork()
    var context: ClipPlacementCommandContext? = nil
    var beforePlayback: () -> Void = {}
    let apply: (ClipFilter) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(filter.kind.title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable \(filter.kind.title)", isOn: $filter.enabled)
                Text(filter.kind.description)
                ClipFilterParameters(filter: $filter)
            }
            if let context {
                FilterAuditionView(context: context, work: previewWork, candidate: filter, voice: nil,
                    voiceMatching: false, beforePlayback: beforePlayback)
            }
            Button("Reset \(filter.kind.title)") {
                let id = filter.id
                let enabled = filter.enabled
                filter = ClipFilter(kind: filter.kind)
                filter.id = id
                filter.enabled = enabled
            }

            NativeModalActions(
                primaryTitle: "Apply",
                primaryEnabled: !previewWork.busy,
                cancel: cancel,
                primary: { apply(filter) }
            )
        }.padding(20).frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .applicationMessage(previewWork.message) { previewWork.message = nil }
    }
}

/// Shared native controls for audio and video, in both Add and Edit Filter.
struct ClipFilterParameters: View {
    @Binding var filter: ClipFilter
    @AccessibilityFocusState private var rotationFocused: Bool
    @State private var rotationFocusRequest = UUID()

    var body: some View {
        if filter.kind == .reverb {
            Menu("Room: \(["Small room", "Medium room", "Large room"][min(max(Int(filter.value("room")), 0), 2)])") {
                ForEach(Array(["Small room", "Medium room", "Large room"].enumerated()), id: \.offset) { index, name in
                    Button(name) { filter.values["room"] = Double(index) }
                }
            }
        }
        ForEach(filter.kind.parameters.filter { parameter in
            parameter.id != "room" && (parameter.id != "highpass" || filter.highPassEnabled) && (parameter.id != "lowpass" || filter.lowPassEnabled)
        }) { parameter in
            if filter.kind.isAudio {
                AudioValueSlider(label: parameter.label, value: valueBinding(parameter), range: parameter.range,
                    step: parameter.step, unit: unit(parameter), identifier: "trimato.filter.\(parameter.id)")
            } else {
                Slider(value: valueBinding(parameter, snap: true), in: parameter.range) { Text(parameter.label) }
            }
        }
        if filter.kind == .tone {
            Toggle("Reduce low rumble", isOn: $filter.highPassEnabled)
            Toggle("Reduce high-frequency hiss", isOn: $filter.lowPassEnabled)
        }
        if filter.kind == .cropOrientation {
            Picker("Rotation Clockwise", selection: $filter.rotation) {
                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0) degrees").tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityFocused($rotationFocused)
            .onChange(of: filter.rotation) {
                let request = UUID()
                rotationFocusRequest = request
                rotationFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard rotationFocusRequest == request, filter.kind == .cropOrientation else { return }
                    rotationFocused = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard rotationFocusRequest == request, filter.kind == .cropOrientation else { return }
                    rotationFocused = true
                }
            }
            .onDisappear { rotationFocusRequest = UUID() }
            Toggle("Flip Horizontally", isOn: $filter.flipHorizontal)
            Toggle("Flip Vertically", isOn: $filter.flipVertical)
        }
    }

    private func unit(_ parameter: FilterParameter) -> String {
        if parameter.id == "delay" { return "milliseconds" }
        if ["highpass", "lowpass"].contains(parameter.id) { return "Hz" }
        if parameter.id == "target" { return "LUFS" }
        if parameter.id == "ratio" { return "" }
        if parameter.id == "amount", [.reverb, .softenS, .echo].contains(filter.kind) { return "percent" }
        return "dB"
    }

    private func valueBinding(_ parameter: FilterParameter, snap: Bool = false) -> Binding<Double> {
        Binding(get: { filter.value(parameter.id) }, set: { value in
            guard value.isFinite else { return }
            let adjusted = snap ? (value / parameter.step).rounded() * parameter.step : value
            filter.values[parameter.id] = min(max(adjusted, parameter.range.lowerBound), parameter.range.upperBound)
        })
    }
}

/// Auditions a copy of the editor draft. No project or editor settings are published.
struct FilterAuditionView: View {
    let context: ClipPlacementCommandContext
    @ObservedObject var work: VoiceAdjustmentWork
    let candidate: ClipFilter?
    let voice: VoiceAdjustment?
    let voiceMatching: Bool
    let beforePlayback: () -> Void
    @State private var comparison = ""
    @State private var bypass = false
    @State private var withShow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.headline).accessibilityAddTraits(.isHeader)
            if context.audioSettings == nil {
                VideoPlayer(player: work.player).frame(height: 160)
            }
            Toggle("Bypass filter", isOn: $bypass).toggleStyle(.switch)
            if context.audioSettings != nil {
                Toggle("Play with show", isOn: $withShow).toggleStyle(.switch)
            }
            Button(work.busy || work.playing ? "Stop preview" : "Play preview") {
                if work.busy || work.playing { work.cancel() }
                else { play(enabled: !bypass, mixed: withShow) }
            }
            .disabled(!bypass && voiceMatching && voice?.targetLoudness == nil && !work.busy && !work.playing)
            if work.busy { ProgressView("Preparing preview") }
            if !comparison.isEmpty { Text(comparison) }
        }
        .onChange(of: candidate) { updatePreview() }
        .onChange(of: voice) { updatePreview() }
        .onChange(of: bypass) { updatePreview() }
        .onChange(of: withShow) { updatePreview() }
        .onDisappear { work.cancel() }
    }

    func settings(enabled: Bool) -> ([ClipFilter], AudioClipSettings?) {
        var filters = context.filters
        var audio = context.audioSettings
        if let candidate {
            filters.removeAll { $0.id == candidate.id || $0.kind == candidate.kind }
            if enabled { filters.append(candidate) }
        }
        if var voice {
            if !enabled {
                if voiceMatching { voice.targetLoudness = nil }
                else { voice.evenOut = false }
            }
            audio?.voice = voice
        }
        return (filters, audio)
    }

    private func updatePreview() {
        comparison = ""
        let position = max(0, work.player.currentTime().seconds)
        if work.playing { play(enabled: !bypass, mixed: withShow, position: position) }
        else { work.cancel() }
    }

    private func play(enabled: Bool, mixed: Bool, position: Double = 0) {
        beforePlayback()
        let (filters, audio) = settings(enabled: enabled)
        work.run {
            if mixed {
                let url = try await context.voiceMixedPreview(filters: filters, audio: audio)
                do { try await work.play(url, position: position) }
                catch { try? FileManager.default.removeItem(at: url); throw error }
                return
            }
            guard let asset = context.controller.asset(for: context.editSelection),
                  let source = context.controller.resolveURL(for: asset) else {
                throw AudioCaptureError.message("Relink this clip before previewing its filters.")
            }
            let url = try await ClipFilterRenderer.render(source: source, filters: filters,
                audio: audio != nil, duration: asset.duration.seconds, segments: context.segments, audioSettings: audio)
            do {
                if audio != nil {
                    if voiceMatching, enabled, let target = voice?.targetLoudness {
                        var unMatched = audio
                        unMatched?.voice?.targetLoudness = nil
                        let baseline = try await ClipFilterRenderer.render(source: source, filters: filters,
                            audio: true, duration: asset.duration.seconds, segments: context.segments, audioSettings: unMatched)
                        defer { try? FileManager.default.removeItem(at: baseline) }
                        let before = try await VoiceAudioProcessor.measure(baseline)
                        let after = try await VoiceAudioProcessor.measure(url)
                        comparison = String(format: "Loudness change: %+.1f dB. Show reference: %.1f LUFS.", after - before, target)
                    }
                    try await work.play(url, position: position)
                } else {
                    let edited = try await EditedCompositionBuilder.build(asset: AVURLAsset(url: source),
                        sourceRanges: context.segments.map { CMTimeRange(start: $0.sourceRange.start.cmTime, duration: $0.duration.cmTime) })
                    for track in try await edited.loadTracks(withMediaType: .video) { edited.removeTrack(track) }
                    let filtered = AVURLAsset(url: url)
                    if let track = try await filtered.loadTracks(withMediaType: .video).first,
                       let destination = edited.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try destination.insertTimeRange(CMTimeRange(start: .zero, duration: try await filtered.load(.duration)), of: track, at: .zero)
                        destination.preferredTransform = try await track.load(.preferredTransform)
                    }
                    try await work.play(url, asset: edited, position: position)
                }
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
}
