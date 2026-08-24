import SwiftUI

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: asset) == nil {
                Text("This media file is offline. Relink it before editing.")
            } else {
                ContentView(viewModel: viewModel, allowsFileOpening: false)

                HStack {
                    Button(PlacementAction.append.title) { place(.append) }
                        .keyboardShortcut("e", modifiers: [])
                    Button(PlacementAction.insert.title) { place(.insert) }
                        .keyboardShortcut("w", modifiers: [])
                    Button(PlacementAction.replaceRemainder.title) { place(.replaceRemainder) }
                        .keyboardShortcut("d", modifiers: [])
                    Menu("Insert on Top") {
                        Button("With Source Audio") { place(.cutawaySourceAudio) }
                            .keyboardShortcut("q", modifiers: [])
                        Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                            .keyboardShortcut("q", modifiers: [.option])
                    }
                }
                .disabled(viewModel.projectSourceSegments.isEmpty)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            viewModel.scopeKeyboardCommands { [weak commandContext] in
                commandContext?.isKeyWindow == true
            }
            loadIfNeeded()
        }
        .onChange(of: viewModel.projectSourceSegments) { segments in
            guard loadedAssetID == asset.id, !segments.isEmpty else { return }
            commandContext.segments = segments
            controller.updateEditSegments(for: editSelection, segments: segments)
        }
        .onDisappear { viewModel.closeMedia() }
    }

    private func loadIfNeeded() {
        guard loadedAssetID != asset.id, let url = controller.resolveURL(for: asset) else { return }
        loadedAssetID = asset.id
        commandContext.segments = initialSegments
        viewModel.load(
            url: url,
            sourceSegments: initialSegments,
            preparedSource: controller.preparedMediaSource(for: asset)
        )
    }

    private func place(_ placement: PlacementAction) {
        commandContext.place(placement)
    }
}
