import SwiftUI

struct ClipFiltersView: View {
    @ObservedObject var context: ClipPlacementCommandContext
    @State private var selection: UUID?
    @State private var editing: ClipFilter?
    @State private var pending: ClipFilter?
    @StateObject private var editFilterActions = NativeModalActionRegistration()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(context.filters, selection: $selection) { filter in
                Text("\(filter.kind.title), \(filter.enabled ? "Enabled" : "Disabled")")
                    .tag(filter.id)
            }
            .accessibilityLabel("Applied Filters")
            HStack {
                Button("Edit Filter…") { editing = selectedFilter }
                    .disabled(selectedFilter == nil)
                Button("Remove Filter") {
                    guard let selection else { return }
                    context.filters.removeAll { $0.id == selection }
                    self.selection = nil
                }.disabled(selectedFilter == nil)
            }
        }
        .background(NativeModalSheetPresenter(
            isPresented: editing != nil,
            title: editing?.kind.title ?? "Edit Filter",
            primaryTitle: "Apply",
            registration: editFilterActions,
            cancel: { editing = nil },
            dismissed: finishEditingFilter
        ) {
            if let filter = editing {
                EditClipFilterView(
                    filter: filter,
                    apply: { updated in
                        pending = updated
                        editing = nil
                    },
                    cancel: { editing = nil },
                    nativeModalActions: editFilterActions
                )
            }
        })
    }

    private var selectedFilter: ClipFilter? { context.filters.first { $0.id == selection } }

    private func finishEditingFilter() {
        if let pending, let index = context.filters.firstIndex(where: { $0.id == pending.id }) {
            context.filters[index] = pending
        }
        pending = nil
    }
}

struct AddClipFilterView: View {
    let available: [ClipFilterKind]
    let add: (ClipFilter) -> Void
    let cancel: () -> Void
    let nativeModalActions: NativeModalActionRegistration
    @State private var selection: ClipFilterKind
    @State private var draft: ClipFilter
    @AccessibilityFocusState private var headingFocused: Bool

    init(
        audio: Bool,
        existing: [ClipFilterKind],
        nativeModalActions: NativeModalActionRegistration,
        add: @escaping (ClipFilter) -> Void,
        cancel: @escaping () -> Void
    ) {
        available = ClipFilterKind.allCases.filter { $0.isAudio == audio && !existing.contains($0) }
        let initial = available.first ?? (audio ? .tone : .brightnessContrast)
        _selection = State(initialValue: initial)
        _draft = State(initialValue: ClipFilter(kind: initial))
        self.add = add
        self.cancel = cancel
        self.nativeModalActions = nativeModalActions
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
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { headingFocused = true }
        .onChange(of: selection) { _, kind in draft = ClipFilter(kind: kind) }
        .nativeModalPrimaryAction(nativeModalActions, enabled: !available.isEmpty) { add(draft) }
    }
}

private struct EditClipFilterView: View {
    @State var filter: ClipFilter
    let apply: (ClipFilter) -> Void
    let cancel: () -> Void
    let nativeModalActions: NativeModalActionRegistration

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(filter.kind.title).font(.headline).accessibilityAddTraits(.isHeader)
            Form {
                Toggle("Enable \(filter.kind.title)", isOn: $filter.enabled)
                Text(filter.kind.description)
                ClipFilterParameters(filter: $filter)
            }
            Button("Reset \(filter.kind.title)") {
                let id = filter.id
                let enabled = filter.enabled
                filter = ClipFilter(kind: filter.kind)
                filter.id = id
                filter.enabled = enabled
            }
        }.padding(20).frame(width: 520)
            .nativeModalPrimaryAction(nativeModalActions) { apply(filter) }
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
