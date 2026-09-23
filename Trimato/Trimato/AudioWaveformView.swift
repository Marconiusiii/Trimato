import SwiftUI

struct AudioWaveformView: View {
    @AppStorage(AppPreferenceKey.accentColor) private var accentChoice = EditorAccent.teal
    let samples: [Float]
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                EditorTheme.workspace

                AudioWaveformDrawing(samples: samples, accent: accentChoice)
                    .equatable()

                Rectangle()
                    .fill(EditorTheme.separator)
                    .frame(height: 1)

                if !isLoading, samples.isEmpty {
                    Text("Waveform unavailable")
                        .foregroundStyle(EditorTheme.secondaryText)
                }


            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

// A static overview, independent of playback position.
private struct AudioWaveformDrawing: View, Equatable {
    let samples: [Float]
    let accent: EditorAccent
    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            var waveform = Path()
            let centerY = size.height / 2
            let count = max(samples.count, 1)
            for (index, amplitude) in samples.enumerated() {
                let x = (CGFloat(index) + 0.5) / CGFloat(count) * size.width
                let halfHeight = max(CGFloat(amplitude) * (size.height * 0.42), 1)
                waveform.move(to: CGPoint(x: x, y: centerY - halfHeight))
                waveform.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
            }
            context.stroke(
                waveform,
                with: .color(EditorTheme.accent(for: accent)),
                lineWidth: max(size.width / CGFloat(count), 1)
            )
        }
    }
}
