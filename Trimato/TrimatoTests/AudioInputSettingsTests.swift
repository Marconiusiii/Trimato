import Foundation
import Testing
@testable import Trimato

@Suite("Audio input settings")
@MainActor
struct AudioInputSettingsTests {
    @Test func inputAndOutputChoicesRemainIndependentAndPersistent() throws {
        let name = "AudioSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let routes = AudioOutputManager(defaults: defaults, observeHardware: false)
        let input = AudioInputManager(defaults: defaults, routes: routes)
        #expect(input.selectedUID == "")
        #expect(routes.selectedUID == "")
        #expect(input.bitDepth == 24)
        input.selectedUID = "microphone"
        input.channel = 2
        input.bitDepth = 16
        #expect(defaults.string(forKey: AppPreferenceKey.audioInputDevice) == "microphone")
        #expect(defaults.integer(forKey: AppPreferenceKey.audioInputChannel) == 2)
        #expect(routes.selectedUID == "")
        let reopened = AudioInputManager(defaults: defaults, routes: routes)
        #expect(reopened.selectedUID == "microphone")
        #expect(reopened.channel == 2)
        #expect(reopened.bitDepth == 16)
        reopened.selectedUID = "other microphone"
        #expect(reopened.channel == 0)
    }
}
