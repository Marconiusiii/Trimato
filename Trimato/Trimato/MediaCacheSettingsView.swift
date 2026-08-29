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
    @Published private(set) var isRefreshing = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    func refresh(announceCompletion: Bool = false) {
        guard !isRefreshing, !isWorking else { return }
        isRefreshing = true
        Task { @MainActor in
            do {
                status = try await MediaCacheManager.shared.status()
                if announceCompletion {
                    announce("Playback proxy storage updated")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func clear(_ scope: MediaCacheClearScope) {
        guard !isWorking, !isRefreshing else { return }
        isWorking = true
        Task { @MainActor in
            do {
                let result = try await MediaCacheManager.shared.clear(scope)
                status = try await MediaCacheManager.shared.status()
                let retained = result.retainedActiveFileCount
                announce(retained == 0
                    ? "Playback proxies cleared"
                    : "Playback proxies cleared. Proxies for open projects were retained")
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
            Section("Export notifications") {
                LabeledContent("Permission", value: notificationModel.state.statusText)
                Text(notificationModel.state.explanation)
                    .foregroundStyle(.secondary)

                if notificationModel.state == .notRequested {
                    Button("Allow export notifications…") {
                        notificationModel.requestAuthorization()
                    }
                    .disabled(notificationModel.isRequesting)
                }
            }

            Section("Playback proxy storage") {
                LabeledContent("Storage used", value: formattedSize)
                LabeledContent("Proxy files", value: formattedFileCount)
                LabeledContent("Storage limit", value: "10 GB")
                LabeledContent("Stored in", value: "macOS Caches")
                Text("Trimato creates a reusable playback proxy only when macOS cannot play an original file directly. Compatible media may use no proxy storage.")
                    .foregroundStyle(.secondary)
                Text("This total does not include projects, original media, exports, transition renders, audio previews, or export intermediates.")
                    .foregroundStyle(.secondary)

                Button("Refresh storage usage") {
                    model.refresh(announceCompletion: true)
                }
                .disabled(model.isRefreshing || model.isWorking)

                if model.isRefreshing {
                    ProgressView("Refreshing storage usage")
                        .controlSize(.small)
                }
            }

            Section("Manage playback proxies") {
                Button("Clear proxies not used recently…") {
                    confirmation = .unused
                }
                .disabled(model.isWorking || model.isRefreshing)
                Text("Removes playback proxies that have not been used in the last seven days.")
                    .foregroundStyle(.secondary)

                Button("Clear all playback proxies…") {
                    confirmation = .all
                }
                .disabled(model.isWorking || model.isRefreshing)
                Text("Removes every playback proxy except those required by an open project or editor.")
                    .foregroundStyle(.secondary)

                if model.isWorking {
                    ProgressView("Clearing playback proxies")
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 600)
        .onAppear {
            notificationModel.refresh()
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationModel.refresh()
            model.refresh()
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
        .alert("Playback proxy storage could not be changed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { presented in if !presented { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Playback proxy storage could not be changed.")
        }
    }

    private var formattedSize: String {
        guard let status = model.status else { return "Calculating" }
        return ByteCountFormatter.string(fromByteCount: status.byteCount, countStyle: .file)
    }

    private var formattedFileCount: String {
        guard let count = model.status?.fileCount else { return "Calculating" }
        return count == 1 ? "1 file" : "\(count.formatted()) files"
    }
}

private enum CacheConfirmation: String, Identifiable {
    case unused
    case all

    var id: String { rawValue }
    var scope: MediaCacheClearScope { self == .unused ? .unused : .all }

    var title: String {
        self == .unused ? "Clear proxies not used recently?" : "Clear all playback proxies?"
    }

    var actionTitle: String {
        self == .unused ? "Clear proxies" : "Clear all proxies"
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
