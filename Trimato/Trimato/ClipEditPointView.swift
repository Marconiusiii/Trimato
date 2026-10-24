import CoreMedia
import SwiftUI

nonisolated struct ClipEditPointValidation: Error {
    var inMessage: String?
    var outMessage: String?
}

nonisolated struct ClipEditPointInput: Identifiable {
    let id = UUID()
    let generation: UUID
    let timeline: ClipEditTimeline
    let point: ClipEditTimeline.EditPoint
    let sourceDuration: CMTime
    let frameRate: Double
    let frames: Bool

    func timeInput(_ time: CMTime) -> JumpToTimeInput {
        JumpToTimeInput(position: time.seconds, duration: sourceDuration.seconds,
            frameRate: frameRate, frames: frames, milliseconds: true)
    }

    func validatedTimeline(inText: String, outText: String) throws -> ClipEditTimeline {
        var validation = ClipEditPointValidation()
        func parse(_ text: String, original: CMTime, field: String) throws -> CMTime {
            let input = timeInput(original)
            // Keep source precision when an existing value is left as displayed.
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == input.initialText { return original }
            do {
                return CMTime(seconds: try input.destination(for: text), preferredTimescale: ProjectTime.defaultTimescale)
            } catch {
                let end = timeInput(sourceDuration).initialText
                let format = frames ? "a whole frame number" : "hours:minutes:seconds, such as 00:00:01.250"
                throw JumpToTimeError(message: "\(field) is invalid. Enter \(format) between \(timeInput(.zero).initialText) and \(end).")
            }
        }
        var inTime: CMTime?
        var outTime: CMTime?
        do { inTime = try parse(inText, original: point.inTime, field: "In") }
        catch { validation.inMessage = error.localizedDescription }
        do { outTime = try parse(outText, original: point.outTime, field: "Out") }
        catch { validation.outMessage = error.localizedDescription }
        if let inTime, CMTimeCompare(inTime, point.precedingStart) <= 0 {
            validation.inMessage = "In must be later than \(timeInput(point.precedingStart).initialText) to keep the section before this edit point."
        }
        if let outTime, CMTimeCompare(outTime, point.followingEnd) >= 0 {
            validation.outMessage = "Out must be earlier than \(timeInput(point.followingEnd).initialText) to keep the section after this edit point."
        }
        if let inTime, let outTime, CMTimeCompare(inTime, outTime) >= 0 {
            validation.inMessage = "In must be earlier than Out."
        }
        guard validation.inMessage == nil, validation.outMessage == nil,
              let inTime, let outTime else { throw validation }
        return try timeline.adjustingEditPoint(point.index, inTime: inTime, outTime: outTime)
    }
}

struct ClipEditPointView: View {
    let input: ClipEditPointInput
    let apply: (ClipEditTimeline) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inText: String
    @State private var outText: String
    @State private var validation = ClipEditPointValidation()
    @State private var failure: String?
    @State private var applying = false
    @State private var work: Task<Void, Never>?

    init(input: ClipEditPointInput, apply: @escaping (ClipEditTimeline) async throws -> Void) {
        self.input = input
        self.apply = apply
        _inText = State(initialValue: input.timeInput(input.point.inTime).initialText)
        _outText = State(initialValue: input.timeInput(input.point.outTime).initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(input.point.name).font(EditorTheme.dialogTitle).accessibilityAddTraits(.isHeader)
            Form {
                TextField(input.frames ? "In frame" : "In timecode", text: $inText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(applying)
                if let message = validation.inMessage { Text(message).fixedSize(horizontal: false, vertical: true) }
                TextField(input.frames ? "Out frame" : "Out timecode", text: $outText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(applying)
                if let message = validation.outMessage { Text(message).fixedSize(horizontal: false, vertical: true) }
            }
            .formStyle(.columns)
            if applying { ProgressView("Adjusting edit point…") }
            if let failure { Text(failure).fixedSize(horizontal: false, vertical: true) }
            NativeModalActions(primaryTitle: "Apply", primaryEnabled: !applying,
                cancel: { work?.cancel(); dismiss() }, primary: applyEdit)
        }
        .padding(EditorTheme.dialogPadding)
        .frame(minWidth: 420, idealWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: inText) { validation = ClipEditPointValidation(); failure = nil }
        .onChange(of: outText) { validation = ClipEditPointValidation(); failure = nil }
        .onDisappear { work?.cancel() }
    }

    private func applyEdit() {
        guard !applying else { return }
        validation = ClipEditPointValidation(); failure = nil
        do {
            let timeline = try input.validatedTimeline(inText: inText, outText: outText)
            applying = true
            work = Task { @MainActor in
                do {
                    try await apply(timeline)
                    try Task.checkCancellation()
                    dismiss()
                } catch is CancellationError {
                    applying = false
                } catch {
                    applying = false
                    failure = error.localizedDescription
                }
            }
        } catch let errors as ClipEditPointValidation {
            validation = errors
        } catch {
            failure = error.localizedDescription
        }
    }
}
