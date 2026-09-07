import AppKit
import Testing
@testable import TrimatoMediaSupport

struct MixerCommandTests {
    @Test func windowCommandsDoNotDependOnControlFocus() {
        #expect(MixerWindowCommand.resolve(keyCode: 13, modifiers: [.command]) == .close)
        #expect(MixerWindowCommand.resolve(keyCode: 1, modifiers: [.command]) == .save)
        #expect(MixerWindowCommand.resolve(keyCode: 126, modifiers: [.command, .option]) == .previousTrack)
        #expect(MixerWindowCommand.resolve(keyCode: 125, modifiers: [.command, .option]) == .nextTrack)
        // Native slider arrows, picker keys, and application Quit remain untouched.
        #expect(MixerWindowCommand.resolve(keyCode: 126, modifiers: []) == nil)
        #expect(MixerWindowCommand.resolve(keyCode: 49, modifiers: []) == nil)
        #expect(MixerWindowCommand.resolve(keyCode: 12, modifiers: [.command]) == nil)
        #expect(MixerWindowCommand.resolve(keyCode: 13, modifiers: [.command, .shift]) == nil)
    }
    @Test func trackNavigationWrapsAndHandlesTrackRemoval() {
        #expect(MixerTrackNavigation.adjacent(-1, selected: "Voice", tracks: ["Voice", "Music"]) == "Music")
        #expect(MixerTrackNavigation.adjacent(1, selected: "Music", tracks: ["Voice", "Music"]) == "Voice")
        #expect(MixerTrackNavigation.adjacent(1, selected: "Voice", tracks: ["Voice"]) == "Voice")
        #expect(MixerTrackNavigation.adjacent(1, selected: "Removed", tracks: ["Voice"]) == "Voice")
        #expect(MixerTrackNavigation.adjacent(1, selected: "Removed", tracks: []) == nil)
    }
}
