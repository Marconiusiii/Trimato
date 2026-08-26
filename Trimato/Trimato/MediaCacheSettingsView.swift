import AppKit
import Combine
import SwiftUI

@MainActor
final class ExportNotificationSettingsModel: ObservableObject {
    @Published private(set) var state: ExportNotificationAuthorizationState = .loading
    @Published private(set) var isRequesting = false

    func refresh() {
        Task { @MainActor in
            state = await ExportNotificationCenter.authorizationState()
        }
    }

    func requestAuthorization() {
        guard !isRequesting else { return }
        isRequesting = true
        Task { @MainActor in
            state = await ExportNotificationCenter.requestAuthorizationIfNeeded()
            isRequesting = false
        }
    }
}

@MainActor
final class MediaCacheSettingsModel: ObservableObject {
    @Published private(set) var status: MediaCacheStatus?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    func refresh() {
        Task { @MainActor in
            do {
                status = try await MediaCacheManager.shared.status()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clear(_ scope: MediaCacheClearScope) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            do {
                let result = try await MediaCacheManager.shared.clear(scope)
                status = try await MediaCacheManager.shared.status()
                let retained = result.retainedActiveFileCount
                announce(retained == 0
                    ? "Media cache cleared"
                    : "Media cache cleared. Media for open projects was retained")
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct MediaCacheSettingsView: View {
    @StateObject private var notificationModel = ExportNotificationSettingsModel()
    @StateObject private var model = MediaCacheSettingsModel()
    @State private var confirmation: CacheConfirmation?

    var body: some View {
        Form {
            Section("Export Notifications") {
                LabeledContent("Permission", value: notificationModel.state.statusText)
                Text(notificationModel.state.explanation)
                    .foregroundStyle(.secondary)

                if notificationModel.state == .notRequested {
                    Button("Allow Export Notifications…") {
                        notificationModel.requestAuthorization()
                    }
                    .disabled(notificationModel.isRequesting)
                }
            }

            Section("Media Cache") {
                LabeledContent("Current size", value: formattedSize)
                LabeledContent("Automatic limit", value: "10 GB")
                LabeledContent("Location", value: "macOS Caches")
                Text("Playback proxies are stored in macOS Caches. Original media and Trimato projects are never removed.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Clear Unused Media Cache…") {
                        confirmation = .unused
                    }
                    Button("Clear All Media Cache…") {
                        confirmation = .all
                    }
                    Spacer()
                    if model.isWorking {
                        ProgressView("Clearing Media Cache")
                            .controlSize(.small)
                    }
                }
                .disabled(model.isWorking)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .onAppear {
            notificationModel.refresh()
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationModel.refresh()
        }
        .alert(item: $confirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.actionTitle)) {
                    model.clear(confirmation.scope)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Media Cache Could Not Be Changed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { presented in if !presented { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "The media cache could not be changed.")
        }
    }

    private var formattedSize: String {
        guard let status = model.status else { return "Calculating" }
        return ByteCountFormatter.string(fromByteCount: status.byteCount, countStyle: .file)
    }
}

private enum CacheConfirmation: String, Identifiable {
    case unused
    case all

    var id: String { rawValue }
    var scope: MediaCacheClearScope { self == .unused ? .unused : .all }

    var title: String {
        self == .unused ? "Clear Unused Media Cache?" : "Clear All Media Cache?"
    }

    var actionTitle: String {
        self == .unused ? "Clear Unused" : "Clear All"
    }

    var message: String {
        switch self {
        case .unused:
            "Playback proxies not used in the last seven days will be removed. Original media and Trimato projects will not be changed."
        case .all:
            "All playback proxies not required by open projects will be removed. Original media and Trimato projects will not be changed."
        }
    }
}
