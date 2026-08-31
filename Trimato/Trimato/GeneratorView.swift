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
        cancelPreparation()
        if previous.kind != definition.kind, !compatibleTracks.contains(where: { $0.id == trackID }) {
            trackID = compatibleTracks.first?.id
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
    @AccessibilityFocusState private var pickerFocus: String?
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generator")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text("Destination playhead: \(ProjectPlayerViewModel.accessibilityTimeLabel(time: session.playhead, showingFrames: false, frameRate: session.definition.frameRate))")
            VStack(alignment: .leading, spacing: 12) {
                GeneratorControlRow("Generator") {
                    Picker("", selection: restoring($session.definition.kind, "kind")) {
                        ForEach(GeneratorKind.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityFocused($pickerFocus, equals: "kind")
                    .disabled(session.editing != nil)
                }
                Text(session.definition.kind.description)
                if session.definition.kind == .text {
                    TextGeneratorControls(definition: $session.definition)
                }
                if session.definition.kind == .solidColor || session.definition.kind == .gradient {
                    GeneratorControlRow(session.definition.kind == .gradient ? "First Color" : "Color") {
                        Picker("", selection: restoring($session.definition.color, "color")) {
                            ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityFocused($pickerFocus, equals: "color")
                    }
                }
                if session.definition.kind == .gradient {
                    GeneratorControlRow("Second Color") {
                        Picker("", selection: restoring($session.definition.secondColor, "second")) {
                            ForEach(GeneratorColor.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityFocused($pickerFocus, equals: "second")
                    }
                    GeneratorControlRow("Direction") {
                        Picker("", selection: restoring($session.definition.direction, "direction")) {
                            ForEach(GradientDirection.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityFocused($pickerFocus, equals: "direction")
                    }
                }
                if session.definition.kind == .silence {
                    GeneratorControlRow("Channels") {
                        Picker("", selection: restoring($session.definition.channels, "channels")) {
                            ForEach(GeneratorChannels.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityFocused($pickerFocus, equals: "channels")
                    }
                }
                GroupBox("Duration") {
                    VStack(alignment: .leading) {
                        GeneratorControlRow("Duration Units") {
                            Picker("", selection: restoring(Binding(
                                get: { session.durationUnit },
                                set: { session.setDurationUnit($0) }
                            ), "durationUnits")) {
                                ForEach(GeneratorDurationUnit.allCases) { unit in
                                    Text(unit.title).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityFocused($pickerFocus, equals: "durationUnits")
                        }

                        GeneratorControlRow(session.durationUnit.fieldLabel) {
                            TextField("", value: $session.durationValue, format: .number)
                        }
                    }
                }
                if session.editing == nil {
                    GeneratorControlRow("Destination Track") {
                        Picker("", selection: restoring($session.trackID, "track")) {
                            ForEach(session.compatibleTracks) { Text($0.name).tag(Optional($0.id)) }
                            Text("New Track").tag(UUID?.none)
                        }.labelsHidden().accessibilityFocused($pickerFocus, equals: "track")
                    }
                    if session.trackID == nil {
                        GeneratorControlRow("New Track Name") {
                            TextField("", text: $session.newTrackName)
                        }
                    }
                }
            }
            if let progress = session.progress { ProgressView("Preparing Generator", value: progress) }
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
            Button(session.progress == nil ? "Cancel" : "Cancel Preparation", role: .cancel) {
                session.cancelPreparation()
                dismiss()
            }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            headingFocused = true
            // Window activation can finish after the view appears. Retry only during opening,
            // and do not take focus back from a picker the user has already reached.
            for delay in [200, 350] {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                guard pickerFocus == nil else { return }
                headingFocused = true
            }
        }
        .onChange(of: session.definition) { previous, _ in
            session.definitionChanged(from: previous)
        }
        .onDisappear {
            session.cancelPreparation()
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

/// Connect the visible label to the native control without replacing its role or value.
/// Keep the native element: combining these macOS field rows discards their role and value.
struct GeneratorControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @Namespace private var labelPair

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: "control", in: labelPair)
            content()
                .accessibilityLabeledPair(role: .content, id: "control", in: labelPair)
        }
    }
}
