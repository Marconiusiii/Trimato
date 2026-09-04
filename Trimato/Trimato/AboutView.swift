import AppKit
import SwiftUI

enum AboutInformation {
    static let copyright = "© 2026 Marco Salsiccia"
    static let ffmpegAcknowledgment = "Includes FFmpeg 8.1.2, licensed under the GNU Lesser General Public License version 2.1 or later."

    static func versionText(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
}

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            Text("Trimato")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text(AboutInformation.versionText())
                .foregroundStyle(.secondary)

            Text(AboutInformation.copyright)

            Divider()

            Text(AboutInformation.ffmpegAcknowledgment)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Link("Visit the FFmpeg website", destination: URL(string: "https://ffmpeg.org/")!)

            Link("Privacy policy", destination: URL(string: "https://marconius.com/trimato/privacy/")!)

            Button("View FFmpeg License") {
                openWindow(id: "ffmpeg-license")
            }
        }
        .frame(width: 420)
        .padding(28)
        .tint(EditorTheme.accent)
        .background(EditorTheme.controlSurface)
        .preferredColorScheme(.dark)
    }
}

struct FFmpegLicenseView: View {
    private let licenseText: String = {
        guard let url = Bundle.main.url(forResource: "COPYING.LGPLv2.1", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled FFmpeg license could not be loaded."
        }
        return text
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FFmpeg License")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(20)

            Divider()

            ScrollView {
                Text(licenseText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(EditorTheme.workspace)
        .preferredColorScheme(.dark)
    }
}
