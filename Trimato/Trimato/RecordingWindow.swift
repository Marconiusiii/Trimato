import SwiftUI
import Combine

@MainActor
final class RecordingWindowRegistry: ObservableObject {
    static let shared = RecordingWindowRegistry()
    @Published var session: ProjectRecordingSession?
    var closeWindow: (() -> Void)?
    private var pendingCloseID: UUID?

    func close(id: UUID) {
        guard session?.id == id else { return }
        pendingCloseID = id
        closeWindow?()
    }

    func installCloseAction(id: UUID, action: @escaping () -> Void) {
        guard session?.id == id else { return }
        closeWindow = action
        if pendingCloseID == id { action() }
    }

    func finished(_ closing: ProjectRecordingSession) {
        guard session?.id == closing.id else { return }
        closeWindow = nil
        pendingCloseID = nil
        session = nil
        closing.close()
        if closing.controller?.recordingSession?.id == closing.id {
            closing.controller?.dismissRecording()
        }
        Task { @MainActor in
            await Task.yield()
            closing.controller?.recordingWindowDidDismiss()
        }
    }
}

struct RecordingWindowContent: View {
    let id: UUID
    @ObservedObject private var registry = RecordingWindowRegistry.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let session = registry.session, session.id == id, let coordinator = session.controller?.projectSaveCoordinator {
            RecordingWindowEditor(session: session, coordinator: coordinator)
                .navigationTitle(session.purpose.toolTitle)
                .focusedSceneValue(\.closeRecording, { session.controller?.dismissRecording() })
                .onAppear {
                    registry.installCloseAction(id: id) { dismissWindow(id: "recording", value: id) }
                }
                .onDisappear { registry.finished(session) }
        } else {
            Text("Recording session closed")
                .task { dismissWindow(id: "recording", value: id) }
        }
    }
}

private struct CloseRecordingKey: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var closeRecording: (() -> Void)? {
        get { self[CloseRecordingKey.self] }
        set { self[CloseRecordingKey.self] = newValue }
    }
}


private struct RecordingWindowEditor: View {
    let session: ProjectRecordingSession
    @ObservedObject var coordinator: ProjectWindowSaveCoordinator

    var body: some View {
        ProjectRecordingView(session: session)
            .disabled(coordinator.isConfirmingClose || coordinator.isResolvingClose)
    }
}
