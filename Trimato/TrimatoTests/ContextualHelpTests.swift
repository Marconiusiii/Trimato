import Foundation
import Testing
@testable import Trimato

@MainActor
struct ContextualHelpTests {
    @Test func contextualTopicIsBundledAndLinked() throws {
        let helpURL = try #require(Bundle.main.url(forResource: "Trimato", withExtension: "help"))
        let help = try #require(Bundle(url: helpURL))
        for topic in TrimatoHelp.Topic.allCases {
            let destination = try TrimatoHelp.destination(for: topic)
            #expect(help.bundleIdentifier == destination.bookIdentifier)
            #expect(destination.bookIdentifier.contains(".c"))
            #expect(FileManager.default.fileExists(atPath: destination.pageURL.path))
            let content = try String(contentsOf: destination.pageURL, encoding: .utf8)
            #expect(content.contains("<a name=\"\(topic.rawValue)\"></a>"))
        }
        let pageURL = try #require(help.url(forResource: "trim-silences", withExtension: "html"))
        let page = try String(contentsOf: pageURL, encoding: .utf8)
        #expect(page.contains("<a name=\"\(TrimatoHelp.Topic.trimSilences.rawValue)\"></a>"))
        #expect(page.contains("Warning:"))
        #expect(page.contains("jump cuts"))
        #expect(page.contains("Individual removed pauses cannot currently be restored or adjusted separately."))
        for name in ["index", "clip-editor"] {
            let url = try #require(help.url(forResource: name, withExtension: "html"))
            #expect(try String(contentsOf: url, encoding: .utf8).contains("href=\"trim-silences.html\""))
        }
        let indexURL = try #require(help.url(forResource: "Trimato", withExtension: "cshelpindex"))
        #expect(try Data(contentsOf: indexURL).count > 0)
    }
}
