import SwiftUI

struct StandaloneClipEditorView: View {
    let url: URL
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var loadedURL: URL?

    var body: some View {
        MacEditorPane("Clip Editor") {
            ContentView(viewModel: viewModel, allowsFileOpening: false)
        }
        .focusedObject(viewModel)
        .navigationTitle("\(url.deletingPathExtension().lastPathComponent) — Clip Editor")
        .frame(minWidth: 700, minHeight: 600)
        .onAppear {
            guard loadedURL != url else { return }
            loadedURL = url
            viewModel.load(url: url)
        }
    }
}
