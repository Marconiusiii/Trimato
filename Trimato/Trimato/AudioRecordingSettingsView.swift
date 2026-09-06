import AppKit
import AVFoundation
import SwiftUI

struct AudioRecordingSettingsView: View {
    @StateObject private var input = AudioInputManager()
    @StateObject private var capture = AudioCaptureSession()
    @ObservedObject private var output = AudioOutputManager.shared
    @AccessibilityFocusState private var pickerFocus: PickerTarget?
    @State private var focusTask: Task<Void, Never>?
    @State private var message: ApplicationMessageDescriptor?
    private enum PickerTarget: Hashable { case input, channel, depth, output }

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Permission", value: input.permissionTitle)
                if input.permission == .notDetermined {
                    Button("Allow microphone access…") { Task { await input.requestPermission() } }
                } else if input.permission != .authorized {
                    Button("Open microphone privacy settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
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
                if let device = input.resolvedDevice {
                    LabeledContent("Sample rate", value: "\(Int(AudioHardware.sampleRate(device.deviceID))) Hz, device rate")
                } else { Text("The selected input is unavailable.") }
                if let gain = input.hardwareGain {
                    Slider(value: Binding(get: { Double(input.hardwareGain ?? gain) * 100 }, set: { value in
                        do { try input.setGain(Float(value / 100)) }
                        catch { message = ApplicationMessageDescriptor(title: "Input Gain", message: error.localizedDescription) }
                    }), in: 0...100, step: 1) { Text("Hardware Input Gain") }
                    .accessibilityValue("\(Int(gain * 100)) percent")
                    .disabled(capture.isBusy)
                } else { Text("Adjust input gain on your microphone or audio interface if available.") }
            }
            Section("Playback") {
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
                if !output.isAvailable { Text("The selected playback output is unavailable. Choose another output to resume playback.") }
            }
            Section("Recording test") {
                Text("Speak after the rising cue. Stop ends the test before the falling cue. Tests stop automatically after 60 seconds and are deleted when you leave this pane.")
                HStack {
                    Button("Record Test") {
                        focusTask?.cancel()
                        capture.record(input: input)
                    }
                    .disabled(input.permission != .authorized || input.resolvedDevice == nil || !output.isAvailable)
                    Button("Stop") { capture.stop() }
                    Button("Play Test") { capture.playTest() }
                        .disabled(capture.testURL == nil || capture.isBusy)
                    Button("Delete Test") { capture.deleteTest() }
                        .disabled(capture.testURL == nil || capture.isBusy)
                }
                LabeledContent("Status", value: status)
                if let summary = capture.summary {
                    LabeledContent("Recorded duration", value: String(format: "%.2f seconds", summary.duration))
                    LabeledContent("Peak level", value: summary.peakDecibels.map { String(format: "%.1f dBFS", $0) } ?? "No signal")
                    LabeledContent("Clipping", value: summary.clippedSamples > 0 ? "Detected. Reduce microphone input gain and record another test." : "Not detected")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: input.selectedUID) { _, _ in restore(.input) }
        .onChange(of: input.bitDepth) { _, _ in restore(.depth) }
        .onChange(of: output.selectedUID) { _, _ in restore(.output) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in input.refresh(); output.refresh() }
        .onDisappear { focusTask?.cancel(); capture.close() }
        .applicationMessage(capture.message ?? message) { capture.message = nil; message = nil }
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
