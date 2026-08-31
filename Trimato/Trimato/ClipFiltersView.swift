import SwiftUI

struct ClipFiltersView: View {
    @ObservedObject var context: ClipPlacementCommandContext
    @State private var adding = false
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
        .sheet(isPresented: $adding) {
            AddClipFilterView(audio: context.audioSettings != nil, existing: context.filters.map(\.kind)) { kind in
                context.filters.append(ClipFilter(kind: kind))
                adding = false
            } cancel: { adding = false }
        }
    }
}

private struct AddClipFilterView: View {
    let audio: Bool
    let existing: [ClipFilterKind]
    let add: (ClipFilterKind) -> Void
    let cancel: () -> Void
    @State private var selection: ClipFilterKind?
    private var available: [ClipFilterKind] { ClipFilterKind.allCases.filter { $0.isAudio == audio && !existing.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Filter").font(.headline).accessibilityAddTraits(.isHeader)
            if available.isEmpty { Text("All available filters have been added to this clip.") }
            else {
                Picker("Filter", selection: Binding(get: { selection ?? available.first }, set: { value in
                    selection = value
                })) {
                    ForEach(available) { Text($0.title).tag(Optional($0)) }
                }
                Text((selection ?? available.first)?.description ?? "")
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { if let kind = selection ?? available.first { add(kind) } }
                    .keyboardShortcut(.defaultAction).disabled(available.isEmpty)
            }
        }.padding(20).frame(width: 460)
    }
}

private struct ClipFilterControls: View {
    @Binding var filter: ClipFilter
    let remove: () -> Void

    var body: some View {
        GroupBox(filter.kind.title) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable \(filter.kind.title)", isOn: $filter.enabled)
                Text(filter.kind.description)
                ForEach(filter.kind.parameters) { parameter in
                    HStack {
                        Slider(value: valueBinding(parameter), in: parameter.range, step: parameter.step) { Text(parameter.label) }
                        TextField(parameter.label, value: valueBinding(parameter), format: .number)
                            .frame(width: 95)
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
                    Toggle("Flip Horizontally", isOn: $filter.flipHorizontal)
                    Toggle("Flip Vertically", isOn: $filter.flipVertical)
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
    private func valueBinding(_ parameter: FilterParameter) -> Binding<Double> {
        Binding(get: { filter.value(parameter.id) }, set: { value in
            guard value.isFinite else { return }
            filter.values[parameter.id] = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        })
    }
}
