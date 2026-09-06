import AppKit
import AVFoundation
import Combine
import SwiftUI

struct AudioRecordingSettingsView: View {
    @StateObject private var sliderKeyboard = SettingsSliderKeyboard()
    @StateObject private var input = AudioInputManager.shared
    @ObservedObject private var capture: AudioCaptureSession
    @ObservedObject private var output = AudioOutputManager.shared
    @AccessibilityFocusState private var pickerFocus: PickerTarget?
    @State private var focusTask: Task<Void, Never>?
    @State private var message: ApplicationMessageDescriptor?
    private enum PickerTarget: Hashable { case input, channel, depth, output }

    init(capture: AudioCaptureSession? = nil) {
        self.capture = capture ?? AudioCaptureSession()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Microphone access", value: input.permissionTitle)
                        .accessibilityElement(children: .combine)
                    Button(input.permission == .notDetermined ? "Allow microphone access…" : "Microphone privacy settings…") {
                        if input.permission == .notDetermined {
                            Task { await input.requestPermission() }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Picker(selection: $input.selectedUID) {
                        Text("System Default").tag("")
                        ForEach(input.inputs) { Text($0.name).tag($0.id) }
                        if !input.selectedUID.isEmpty, !input.inputs.contains(where: { $0.id == input.selectedUID }) {
                            Text("Unavailable input").tag(input.selectedUID)
                        }
                    }
                    label: { Text("Microphone").accessibilityHidden(true) }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Microphone")
                    .accessibilityFocused($pickerFocus, equals: .input)
                    .disabled(capture.isBusy)
                    Picker(selection: Binding(get: { input.channel }, set: { input.channel = $0; restore(.channel) })) {
                        ForEach(0..<max(1, input.resolvedDevice?.inputChannels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                        if input.channel >= max(1, input.resolvedDevice?.inputChannels ?? 1) {
                            Text("Channel \(input.channel + 1) unavailable").tag(input.channel)
                        }
                    }
                    label: { Text("Microphone channel").accessibilityHidden(true) }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Microphone channel")
                    .accessibilityFocused($pickerFocus, equals: .channel)
                    .disabled(capture.isBusy)
                    Picker(selection: $input.bitDepth) {
                        Text("Standard").tag(16)
                        Text("High").tag(24)
                    }
                    label: { Text("Recording quality").accessibilityHidden(true) }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Recording quality")
                    .accessibilityFocused($pickerFocus, equals: .depth)
                    .disabled(capture.isBusy)
                    MicrophoneVolumeSlider(value: Binding(get: { Double(input.hardwareGain ?? 0) * 100 }, set: { value in
                        do { try input.setGain(Float(value / 100)) }
                        catch { message = ApplicationMessageDescriptor(title: "Microphone Volume", message: error.localizedDescription) }
                    }), isEnabled: !capture.isRecordingRequested && input.hardwareGain != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Playback")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                Picker(selection: $output.selectedUID) {
                    Text("System Default").tag("")
                    ForEach(output.outputs) { Text($0.name).tag($0.id) }
                    if !output.selectedUID.isEmpty, !output.outputs.contains(where: { $0.id == output.selectedUID }) {
                        Text("Unavailable output").tag(output.selectedUID)
                    }
                }
                label: { Text("Playback device").accessibilityHidden(true) }
                .pickerStyle(.menu)
                .accessibilityLabel("Playback device")
                .accessibilityFocused($pickerFocus, equals: .output)
                .disabled(capture.isBusy)
            }
            Text("Recording test")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Record Test", isOn: Binding(get: { capture.isRecordingRequested }, set: { enabled in
                            focusTask?.cancel()
                            capture.setRecording(enabled, input: input)
                        }))
                        .toggleStyle(.button)
                        .disabled(!capture.isRecordingRequested && (input.permission != .authorized || input.resolvedDevice == nil || !output.isAvailable))
                        Toggle("Play Test", isOn: Binding(get: { capture.isPlaying }, set: { capture.setTestPlayback($0) }))
                            .toggleStyle(.button)
                            .disabled(capture.testURL == nil || capture.isBusy)
                        Button("Delete Test") { capture.deleteTest() }
                            .disabled(capture.testURL == nil || capture.isBusy)
                    }
                    LabeledContent("Status", value: status)
                        .accessibilityElement(children: .combine)
                    LabeledContent("Length", value: capture.summary.map { String(format: "%.2f seconds", $0.duration) } ?? "No recording")
                        .accessibilityElement(children: .combine)
                    LabeledContent("Recording level", value: recordingLevel)
                        .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onChange(of: input.selectedUID) { _, _ in restore(.input) }
        .onChange(of: input.bitDepth) { _, _ in restore(.depth) }
        .onChange(of: output.selectedUID) { _, _ in restore(.output) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in input.refresh(); output.refresh() }
        .onAppear { sliderKeyboard.start() }
        .onDisappear { sliderKeyboard.stop(); focusTask?.cancel(); capture.close() }
        .applicationMessage(capture.message ?? message) { capture.message = nil; message = nil }
    }

    private var recordingLevel: String {
        guard let summary = capture.summary else { return "No recording" }
        if summary.clippedSamples > 0 { return "Too loud" }
        return summary.peak > 0 ? "Sound detected" : "No sound"
    }

    private var status: String {
        switch capture.state {
        case .idle: capture.isPlaying ? "Playing test" : "Ready"
        case .preparing: "Preparing recording"
        case .recording: "Recording"
        case .finishing: "Finishing recording"
        }
    }

    private func restore(_ target: PickerTarget) {
        focusTask?.cancel()
        pickerFocus = nil
        focusTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard !capture.isBusy else { return }
                pickerFocus = target
                try await Task.sleep(for: .milliseconds(350))
                guard !capture.isBusy else { return }
                pickerFocus = target
            } catch { }
        }
    }
}

struct MicrophoneVolumeSlider: View {
    @Binding var value: Double
    var isEnabled = true
    var body: some View {
        Slider(value: $value, in: 0...100, step: 1) {
            Text("Microphone volume").accessibilityHidden(true)
        }
        .accessibilityLabel("Microphone volume")
        .accessibilityIdentifier(SettingsSliderKeyboard.identifier)
        .disabled(!isEnabled)
    }
}

/// Route bare vertical arrows to the focused slider's native accessibility action.
/// VoiceOver focus need not be the window's keyboard first responder.
@MainActor
final class SettingsSliderKeyboard: ObservableObject {
    static let identifier = "trimato.settings.microphone-volume"
    private var monitor: Any?
    private let targetIdentifier: String
    init(identifier: String = SettingsSliderKeyboard.identifier) { targetIdentifier = identifier }
    func start() {
        guard monitor == nil else { return }
        let identifier = targetIdentifier
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(event, focused: NSApp.accessibilityFocusedUIElement as? NSObject, identifier: identifier)
        }
    }

    static func handle(_ event: NSEvent, focused: NSObject?, identifier: String = SettingsSliderKeyboard.identifier) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.keyCode == 126 || event.keyCode == 125 else { return event }
        var candidate = focused
        var visited = Set<ObjectIdentifier>()
        while let element = candidate, visited.insert(ObjectIdentifier(element)).inserted {
            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            if element.responds(to: identifierSelector),
               element.value(forKey: "accessibilityIdentifier") as? String == identifier {
                let action = NSSelectorFromString(event.keyCode == 126 ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement")
                guard element.responds(to: action) else { return event }
                typealias NativeAdjustment = @convention(c) (AnyObject, Selector) -> Bool
                let adjust = unsafeBitCast(element.method(for: action), to: NativeAdjustment.self)
                _ = adjust(element, action)
                return nil
            }
            let parentSelector = NSSelectorFromString("accessibilityParent")
            candidate = element.responds(to: parentSelector)
                ? element.perform(parentSelector)?.takeUnretainedValue() as? NSObject : nil
        }
        return event
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
