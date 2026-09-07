import AppKit
import Combine

nonisolated enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Application appearance reaches native windows, sheets, and SwiftUI without replacing views.
@MainActor
final class ApplicationAppearanceController {
    private var observation: AnyCancellable?

    func start() {
        apply()
        observation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
    }

    private func apply() {
        let choice = AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.appearance) ?? "") ?? .system
        let name: NSAppearance.Name? = switch choice {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }
}
