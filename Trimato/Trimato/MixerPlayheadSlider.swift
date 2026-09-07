import SwiftUI

struct MixerPlayheadSlider: View {
    @Binding var value: Double
    let step: Double
    let timecode: String

    var body: some View {
        // An inline Slider label makes macOS lay out labels for its frame steps.
        // Native LabeledContent keeps the label associated without that work.
        LabeledContent("Project playhead") {
            Slider(value: $value, in: 0...1, step: step)
                .accessibilityValue(timecode)
        }
    }
}
