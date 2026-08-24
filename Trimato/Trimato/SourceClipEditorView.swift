import SwiftUI

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    let linkedNamespace: Namespace.ID

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editorHeading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if controller.resolveURL(for: asset) == nil {
                Text("This media file is offline. Relink it before editing.")
            } else {
                ContentView(viewModel: viewModel, allowsFileOpening: false)

                HStack {
                    Button("Append to Timeline") { place(.append) }
                    Button("Insert at Playhead") { place(.insert) }
                    Button("Replace Clip Remainder") { place(.replaceRemainder) }
                    Menu("Add Cutaway") {
                        Button("With Source Audio") { place(.cutawaySourceAudio) }
                        Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                    }
                }
                .disabled(viewModel.projectSourceSegments.isEmpty)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .accessibilityLinkedGroup(id: "browser-editor", in: linkedNamespace)
        .onAppear { loadIfNeeded() }
        .onChange(of: viewModel.projectSourceSegments) { segments in
            guard loadedAssetID == asset.id, !segments.isEmpty else { return }
            controller.updateEditSegments(for: editSelection, segments: segments)
        }
        .onDisappear { viewModel.closeMedia() }
    }

    private var editorHeading: String {
        switch editSelection {
        case .asset: "Source Clip Editor: \(asset.name)"
        case .timelineClip: "Timeline Clip Editor: \(asset.name)"
        case .cutaway: "Cutaway Editor: \(asset.name)"
        case .project: "Clip Editor"
        }
    }

    private func loadIfNeeded() {
        guard loadedAssetID != asset.id, let url = controller.resolveURL(for: asset) else { return }
        loadedAssetID = asset.id
        viewModel.load(url: url, sourceSegments: initialSegments)
    }

    private func place(_ placement: PlacementAction) {
        controller.placeSelectedAsset(placement, segments: viewModel.projectSourceSegments)
    }
}
