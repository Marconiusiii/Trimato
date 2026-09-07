import Foundation

nonisolated enum ImportedFileHandling: String, CaseIterable, Identifiable {
    case keep, move, ask
    static let preferenceKey = "importedFileHandling"
    static func preference(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .keep
    }
    var id: Self { self }
    var title: String {
        switch self {
        case .keep: "Keep in Place"
        case .move: "Move to Project"
        case .ask: "Ask Each Time"
        }
    }
}

