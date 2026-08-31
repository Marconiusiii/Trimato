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
        trackID = controller.activeTimelineTrack?.kind == .video ? controller.activeTimelineTrackID : defaultCompatibleTrackID
    }

    var compatibleTracks: [TimelineTrack] {
        controller?.project.orderedTimelineTracks.filter { $0.kind == definition.kind.trackKind } ?? []
    }

    // Changing the presentation order must not change the existing default destination.
    private var defaultCompatibleTrackID: UUID? {
        controller?.project.tracks.first { $0.kind == definition.kind.trackKind }?.id
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
        cancelPreparation()
        if previous.kind != definition.kind, !compatibleTracks.contains(where: { $0.id == trackID }) {
            trackID = defaultCompatibleTrackID
        }
    }

    func cancelPreparation() {
        operation?.cancel()
        operation = nil
        if progress != nil { progress = nil }
    }

    func prepare(placement: PlacementAction, onTop: Bool = false, finished: @escaping () -> Void = {}) {
        guard let controller else { errorMessage = "The project is no longer open."; return }
        cancelPreparation()
        guard durationValue.isFinite, durationValue > 0,
              durationValue <= (usesFrames ? 86400 * definition.frameRate : 86400),
              !usesFrames || durationValue.rounded() == durationValue else {
            errorMessage = "Enter a positive duration no longer than 24 hours. Frame counts must be whole numbers."
            return
        }
        let expected = controller.project
        var definition = definition
        definition.duration = ProjectTime(seconds: usesFrames ? durationValue / definition.frameRate : durationValue)
        if definition.kind == .text, let error = definition.textTypographyError {
            errorMessage = error
            return
        }
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
                _ = try await GeneratorRenderer.ensure(definition) { [weak self] value in self?.progress = value }
                try Task.checkCancellation()
                if let editing {
                    try controller.updateGenerator(definition, editing: editing, expectedProject: expected)
                } else {
                    try controller.placeGenerator(definition, placement: placement, at: playhead,
                                                  trackID: destination, newTrackName: name, expectedProject: expected)
                }
                progress = nil
                operation = nil
                finished()
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
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generator")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text("Destination playhead: \(ProjectPlayerViewModel.accessibilityTimeLabel(time: session.playhead, showingFrames: false, frameRate: session.definition.frameRate))")

            Form {
                Picker("Generator", selection: $session.definition.kind) {
                    ForEach(GeneratorKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .help(session.definition.kind.description)
                .disabled(session.editing != nil)

                generatorParameters

                Picker("Duration Units", selection: Binding(
                    get: { session.durationUnit },
                    set: { session.setDurationUnit($0) }
                )) {
                    ForEach(GeneratorDurationUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                TextField(session.durationUnit.fieldLabel, value: $session.durationValue, format: .number)

                if session.editing == nil {
                    Picker("Destination Track", selection: $session.trackID) {
                        ForEach(session.compatibleTracks) { track in
                            Text(track.name).tag(Optional(track.id))
                        }
                        Text("New Track").tag(UUID?.none)
                    }
                    .pickerStyle(.menu)

                    if session.trackID == nil {
                        TextField("New Track Name", text: $session.newTrackName)
                    }
                }
            }
            .disabled(session.progress != nil)

            if let progress = session.progress {
                ProgressView("Preparing Generator", value: progress)
            }
            placementControls
                .disabled(session.progress != nil)
            Button(session.progress == nil ? "Cancel" : "Cancel Preparation", role: .cancel) {
                session.cancelPreparation()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            headingFocused = true
        }
        .onChange(of: session.definition) { previous, _ in
            session.definitionChanged(from: previous)
        }
        .onDisappear {
            session.cancelPreparation()
            GeneratorWindowRegistry.shared.sessions.removeValue(forKey: session.id)
            session.controller?.requestEditorFocusRestore()
        }
        .alert("Generator Could Not Be Prepared", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var generatorParameters: some View {
        switch session.definition.kind {
        case .black:
            EmptyView()
        case .solidColor:
            Picker("Color", selection: $session.definition.color) {
                ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
            }

        case .gradient:
            Picker("First Color", selection: $session.definition.color) {
                ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
            }

            Picker("Second Color", selection: $session.definition.secondColor) {
                ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
            }

            Picker("Direction", selection: $session.definition.direction) {
                ForEach(GradientDirection.allCases) { Text($0.title).tag($0) }
            }

        case .silence:
            Picker("Channels", selection: $session.definition.channels) {
                ForEach(GeneratorChannels.allCases) { Text($0.title).tag($0) }
            }

        case .text:
            TextGeneratorControls(definition: $session.definition)
        }
    }

    @ViewBuilder
    private var placementControls: some View {
        if session.editing != nil {
            Button("Update Generator") { session.prepare(placement: .insert) { dismiss() } }
        } else {
            GroupBox("Add to Timeline") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Append") { session.prepare(placement: .append) { dismiss() } }
                    Button("Insert and Split") { session.prepare(placement: .insert) { dismiss() } }
                    Button("Insert and Overwrite") { session.prepare(placement: .replaceRemainder) { dismiss() } }
                    if session.definition.kind != .silence {
                        Button("Insert on Top in New Video Track") {
                            session.prepare(placement: .insert, onTop: true) { dismiss() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
