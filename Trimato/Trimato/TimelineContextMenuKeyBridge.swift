import Foundation

nonisolated enum TimelineElementAccessibilityIdentifier {
    private static let clipPrefix = "trimato.timeline.clip."
    private static let transitionPrefix = "trimato.timeline.transition."

    static func clip(_ id: UUID) -> String {
        clipPrefix + id.uuidString
    }

    static func transition(_ id: UUID) -> String {
        transitionPrefix + id.uuidString
    }

    static func selection(from identifier: String?) -> TimelineElementSelection? {
        guard let identifier else { return nil }
        if identifier.hasPrefix(clipPrefix),
           let id = UUID(uuidString: String(identifier.dropFirst(clipPrefix.count))) {
            return .clip(id)
        }
        if identifier.hasPrefix(transitionPrefix),
           let id = UUID(uuidString: String(identifier.dropFirst(transitionPrefix.count))) {
            return .transition(id)
        }
        return nil
    }
}
