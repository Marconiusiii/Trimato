import SwiftUI

struct AudioWaveformView: View {
    let samples: [Float]
    let playbackFraction: Double
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                EditorTheme.workspace

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
                        with: .color(EditorTheme.accent.opacity(0.9)),
                        lineWidth: max(size.width / CGFloat(count), 1)
                    )
                }

                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 1)

                if isLoading, samples.isEmpty {
                    ProgressView("Preparing waveform")
                        .controlSize(.small)
                } else if samples.isEmpty {
                    Text("Waveform unavailable")
                        .foregroundStyle(.secondary)
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .position(
                        x: min(max(playbackFraction, 0), 1) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
