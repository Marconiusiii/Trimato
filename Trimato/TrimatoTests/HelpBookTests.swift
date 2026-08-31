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

        #expect(helpInfo["CFBundleIdentifier"] as? String == TrimatoHelp.bookIdentifier)
        #expect(appInfo["CFBundleHelpBookName"] as? String == TrimatoHelp.bookIdentifier)
        #expect((helpInfo["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0 > 8)
        #expect(quickStart.contains("<a name=\"\(TrimatoHelp.quickStartAnchor)\"></a>"))
        #expect(quickStart.contains("<h1 id=\"trimato-quickstart\">Trimato QuickStart guide</h1>"))
        #expect(quickStart.contains("<link rel=\"stylesheet\" href=\"trimato-help.css\">"))
    }
}
