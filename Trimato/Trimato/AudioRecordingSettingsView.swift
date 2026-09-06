import AppKit
import AVFoundation
import SwiftUI

struct AudioRecordingSettingsView: View {
    @StateObject private var input = AudioInputManager()
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
            GroupBox("Microphone") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Permission", value: input.permissionTitle)
                    Button("Microphone Access…") {
                        if input.permission == .notDetermined {
                            Task { await input.requestPermission() }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Picker("Audio Input", selection: $input.selectedUID) {
                        Text("System Default").tag("")
                        ForEach(input.inputs) { Text($0.name).tag($0.id) }
                        if !input.selectedUID.isEmpty, !input.inputs.contains(where: { $0.id == input.selectedUID }) {
                            Text("Unavailable input").tag(input.selectedUID)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityFocused($pickerFocus, equals: .input)
                    .disabled(capture.isBusy)
                    Picker("Input Channel", selection: Binding(get: { input.channel }, set: { input.channel = $0; restore(.channel) })) {
                        ForEach(0..<max(1, input.resolvedDevice?.inputChannels ?? 1), id: \.self) { Text("Channel \($0 + 1) (mono)").tag($0) }
                        if input.channel >= max(1, input.resolvedDevice?.inputChannels ?? 1) {
                            Text("Channel \(input.channel + 1) unavailable").tag(input.channel)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityFocused($pickerFocus, equals: .channel)
                    .disabled(capture.isBusy)
                    Picker("Recording Quality", selection: $input.bitDepth) {
                        Text("16-bit PCM").tag(16)
                        Text("24-bit PCM").tag(24)
                    }
                    .pickerStyle(.menu)
                    .accessibilityFocused($pickerFocus, equals: .depth)
                    .disabled(capture.isBusy)
                    LabeledContent("Sample rate", value: sampleRate)
                    Slider(value: Binding(get: { Double(input.hardwareGain ?? 0) * 100 }, set: { value in
                        do { try input.setGain(Float(value / 100)) }
                        catch { message = ApplicationMessageDescriptor(title: "Input Gain", message: error.localizedDescription) }
                    }), in: 0...100, step: 1) { Text("Hardware Input Gain") }
                    .accessibilityValue(input.hardwareGain.map { "\(Int($0 * 100)) percent" } ?? "Not supported by this device")
                    .disabled(capture.isRecordingRequested || input.hardwareGain == nil)
                    Text(input.hardwareGain == nil ? "Adjust gain on your microphone or audio interface if available." : "Hardware gain changes the microphone input level.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Playback") {
                Picker("Audio Playback Output", selection: $output.selectedUID) {
                    Text("System Default").tag("")
                    ForEach(output.outputs) { Text($0.name).tag($0.id) }
                    if !output.selectedUID.isEmpty, !output.outputs.contains(where: { $0.id == output.selectedUID }) {
                        Text("Unavailable output").tag(output.selectedUID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityFocused($pickerFocus, equals: .output)
                .disabled(capture.isBusy)
            }
            GroupBox("Recording test") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Turn Record Test on to record after the cue, and off to stop. Tests last up to 60 seconds and are deleted when you leave Audio settings.")
                        .font(.callout)
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
                    LabeledContent("Recorded duration", value: capture.summary.map { String(format: "%.2f seconds", $0.duration) } ?? "No recording")
                    LabeledContent("Peak level", value: peakLevel)
                    LabeledContent("Clipping", value: clipping)
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
        .onDisappear { focusTask?.cancel(); capture.close() }
        .applicationMessage(capture.message ?? message) { capture.message = nil; message = nil }
    }

    private var sampleRate: String {
        guard let device = input.resolvedDevice else { return "Input unavailable" }
        return "\(Int(AudioHardware.sampleRate(device.deviceID))) Hz, device rate"
    }

    private var peakLevel: String {
        guard let summary = capture.summary else { return "No recording" }
        return summary.peakDecibels.map { String(format: "%.1f dBFS", $0) } ?? "No signal"
    }

    private var clipping: String {
        guard let summary = capture.summary else { return "No recording" }
        return summary.clippedSamples > 0 ? "Detected. Reduce input gain and try again." : "Not detected"
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
