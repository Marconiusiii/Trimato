import AppKit

/// Contextual topics opened in the system Help viewer.
@MainActor
enum TrimatoHelp {
    enum Topic: String {
        case trimSilences = "trimato-trim-silences"
    }

    static let bookName = "com.marconius.trimato.help"

    static func open(_ topic: Topic) {
        NSHelpManager.shared.openHelpAnchor(topic.rawValue, inBook: bookName)
    }
}
