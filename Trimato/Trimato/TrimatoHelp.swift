import AppKit
import Carbon
import SwiftUI

/// Contextual topics opened in the system Help viewer.
@MainActor
enum TrimatoHelp {
    enum Topic: String, CaseIterable {
        case trimSilences = "trimato-trim-silences"
        case clipEditor = "trimato-clip-editor"
        case filters = "trimato-filters"
        case transitions = "trimato-transitions"
        case generator = "trimato-generator"
        case mixer = "trimato-mixer"
    }

    struct Destination {
        let bookIdentifier: String
        let page: String
        let pageURL: URL
    }

    enum HelpError: LocalizedError {
        case missingContent
        case mismatchedBook

        var errorDescription: String? {
            switch self {
            case .missingContent: "This copy of Trimato is missing its Help content. Reinstall the current version of Trimato."
            case .mismatchedBook: "The Help content does not match this version of Trimato. Reinstall the current version of Trimato."
            }
        }
    }

    static func destination(for topic: Topic, in application: Bundle = .main) throws -> Destination {
        guard let bookURL = application.url(forResource: "Trimato", withExtension: "help"),
              let book = Bundle(url: bookURL),
              let identifier = book.bundleIdentifier,
              let topicsURL = book.url(forResource: "HelpTopics", withExtension: "plist"),
              let topics = NSDictionary(contentsOf: topicsURL) as? [String: String],
              let page = topics[topic.rawValue],
              let pageURL = book.url(forResource: (page as NSString).deletingPathExtension,
                                     withExtension: (page as NSString).pathExtension),
              let indexName = book.object(forInfoDictionaryKey: "HPDBookIndexPath") as? String,
              book.url(forResource: (indexName as NSString).deletingPathExtension,
                       withExtension: (indexName as NSString).pathExtension) != nil else {
            throw HelpError.missingContent
        }
        guard application.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String == identifier,
              application.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == book.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              application.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                == book.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              book.object(forInfoDictionaryKey: "TrimatoHelpContentDigest") as? String != nil else {
            throw HelpError.mismatchedBook
        }
        return Destination(bookIdentifier: identifier, page: page, pageURL: pageURL)
    }

    /// Returns an actionable message if registration or the native Help request fails.
    static func open(_ topic: Topic, in application: Bundle = .main) -> String? {
        do {
            let target = try destination(for: topic, in: application)
            guard AHRegisterHelpBookWithURL(application.bundleURL as CFURL) == noErr else {
                return "Trimato could not register its Help content. Close Help and try again."
            }
            guard AHGotoPage(target.bookIdentifier as CFString, target.page as CFString,
                             topic.rawValue as CFString) == noErr else {
                return "Trimato could not open this Help topic. Close Help and try again."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Uses the same native button and Help destination in each dialog's action row.
struct ContextualHelpButton: View {
    let topic: TrimatoHelp.Topic
    @State private var errorMessage: String?

    var body: some View {
        Button("Help") { errorMessage = TrimatoHelp.open(topic) }
            .applicationMessage(errorMessage.map {
                ApplicationMessageDescriptor(title: "Help Could Not Be Opened", message: $0)
            }) { errorMessage = nil }
    }
}
