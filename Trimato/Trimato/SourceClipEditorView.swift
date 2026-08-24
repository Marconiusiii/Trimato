import SwiftUI

struct SourceClipEditorView: View {
    @ObservedObject var controller: ProjectController
    let asset: MediaAssetRecord
    let editSelection: EditorSelection
    let initialSegments: [SourceSegment]
    @ObservedObject var commandContext: ClipPlacementCommandContext

    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedAssetID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    @State private var cacheOwnerID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.resolveURL(for: asset) == nil {
                Text("This media file is offline. Relink it before editing.")
            } else {
                ContentView(viewModel: viewModel, allowsFileOpening: false)

                HStack {
                    if commandContext.isTimelineEntry {
                        Button("Update Clip") { commandContext.performUpdate() }
                            .keyboardShortcut("u", modifiers: .command)
                            .disabled(!commandContext.canUpdate)
                        Divider()
                    }
                    Button(PlacementAction.append.title) { place(.append) }
                        .keyboardShortcut("e", modifiers: [])
                        .disabled(!commandContext.canPlace)
                    Button(PlacementAction.insert.title) { place(.insert) }
                        .keyboardShortcut("w", modifiers: [])
                        .disabled(!commandContext.canPlace)
                    Button(PlacementAction.replaceRemainder.title) { place(.replaceRemainder) }
                        .keyboardShortcut("d", modifiers: [])
                        .disabled(!commandContext.canPlace)
                    Menu("Insert on Top") {
                        Button("With Source Audio") { place(.cutawaySourceAudio) }
                            .keyboardShortcut("q", modifiers: [])
                        Button("Over Primary Audio") { place(.cutawayPrimaryAudio) }
                            .keyboardShortcut("q", modifiers: [.option])
                    }
                    .disabled(!commandContext.canPlace)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if let cacheKey = asset.proxyCacheKey {
                let owner = cacheOwnerID
                Task {
                    await MediaCacheManager.shared.updateProtectedKeys(owner: owner, keys: [cacheKey])
                }
            }
            viewModel.scopeKeyboardCommands { [weak commandContext] in
                commandContext?.isKeyWindow == true
            }
            loadIfNeeded()
        }
        .onChange(of: viewModel.placementSourceSegments) { segments in
            guard loadedAssetID == asset.id else { return }
            commandContext.setSegments(segments)
        }
        .onDisappear {
            preparationTask?.cancel()
            preparationTask = nil
            viewModel.closeMedia()
            let owner = cacheOwnerID
            Task { await MediaCacheManager.shared.releaseProtectedKeys(owner: owner) }
        }
    }

    private func loadIfNeeded() {
        guard loadedAssetID != asset.id, let url = controller.resolveURL(for: asset) else { return }
        loadedAssetID = asset.id
        commandContext.setSegments(initialSegments)
        let opening = ClipEditorOpeningConfiguration.make(
            segments: initialSegments,
            sourceDuration: asset.duration
        )
        preparationTask = Task { @MainActor in
            do {
                let source = try await controller.preparedMediaSource(for: asset)
                try Task.checkCancellation()
                if let cacheKey = controller.project.asset(id: asset.id)?.proxyCacheKey {
                    await MediaCacheManager.shared.updateProtectedKeys(
                        owner: cacheOwnerID,
                        keys: [cacheKey]
                    )
                }
                viewModel.load(
                    url: url,
                    sourceSegments: opening.playbackSegments,
                    preparedSource: source,
                    initialInMarker: opening.inMarker,
                    initialOutMarker: opening.outMarker
                )
            } catch is CancellationError {
                return
            } catch {
                loadedAssetID = nil
                controller.presentedError = ProjectPresentedError(
                    title: "Clip Preparation Failed",
                    message: error.localizedDescription
                )
            }
            preparationTask = nil
        }
    }

    private func place(_ placement: PlacementAction) {
        commandContext.place(placement)
    }
}
