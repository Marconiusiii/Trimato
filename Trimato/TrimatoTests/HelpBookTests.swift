import Foundation
import Testing
@testable import Trimato

struct HelpBookTests {
    @Test func quickStartIsLinkedFromTheIntroductionAndListedFirst() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helpBundle = projectDirectory
            .appendingPathComponent("Trimato/Trimato.help", isDirectory: true)
        let helpInfo = try #require(
            NSDictionary(contentsOf: helpBundle.appendingPathComponent("Contents/Info.plist"))
        )
        let appInfo = try #require(
            NSDictionary(contentsOf: projectDirectory.appendingPathComponent("Trimato/Info.plist"))
        )
        let quickStart = try String(
            contentsOf: helpBundle.appendingPathComponent(
                "Contents/Resources/en.lproj/quickstart.html"
            ),
            encoding: .utf8
        )
        let indexPage = try String(
            contentsOf: helpBundle.appendingPathComponent(
                "Contents/Resources/en.lproj/index.html"
            ),
            encoding: .utf8
        )

        let bookIdentifier = try #require(helpInfo["CFBundleIdentifier"] as? String)
        #expect(bookIdentifier == "com.marconius.trimato.help")
        #expect(helpInfo["CFBundleShortVersionString"] as? String == "1.3.0")
        #expect(appInfo["CFBundleHelpBookName"] as? String == bookIdentifier)
        #expect(indexPage.contains(
            "<meta name=\"AppleTitle\" content=\"\(bookIdentifier)\">"
        ))
        #expect(helpInfo["CFBundleVersion"] as? String == "13")
        #expect(quickStart.contains("<a name=\"trimato-quickstart-guide\"></a>"))
        #expect(quickStart.contains("<h1 id=\"trimato-quickstart\">Trimato QuickStart guide</h1>"))
        #expect(quickStart.contains("<link rel=\"stylesheet\" href=\"trimato-help.css\">"))
        #expect(indexPage.components(separatedBy: "href=\"quickstart.html\"").count - 1 == 2)
        let quickStartTopic = try #require(indexPage.range(
            of: "<li><a href=\"quickstart.html\">Trimato QuickStart guide</a></li>"
        ))
        let workspaceTopic = try #require(indexPage.range(
            of: "<li><a href=\"workspace.html\">Understand the workspace</a></li>"
        ))
        #expect(quickStartTopic.lowerBound < workspaceTopic.lowerBound)
        #expect(!indexPage.contains("getting-started.html"))
        #expect(!FileManager.default.fileExists(atPath: helpBundle.appendingPathComponent(
            "Contents/Resources/en.lproj/getting-started.html"
        ).path))
    }

    @Test func builtApplicationContainsTheQuickStartPage() throws {
        let helpBookURL = try #require(
            Bundle.main.url(forResource: "Trimato", withExtension: "help")
        )
        let helpBundle = try #require(Bundle(url: helpBookURL))
        let pageURL = try #require(
            helpBundle.url(forResource: "quickstart", withExtension: "html")
        )
        #expect(pageURL.lastPathComponent == "quickstart.html")
    }
}
