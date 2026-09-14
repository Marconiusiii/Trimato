import Foundation
import Testing
@testable import Trimato

@MainActor
struct ContextualHelpTests {
    @Test func contextualTopicIsBundledAndLinked() throws {
        let helpURL = try #require(Bundle.main.url(forResource: "Trimato", withExtension: "help"))
        let help = try #require(Bundle(url: helpURL))
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String == TrimatoHelp.bookName)
        #expect(help.bundleIdentifier == TrimatoHelp.bookName)
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
        let indexURL = try #require(help.url(forResource: "Trimato", withExtension: "helpindex"))
        #expect(try Data(contentsOf: indexURL).count > 0)
    }
}
