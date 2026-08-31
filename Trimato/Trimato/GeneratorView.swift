import AVFoundation
import Combine
import SwiftUI

nonisolated enum GeneratorDurationUnit: String, CaseIterable, Identifiable {
    case seconds, frames

    var id: Self { self }
    var title: String { self == .seconds ? "Seconds" : "Frames" }
    var fieldLabel: String { "Duration in \(title)" }
}

@MainActor
final class GeneratorWindowRegistry {
    static let shared = GeneratorWindowRegistry()
    var sessions: [UUID: GeneratorSession] = [:]
}

@MainActor
final class GeneratorSession: ObservableObject, Identifiable {
    let id = UUID()
    weak var controller: ProjectController?
    let playhead: ProjectTime
    let editing: EditorSelection?
    @Published var definition = GeneratorDefinition()
    @Published var trackID: UUID?
    @Published var newTrackName = "Generator"
    @Published var durationValue = 5.0
    @Published private(set) var durationUnit: GeneratorDurationUnit = .seconds
    var usesFrames: Bool { durationUnit == .frames }
    @Published var progress: Double?
    @Published var errorMessage: String?
    @Published var previewReady = false
    let player = AVPlayer()
    private var operation: Task<Void, Never>?

    init(controller: ProjectController, editing: EditorSelection? = nil) {
        self.editing = editing
        self.controller = controller
        let names = Set(controller.project.tracks.map(\.name))
        var suffix = 1
        while names.contains(suffix == 1 ? "Generator" : "Generator \(suffix)") { suffix += 1 }
        newTrackName = suffix == 1 ? "Generator" : "Generator \(suffix)"
        playhead = controller.timelinePlayhead
        definition.width = controller.project.format.width ?? 1920
        definition.height = controller.project.format.height ?? 1080
        definition.frameRate = controller.project.format.frameRate ?? 30
        if let editing, let saved = controller.asset(for: editing)?.generator {
            definition = saved
            durationValue = controller.segments(for: editing)?.reduce(0) { $0 + $1.duration.seconds } ?? saved.duration.seconds
        }
        trackID = controller.activeTimelineTrack?.kind == .video ? controller.activeTimelineTrackID : compatibleTracks.first?.id
    }

    var compatibleTracks: [TimelineTrack] {
        controller?.project.tracks.filter { $0.kind == definition.kind.trackKind } ?? []
    }

    func setDurationUnit(_ unit: GeneratorDurationUnit) {
        guard unit != durationUnit else { return }
        if unit == .frames {
            let converted = (durationValue * definition.frameRate).rounded()
            durationValue = durationValue > 0 ? max(1, converted) : converted
        } else {
            durationValue /= definition.frameRate
        }
        durationUnit = unit
    }

    func definitionChanged(from previous: GeneratorDefinition) {
        guard previous != definition else { return }
        stop()
        if previewReady { previewReady = false }
        if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
        if previous.kind != definition.kind, !compatibleTracks.contains(where: { $0.id == trackID }) {
            trackID = compatibleTracks.first?.id
        }
    }

    func stop() {
        operation?.cancel()
        operation = nil
        if progress != nil { progress = nil }
        player.pause()
    }

    func prepare(placement: PlacementAction? = nil, onTop: Bool = false, finished: @escaping () -> Void = {}) {
        guard let controller else { errorMessage = "The project is no longer open."; return }
        stop()
        guard durationValue.isFinite, durationValue > 0,
              durationValue <= (usesFrames ? 86400 * definition.frameRate : 86400),
              !usesFrames || durationValue.rounded() == durationValue else {
            errorMessage = "Enter a positive duration no longer than 24 hours. Frame counts must be whole numbers."
            return
        }
        let expected = controller.project
        var definition = definition
        definition.duration = ProjectTime(seconds: usesFrames ? durationValue / definition.frameRate : durationValue)
        do { try definition.validate() } catch { errorMessage = error.localizedDescription; return }
        let destination = onTop ? nil : trackID
        var name = newTrackName
        if onTop {
            let names = Set(controller.project.tracks.map(\.name))
            var suffix = 1
            while names.contains(suffix == 1 ? "Generator" : "Generator \(suffix)") { suffix += 1 }
            name = suffix == 1 ? "Generator" : "Generator \(suffix)"
        }
        progress = 0
        operation = Task { @MainActor in
            do {
                let url = try await GeneratorRenderer.ensure(definition) { [weak self] value in self?.progress = value }
                try Task.checkCancellation()
                if let placement {
                    if let editing {
                        try controller.updateGenerator(definition, editing: editing, expectedProject: expected)
                    } else {
                    try controller.placeGenerator(definition, placement: placement, at: playhead,
                                                  trackID: destination, newTrackName: name, expectedProject: expected)
                    }
                    progress = nil
                    finished()
                } else {
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    previewReady = true
                    progress = nil
                    player.play()
                }
            } catch is CancellationError {
                return
            } catch {
                progress = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct GeneratorView: View {
    @ObservedObject var session: GeneratorSession
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var pickerFocus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generator").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Destination playhead: \(session.playhead.seconds, specifier: "%.3f") seconds")
            Form {
                Picker("Generator", selection: restoring($session.definition.kind, "kind")) {
                    ForEach(GeneratorKind.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityFocused($pickerFocus, equals: "kind")
                .disabled(session.editing != nil)
                Text(session.definition.kind.description)
                if session.definition.kind == .solidColor || session.definition.kind == .gradient {
                    Picker(session.definition.kind == .gradient ? "First Color" : "Color", selection: restoring($session.definition.color, "color")) {
                        ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityFocused($pickerFocus, equals: "color")
                }
                if session.definition.kind == .gradient {
                    Picker("Second Color", selection: restoring($session.definition.secondColor, "second")) {
                        ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
                    }.accessibilityFocused($pickerFocus, equals: "second")
                    Picker("Direction", selection: restoring($session.definition.direction, "direction")) {
                        ForEach(GradientDirection.allCases) { Text($0.title).tag($0) }
                    }.accessibilityFocused($pickerFocus, equals: "direction")
                }
                if session.definition.kind == .silence {
                    Picker("Channels", selection: restoring($session.definition.channels, "channels")) {
                        ForEach(GeneratorChannels.allCases) { Text($0.title).tag($0) }
                    }.accessibilityFocused($pickerFocus, equals: "channels")
                }
                GroupBox("Duration") {
                    VStack(alignment: .leading) {
                        Picker("Duration Units", selection: restoring(Binding(
                            get: { session.durationUnit },
                            set: { session.setDurationUnit($0) }
                        ), "durationUnits")) {
                            ForEach(GeneratorDurationUnit.allCases) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityFocused($pickerFocus, equals: "durationUnits")

                        LabeledContent(session.durationUnit.fieldLabel) {
                            TextField(session.durationUnit.fieldLabel, value: $session.durationValue, format: .number)
                                .labelsHidden()
                        }
                    }
                }
                if session.editing == nil {
                    Picker("Destination Track", selection: restoring($session.trackID, "track")) {
                        ForEach(session.compatibleTracks) { Text($0.name).tag(Optional($0.id)) }
                        Text("New Track").tag(UUID?.none)
                    }.accessibilityFocused($pickerFocus, equals: "track")
                    if session.trackID == nil {
                        LabeledContent("New Track Name") {
                            TextField("New Track Name", text: $session.newTrackName)
                                .labelsHidden()
                        }
                    }
                }
            }
            .formStyle(.columns)
            if session.previewReady, session.definition.kind != .silence {
                VideoPlayerView(player: session.player).frame(height: 150).accessibilityHidden(true)
            }
            if let progress = session.progress { ProgressView("Preparing Generator", value: progress) }
            HStack {
                Button("Preview") { session.prepare() }.disabled(session.progress != nil)
                Button("Stop") { session.stop() }
            }
            if session.editing != nil {
                Button("Update Generator") { place(.insert) }.disabled(session.progress != nil)
            } else {
                GroupBox("Add to Timeline") {
                    VStack(alignment: .leading) {
                        Button("Append") { place(.append) }
                        Button("Insert and Split") { place(.insert) }
                        Button("Insert and Overwrite") { place(.replaceRemainder) }
                        if session.definition.kind != .silence {
                            Button("Insert on Top in New Video Track") {
                                session.prepare(placement: .insert, onTop: true) { dismiss() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(session.progress != nil)
            }
            Button("Cancel", role: .cancel) { session.stop(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: session.definition) { previous, _ in
            session.definitionChanged(from: previous)
        }
        .onDisappear {
            session.stop()
            GeneratorWindowRegistry.shared.sessions.removeValue(forKey: session.id)
            session.controller?.requestEditorFocusRestore()
        }
        .alert("Generator Could Not Be Prepared", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }

    private func place(_ action: PlacementAction) { session.prepare(placement: action) { dismiss() } }

    private func restoring<T>(_ binding: Binding<T>, _ key: String) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            pickerFocus = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pickerFocus = key }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { pickerFocus = key }
        })
    }
}
