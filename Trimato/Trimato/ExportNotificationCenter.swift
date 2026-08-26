import OSLog
import UserNotifications

nonisolated enum ExportNotificationAuthorizationState: Equatable {
    case loading
    case notRequested
    case allowed
    case denied
    case unavailable

    static func resolve(_ status: UNAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined:
            .notRequested
        case .authorized, .provisional, .ephemeral:
            .allowed
        case .denied:
            .denied
        @unknown default:
            .unavailable
        }
    }

    var statusText: String {
        switch self {
        case .loading:
            "Checking"
        case .notRequested:
            "Not requested"
        case .allowed:
            "Allowed"
        case .denied:
            "Not allowed"
        case .unavailable:
            "Unavailable"
        }
    }

    var explanation: String {
        switch self {
        case .loading:
            "Checking whether Trimato may send export notifications."
        case .notRequested:
            "Allow Trimato to send a system notification containing the filename after a successful export."
        case .allowed:
            "Trimato may send a system notification containing the filename after a successful export."
        case .denied:
            "To receive export notifications, open System Settings, choose Notifications, choose Trimato, and turn on Allow Notifications."
        case .unavailable:
            "Trimato could not read the current notification permission."
        }
    }
}

@MainActor
enum ExportNotificationCenter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.marconius.trimato",
        category: "ExportNotifications"
    )

    static func authorizationState() async -> ExportNotificationAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return ExportNotificationAuthorizationState.resolve(settings.authorizationStatus)
    }

    @discardableResult
    static func requestAuthorizationIfNeeded() async -> ExportNotificationAuthorizationState {
        let currentState = await authorizationState()
        guard currentState == .notRequested else { return currentState }

        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return await authorizationState()
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    static func postExportCompleted(filename: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional else { return }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content(filename: filename),
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    static func content(filename: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Export complete"
        content.body = "Trimato has completed exporting \(filename)."
        content.sound = .default
        return content
    }
}
