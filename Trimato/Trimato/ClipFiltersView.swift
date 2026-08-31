import SwiftUI

struct ClipFiltersView: View {
    @ObservedObject var context: ClipPlacementCommandContext
    @State private var adding = false
    @State private var pendingFilter: ClipFilter?
    @AccessibilityFocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Add Filter…") { adding = true }
                .accessibilityFocused($addFocused)
            if !context.filters.isEmpty {
                Text("Filters").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Filters process in the listed order. Disabled filters keep their settings.")
                ForEach(ClipFilterKind.allCases) { kind in
                    if let index = context.filters.firstIndex(where: { $0.kind == kind }) {
                        ClipFilterControls(filter: $context.filters[index], remove: {
                            context.filters.removeAll { $0.kind == kind }
                            addFocused = true
                        })
                    }
                }
            }
        }
        .sheet(isPresented: $adding, onDismiss: {
            // Do not start preparing a preview while the modal sheet is closing.
            if let pendingFilter {
                context.filters.append(pendingFilter)
                self.pendingFilter = nil
            }
        }) {
            AddClipFilterView(audio: context.audioSettings != nil, existing: context.filters.map(\.kind)) { filter in
                pendingFilter = filter
                adding = false
            } cancel: {
                pendingFilter = nil
                adding = false
            }
        }
    }
}

private struct AddClipFilterView: View {
    let available: [ClipFilterKind]
    let add: (ClipFilter) -> Void
    let cancel: () -> Void
    @State private var selection: ClipFilterKind
    @State private var draft: ClipFilter
    @AccessibilityFocusState private var headingFocused: Bool

    init(audio: Bool, existing: [ClipFilterKind], add: @escaping (ClipFilter) -> Void, cancel: @escaping () -> Void) {
        available = ClipFilterKind.allCases.filter { $0.isAudio == audio && !existing.contains($0) }
        let initial = available.first ?? (audio ? .tone : .brightnessContrast)
        _selection = State(initialValue: initial)
        _draft = State(initialValue: ClipFilter(kind: initial))
        self.add = add
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Filter")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            if available.isEmpty {
                Text("All available filters have been added to this clip.")
            } else {
                Form {
                    Picker("Filter", selection: $selection) {
                        ForEach(available) { Text($0.title).tag($0) }
                    }
                    Text(selection.description)
                    ClipFilterParameters(filter: $draft)
                }
                Text("Add prepares a clip preview. Choose Update Clip in the Clip Editor to save the filter to the timeline.")
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { add(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(available.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { headingFocused = true }
        .onChange(of: selection) { _, kind in draft = ClipFilter(kind: kind) }
    }
}

private struct ClipFilterControls: View {
    @Binding var filter: ClipFilter
    let remove: () -> Void

    var body: some View {
        GroupBox(filter.kind.title) {
            VStack(alignment: .leading, spacing: 10) {
                Form {
                    Toggle("Enable \(filter.kind.title)", isOn: $filter.enabled)
                    Text(filter.kind.description)
                    ClipFilterParameters(filter: $filter)
                }
                HStack {
                    Button("Reset \(filter.kind.title)") {
                        let id = filter.id
                        let enabled = filter.enabled
                        filter = ClipFilter(kind: filter.kind)
                        filter.id = id
                        filter.enabled = enabled
                    }
                    Button("Remove \(filter.kind.title)", action: remove)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shared native form rows for the draft and the applied filter.
private struct ClipFilterParameters: View {
    @Binding var filter: ClipFilter

    var body: some View {
        ForEach(filter.kind.parameters) { parameter in
            Slider(value: valueBinding(parameter), in: parameter.range, step: parameter.step) {
                Text(parameter.label)
            }
            TextField(parameter.label, value: valueBinding(parameter), format: .number)
        }
        if filter.kind == .tone {
            Toggle("Reduce low rumble", isOn: $filter.highPassEnabled)
            Toggle("Reduce high-frequency hiss", isOn: $filter.lowPassEnabled)
        }
        if filter.kind == .cropOrientation {
            Picker("Rotation Clockwise", selection: $filter.rotation) {
                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0) degrees").tag($0) }
            }
            Toggle("Flip Horizontally", isOn: $filter.flipHorizontal)
            Toggle("Flip Vertically", isOn: $filter.flipVertical)
        }
    }

    private func valueBinding(_ parameter: FilterParameter) -> Binding<Double> {
        Binding(get: { filter.value(parameter.id) }, set: { value in
            guard value.isFinite else { return }
            filter.values[parameter.id] = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        })
    }
}
