import AppKit
import SwiftUI
import OSLog
@testable import Trimato

@MainActor final class ComparisonState: ObservableObject {
    enum Kind: String, CaseIterable { case standard = "Standard slider", trimato = "Trimato playhead" }
    let kind: Kind
    let background: Bool
    @Published var preparing = true
    weak var slider: NSSlider?
    private(set) var entered = false
    private let logger = Logger(subsystem: "com.marconius.trimato", category: "SliderEntryComparison")
    init(_ kind: Kind, background: Bool = false) { self.kind = kind; self.background = background }
    func record(_ message: String) {
        logger.notice("\(self.kind.rawValue, privacy: .public): \(message, privacy: .public)")
    }
    func enter() async {
        await Task.yield()
        guard !entered, !preparing, let slider, let window = slider.window,
              slider.isEnabled, window.attachedSheet == nil,
              background || (window.isKeyWindow && NSApp.isActive) else {
            record("entry gate declined"); return
        }
        record("entry requesting native slider")
        guard window.makeFirstResponder(slider), window.firstResponder === slider else {
            record("entry refused"); return
        }
        entered = true
        record("entry accepted")
        if !background { ClipLoadingSpeech.post(ClipLoadingSpeech.announcement("Clip Ready", completed: true)) }
    }
}

struct ComparisonSlider: NSViewRepresentable {
    let state: ComparisonState
    let enabled: Bool
    func makeNSView(context: Context) -> NSSlider {
        let slider: NSSlider
        if state.kind == .trimato {
            let native = NativePlayheadSlider.PlayheadSlider()
            native.cell = NativePlayheadSlider.PlayheadCell()
            native.frameStep = 1.0 / 3000
            slider = native
        } else { slider = NSSlider() }
        slider.minValue = 0; slider.maxValue = 1; slider.doubleValue = 0
        slider.isContinuous = true
        slider.cell?.setAccessibilityLabel("Clip playhead")
        slider.cell?.setAccessibilityIdentifier("comparison.playhead")
        state.slider = slider
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        slider.isEnabled = enabled
        if let cell = slider.cell as? NativePlayheadSlider.PlayheadCell {
            cell.updateSpokenValue(format: { _ in "00:00" }, feedback: .whenStopped, isMoving: { false })
        }
    }
    static func dismantleNSView(_ slider: NSSlider, coordinator: ()) {
        (slider.cell as? NativePlayheadSlider.PlayheadCell)?.cancelPendingValue()
    }
}

struct ComparisonEditor: View {
    @ObservedObject var state: ComparisonState
    @FocusState private var filterFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(state.kind.rawValue).font(.title2)
            ComparisonSlider(state: state, enabled: !state.preparing).disabled(state.preparing).frame(height: 30)
            Button("Add Filter…") { }.focused($filterFocused)
            Button("Close") { state.slider?.window?.performClose(nil) }
        }
        .padding(24).frame(width: 520)
        .onChange(of: filterFocused) { _, focused in state.record("Add Filter focus=\(focused)") }
        .sheet(isPresented: Binding(get: { !state.background && state.preparing }, set: { if !state.background { state.preparing = $0 } }), onDismiss: {
            Task { @MainActor in await state.enter() }
        }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Preparing Clip").font(.headline)
                ProgressView().accessibilityLabel("Preparing Clip")
                Button("Finish Preparation") { state.preparing = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 340)
        }
    }
}

struct ComparisonLauncher: View {
    let open: (ComparisonState.Kind) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Slider Entry Comparison").font(.title2)
            Button("Open Standard Slider") { open(.standard) }.keyboardShortcut("1", modifiers: .command)
            Button("Open Trimato Playhead") { open(.trimato) }.keyboardShortcut("2", modifiers: .command)
        }.padding(24).frame(width: 420)
    }
}

@MainActor final class ComparisonApp: NSObject, NSApplicationDelegate {
    var launcher: NSWindow?
    var editors: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Slider Entry Comparison", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        let window = Self.window(title: "Slider Entry Comparison", root: ComparisonLauncher(open: { [weak self] in self?.open($0) }))
        launcher = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func open(_ kind: ComparisonState.Kind) {
        let state = ComparisonState(kind)
        let window = Self.window(title: kind.rawValue, root: ComparisonEditor(state: state))
        editors.append(window)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    static func window<V: View>(title: String, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentViewController = NSHostingController(rootView: root.environment(\.accessibilityEnabled, true))
        return window
    }
}

@main struct SliderEntryComparison {
    @MainActor static func main() async throws {
        // Keep coverage output from the linked debug library out of the working directory.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__llvm_profile_set_filename") {
            let setFilename = unsafeBitCast(symbol, to: (@convention(c) (UnsafePointer<CChar>) -> Void).self)
            let profile = NSTemporaryDirectory() + "trimato-slider-comparison-\(ProcessInfo.processInfo.processIdentifier).profraw"
            profile.withCString { setFilename($0) }
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--background-check") {
            app.setActivationPolicy(.prohibited); app.finishLaunching()
            for kind in ComparisonState.Kind.allCases {
                let state = ComparisonState(kind, background: true)
                let window = ComparisonApp.window(title: kind.rawValue, root: ComparisonEditor(state: state))
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let slider = state.slider else { fatalError("Missing slider") }
                precondition(!slider.isEnabled)
                await state.enter(); precondition(!state.entered)
                state.preparing = false
                try await Task.sleep(for: .milliseconds(100))
                await state.enter()
                precondition(state.entered && window.firstResponder === slider)
                precondition(slider.cell?.accessibilityLabel() == "Clip playhead")
                if kind == .trimato { precondition(slider.cell?.accessibilityValue() as? String == "00:00") }
                else { precondition(slider.cell?.accessibilityValue() is NSNumber) }
                precondition(!window.isVisible && !window.isKeyWindow && !app.isActive)
                print("PASS: \(kind.rawValue), disabled preparation, native entry, label and value, invisible inactive window")
            }
            print("LIMITATION: background checks do not exercise sheet dismissal or VoiceOver speech")
            return
        }
        app.setActivationPolicy(.regular)
        let delegate = ComparisonApp(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
