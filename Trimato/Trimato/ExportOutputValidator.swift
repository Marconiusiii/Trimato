import Foundation

nonisolated enum ExportOutputValidator {
    static func validate(_ url: URL, duration: Double, video: Bool, audio: Bool) async throws {
        try Task.checkCancellation()
        let report = try await FFmpegMediaProbe.inspect(url: url)
        // Permit container rounding and encoder padding, but not a missing end.
        let tolerance = max(0.15, 2 / max(report.frameRate ?? 30, 1))
        guard duration.isFinite, duration > 0, report.duration.isFinite, report.duration > 0,
              abs(report.duration - duration) <= tolerance,
              !video || report.videoStream != nil,
              !audio || report.hasAudio,
              report.videoStream != nil || report.hasAudio else {
            throw ProjectExporter.ExportError.encodingFailed(
                "The completed media did not contain the expected duration or tracks. The destination has not been replaced.")
        }
        try Task.checkCancellation()
    }
}
