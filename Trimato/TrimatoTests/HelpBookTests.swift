import AppKit
import Foundation
import Testing
@testable import Trimato

struct HelpBookTests {
    @Test func quickStartPageAndHelpRegistrationUseTheSameAnchorAndBook() throws {
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

        #expect(helpInfo["CFBundleIdentifier"] as? String == TrimatoHelp.bookIdentifier)
        #expect(helpInfo["CFBundleShortVersionString"] as? String == "1.4.0")
        #expect(appInfo["CFBundleHelpBookName"] as? String == TrimatoHelp.bookIdentifier)
        #expect(indexPage.contains(
            "<meta name=\"AppleTitle\" content=\"\(TrimatoHelp.bookIdentifier)\">"
        ))
        #expect((helpInfo["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0 > 9)
        #expect(quickStart.contains("<a name=\"\(TrimatoHelp.quickStartAnchor)\"></a>"))
        #expect(TrimatoHelp.quickStartDestination == TrimatoHelp.Destination(
            book: "com.marconius.trimato.help",
            page: "quickstart.html",
            anchor: "trimato-quickstart-guide"
        ))
        #expect(quickStart.contains("<h1 id=\"trimato-quickstart\">Trimato QuickStart guide</h1>"))
        #expect(quickStart.contains("<link rel=\"stylesheet\" href=\"trimato-help.css\">"))
        #expect(!indexPage.contains("getting-started.html"))
        #expect(!FileManager.default.fileExists(atPath: helpBundle.appendingPathComponent(
            "Contents/Resources/en.lproj/getting-started.html"
        ).path))
    }

    @Test @MainActor func builtApplicationRegistersItsHelpBook() throws {
        #expect(NSHelpManager.shared.registerBooks(in: .main))
        let helpBookURL = try #require(
            Bundle.main.url(forResource: "Trimato", withExtension: "help")
        )
        let helpBundle = try #require(Bundle(url: helpBookURL))
        let pageURL = try #require(
            helpBundle.url(forResource: "quickstart", withExtension: "html")
        )
        #expect(pageURL.lastPathComponent == TrimatoHelp.quickStartDestination.page)
    }
}
