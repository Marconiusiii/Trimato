import UserNotifications

@MainActor
enum ExportNotificationCenter {
    static func requestAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
