import SwiftUI

nonisolated struct JumpToTimeInput: Identifiable {
    let id = UUID()
    let position: Double
    let duration: Double
    let frameRate: Double
    let frames: Bool
    let milliseconds: Bool

    var rate: Double { ProjectFormat.stableFrameRate(frameRate) }
    var lastFrame: Int64 { Int64(Self.frameNumber(seconds: duration, rate: rate)) }
    var initialText: String {
        if frames { return String(Self.frameNumber(seconds: position, rate: rate)) }
        let text = AppPreferences.passiveTimecode(seconds: position, precision: milliseconds)
        return text.filter { $0 == ":" }.count == 1 ? "00:" + text : text
    }

    func destination(for text: String) throws -> Double {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double
        if frames {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let frame = Int64(text), frame >= 0, frame <= lastFrame else {
                throw JumpToTimeError(message: "That frame number is invalid. Enter a frame number between 0 and \(lastFrame.formatted()).")
            }
            value = min(Double(frame) / rate, duration)
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            let invalid = JumpToTimeError(message: "The timecode format is invalid. Enter hours, minutes, and seconds separated by colons.")
            guard parts.count == 3,
                  parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  parts[2].allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
                  let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
                  hours.isFinite, minutes < 60, seconds < 60 else { throw invalid }
            // Retain precision hidden by the user's milliseconds display setting.
            value = text == initialText ? position : hours * 3600 + minutes * 60 + seconds
        }
        guard value.isFinite, value >= 0, value <= duration else {
            throw JumpToTimeError(message: "That time is outside the timeline. Enter a time between zero and \(AppPreferences.spokenTimecode(seconds: duration, frameRate: rate, milliseconds: milliseconds, style: .timeUnits)).")
        }
        return value
    }

    static func frameNumber(seconds: Double, rate: Double) -> Int {
        let rate = ProjectFormat.stableFrameRate(rate)
        let value = max(0, seconds) * rate
        guard value.isFinite else { return 0 }
        guard value < Double(Int.max) else { return Int.max }
        // ProjectTime quantizes to 600,000 ticks per second. A seek exactly on
        // a frame boundary may round down by half a tick; keep that frame's number.
        let nearest = value.rounded()
        let tolerance = rate / Double(ProjectTime.defaultTimescale) * 0.51
        return Int(abs(value - nearest) <= tolerance ? nearest : value.rounded(.down))
    }


}

nonisolated struct JumpToTimeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct JumpToTimeView: View {
    let input: JumpToTimeInput
    let cancel: () -> Void
    let seek: (Double, @escaping (Bool) -> Void) -> Void
    let completed: () -> Void
    @State private var text: String
    @State private var seeking = false
    @State private var error: ApplicationMessageDescriptor?
    @FocusState private var inputFocused: Bool
    @AccessibilityFocusState private var inputAccessibilityFocused: Bool

    init(input: JumpToTimeInput, cancel: @escaping () -> Void,
         seek: @escaping (Double, @escaping (Bool) -> Void) -> Void, completed: @escaping () -> Void) {
        self.input = input
        self.cancel = cancel
        self.seek = seek
        self.completed = completed
        _text = State(initialValue: input.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Jump to Time").editorFont(.title2, weight: .semibold).accessibilityAddTraits(.isHeader)
            TextField(input.frames ? "Frame" : "Timecode", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .accessibilityFocused($inputAccessibilityFocused)
                .disabled(seeking)
            NativeModalActions(primaryTitle: "Jump", primaryEnabled: !seeking,
                cancel: cancel, primary: jump)
                .disabled(seeking)
        }
        .padding(EditorTheme.dialogPadding)
        .frame(minWidth: 360, idealWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(seeking)
        .onAppear { ClipEntryDiagnostics.record("jump.sheet.appeared") }
        .onDisappear { ClipEntryDiagnostics.record("jump.sheet.disappeared seeking=\(seeking)") }
        .applicationMessage(error) {
            error = nil
            Task { @MainActor in
                await Task.yield()
                inputFocused = true
                inputAccessibilityFocused = true
            }
        }
    }

    private func presentError(_ message: String, title: String) {
        inputFocused = false
        inputAccessibilityFocused = false
        error = .init(title: title, message: message)
    }

    private func jump() {
        do {
            let destination = try input.destination(for: text)
            guard !seeking else { return }
            seeking = true
            ClipEntryDiagnostics.record("jump.seek.started controlsEnabled=false")
            seek(destination) { finished in
                ClipEntryDiagnostics.record("jump.seek.completed success=\(finished)")
                if finished {
                    // Keep the closing sheet stable instead of re-enabling its controls.
                    completed()
                } else {
                    seeking = false
                    ClipEntryDiagnostics.record("jump.seek.failed controlsEnabled=true")
                    presentError("The playhead could not move to that position. Try Jump again.", title: "Could Not Jump")
                }
            }
        } catch {
            presentError(error.localizedDescription, title: "Could Not Jump")
        }
    }
}
