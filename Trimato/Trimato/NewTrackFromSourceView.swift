import SwiftUI

nonisolated enum NewTrackSourceKind: String, CaseIterable, Identifiable, Sendable {
    case video
    case audio

    var id: String { rawValue }
    var trackKind: TimelineTrackKind { self == .video ? .video : .audio }
    var commandTitle: String { self == .video ? "New Track from Video…" : "New Track from Audio…" }
    var heading: String { self == .video ? "New Track from Video" : "New Track from Audio" }

    static func availableKinds(hasVideo: Bool, hasAudio: Bool) -> [Self] {
        allCases.filter { kind in
            switch kind {
            case .video: hasVideo
            case .audio: hasAudio
            }
        }
    }

    func suggestedTrackName(sourceName: String, sourceHasVideo: Bool) -> String {
        switch self {
        case .video:
            sourceName
        case .audio:
            sourceHasVideo ? "\(sourceName) Audio" : sourceName
        }
    }
}

nonisolated struct NewTrackFromSourceRequest: Identifiable, Equatable, Sendable {
    let assetID: UUID
    let kind: NewTrackSourceKind

    var id: String { "\(assetID.uuidString)-\(kind.id)" }
}

struct NewTrackFromSourceView: View {
    let kind: NewTrackSourceKind
    let create: (String) -> Bool
    let close: () -> Void
    @Binding var presentedError: ProjectPresentedError?

    @State private var trackName: String
    @FocusState private var trackNameFocused: Bool

    init(
        kind: NewTrackSourceKind,
        suggestedTrackName: String,
        presentedError: Binding<ProjectPresentedError?>,
        create: @escaping (String) -> Bool,
        close: @escaping () -> Void
    ) {
        self.kind = kind
        self.create = create
        self.close = close
        _presentedError = presentedError
        _trackName = State(initialValue: suggestedTrackName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            LabeledContent("Track Name") {
                TextField("Track Name", text: $trackName)
                    .labelsHidden()
                    .focused($trackNameFocused)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Create Track") {
                    if create(trackName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { trackNameFocused = true }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
