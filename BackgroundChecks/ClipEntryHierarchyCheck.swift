import AppKit
import SwiftUI
import AVFoundation
@testable import Trimato

@MainActor final class EntryState: ObservableObject {
    @Published var handoffPending = true
}
struct EntryHost: View {
    @ObservedObject var state: EntryState
    let player: VideoPlayerViewModel
    var body: some View {
        ContentView(viewModel: player, editorHeading: "Video Clip Editor", compact: true,
                    isPreparingSource: state.handoffPending)
    }
}
@main struct ClipEntryHierarchyCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        UserDefaults.standard.setVolatileDomain([AppPreferenceKey.timecodeFeedback: "onDemand"], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-entry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("silent.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=1", "-c:v", "prores_ks", "-an", url.path])
        let player = VideoPlayerViewModel()
        player.player.isMuted = true
        let state = EntryState()
        let host = NSHostingView(rootView: EntryHost(state: state, player: player).environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var previous = ""
        func snapshot(_ phase: String) {
            host.layoutSubtreeIfNeeded()
            precondition(!window.isVisible && !window.isKeyWindow && !app.isActive && player.player.rate == 0)
            var seen = Set<ObjectIdentifier>(), rows: [String] = [], sliders: [NSObject] = []
            func read(_ o: NSObject, _ key: String) -> Any? {
                o.responds(to: NSSelectorFromString(key)) ? o.value(forKey: key) : nil
            }
            func walk(_ o: NSObject, _ depth: Int) {
                guard depth < 20, seen.insert(ObjectIdentifier(o)).inserted else { return }
                let role = read(o, "accessibilityRole") as? String ?? "?"
                let value = read(o, "accessibilityValue")
                let label = read(o, "accessibilityLabel")
                let title = read(o, "accessibilityTitle")
                if role == "AXSlider" { sliders.append(o) }
                if role == "AXStaticText" {
                    precondition(!((value as? String ?? "").isEmpty && (label as? String ?? "").isEmpty && (title as? String ?? "").isEmpty), "Empty text entered the editor hierarchy")
                }
                rows.append("\(depth) \(role) label=\(String(describing: label)) title=\(String(describing: title)) value=\(String(describing: value))")
                if let children = read(o, "accessibilityChildren") as? [NSObject] { children.forEach { walk($0, depth + 1) } }
            }
            walk(host, 0)
            precondition(sliders.count == 1, "Editor exposed multiple sliders")
            precondition(read(sliders[0], "accessibilityLabel") as? String == "Clip playhead")
            precondition(read(sliders[0], "accessibilityIdentifier") as? String == ClipEditorAccessibilityIdentifier.playhead)
            precondition(read(sliders[0], "accessibilityValue") == nil, "On Demand exposed a value")
            rows.append("RELATIONSHIPS " + AccessibilityRelationshipProbe.report(sliders[0]))
            rows.append("WINDOW FOCUS " + String(describing: window.firstResponder))
            let result = rows.joined(separator: "\n")
            if result != previous { print("PHASE \(phase)\n\(result)"); previous = result }
        }
        snapshot("before loading")
        for prepared in [false, true] {
            state.handoffPending = true
            let source: MediaSource? = prepared ? .native(url: url, asset: AVURLAsset(url: url), contentType: nil, mode: .nativePassthrough, frameTimestamps: (0..<10).map { CMTime(value: Int64($0), timescale: 10) }, hasAudio: false) : nil
            player.load(url: url, preparedSource: source)
            for _ in 0..<1000 {
                snapshot("loading prepared=\(prepared) status=\(player.mediaStatus ?? "nil")")
                if !player.isPreparingMedia { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(player.hasMedia)
            state.handoffPending = false
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); snapshot("entry ready") }
            func nativeSlider(_ view: NSView) -> NSSlider? {
                if let slider = view as? NSSlider { return slider }
                return view.subviews.lazy.compactMap(nativeSlider).first
            }
            guard let slider = nativeSlider(host) else { fatalError("Playhead not installed") }
            precondition(window.makeFirstResponder(slider) && window.firstResponder === slider)
            snapshot("prepared editor keyboard entry")
            precondition(window.makeFirstResponder(nil))
            snapshot("prepared editor keyboard focus away")
            precondition(window.makeFirstResponder(slider) && window.firstResponder === slider)
            snapshot("prepared editor keyboard return")
            player.closeMedia()
        }
        print("CHECK COMPLETE: invisible inactive window, no audio playback; native key-window/VoiceOver entry is not exercised")
    }
}
