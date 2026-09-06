import Testing
@testable import Trimato

@Suite("Audio output routing")
struct AudioOutputRoutingTests {
    private let headphones = AudioDeviceChoice(id: "headphones", deviceID: 10, name: "Headphones", inputChannels: 0, outputChannels: 2)
    private let speakers = AudioDeviceChoice(id: "speakers", deviceID: 20, name: "Speakers", inputChannels: 0, outputChannels: 2)

    @Test func systemDefaultFollowsTheDefaultDevice() {
        #expect(AudioOutputManager.resolve(selectedUID: "", devices: [headphones, speakers], defaultID: 20) == speakers)
        #expect(AudioOutputManager.resolve(selectedUID: "", devices: [headphones, speakers], defaultID: 10) == headphones)
    }

    @Test func explicitRouteDoesNotFollowDefaultOrFallBackWhenDisconnected() {
        #expect(AudioOutputManager.resolve(selectedUID: "headphones", devices: [headphones, speakers], defaultID: 20) == headphones)
        #expect(AudioOutputManager.resolve(selectedUID: "headphones", devices: [speakers], defaultID: 20) == nil)
    }
}
