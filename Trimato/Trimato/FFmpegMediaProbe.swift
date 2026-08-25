import AVFoundation
import Foundation

struct FFmpegMediaProbe {
    private nonisolated final class FrameProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private let duration: Double
        private let progress: @MainActor @Sendable (Double) -> Void
        private var lastReportedPercent = -1
        private var lastDeliveredPercent = -1
        private var isFinished = false

        init(duration: Double, progress: @escaping @MainActor @Sendable (Double) -> Void) {
            self.duration = duration
            self.progress = progress
        }

        func receive(_ line: String) {
            guard let timestamp = Double(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  timestamp.isFinite else { return }
            let percent = min(max(Int((timestamp / duration * 100).rounded(.down)), 0), 99)
            lock.lock()
            guard percent > lastReportedPercent else {
                lock.unlock()
                return
            }
            lastReportedPercent = percent
            lock.unlock()
            Task { @MainActor [weak self] in
                guard let self, self.shouldDeliver(percent) else { return }
                self.progress(Double(percent) / 100)
            }
        }

        func finish() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        private func shouldDeliver(_ percent: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished, percent > lastDeliveredPercent else { return false }
            lastDeliveredPercent = percent
            return true
        }
    }

    struct Report: Decodable, Equatable {
        struct Stream: Decodable, Equatable {
            let codecType: String?
            let codecName: String?
            let pixelFormat: String?
            let colorTransfer: String?
            let width: Int?
            let height: Int?
            let averageFrameRate: String?

            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type"
                case codecName = "codec_name"
                case pixelFormat = "pix_fmt"
                case colorTransfer = "color_transfer"
                case width
                case height
                case averageFrameRate = "avg_frame_rate"
            }
        }

        struct Format: Decodable, Equatable {
            let duration: String?
            let formatName: String?

            enum CodingKeys: String, CodingKey {
                case duration
                case formatName = "format_name"
            }
        }

        let streams: [Stream]
        let format: Format?

        var videoStream: Stream? { streams.first { $0.codecType == "video" } }
        var hasAudio: Bool { streams.contains { $0.codecType == "audio" } }
        var duration: Double { Double(format?.duration ?? "") ?? 0 }

        var frameRate: Double? {
            guard let raw = videoStream?.averageFrameRate else { return nil }
            let parts = raw.split(separator: "/", maxSplits: 1).compactMap { Double($0) }
            if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
            return Double(raw)
        }

        var isHDR: Bool {
            guard let transfer = videoStream?.colorTransfer?.lowercased() else { return false }
            return transfer == "smpte2084" || transfer == "arib-std-b67"
        }

        var hasAlpha: Bool {
            guard let pixelFormat = videoStream?.pixelFormat?.lowercased() else { return false }
            return pixelFormat.contains("yuva") || pixelFormat.contains("rgba") ||
                pixelFormat.contains("bgra") || pixelFormat.contains("argb") ||
                pixelFormat.contains("abgr") || pixelFormat.contains("gbrap")
        }
    }

    static func inspect(url: URL) async throws -> Report {
        let result = try await FFmpegRunner.run(tool: .ffprobe, arguments: [
            "-v", "error",
            "-show_streams",
            "-show_format",
            "-of", "json",
            url.path
        ])
        do {
            let report = try JSONDecoder().decode(Report.self, from: result.standardOutput)
            guard report.videoStream != nil else { throw MediaSourceError.noVideoTrack }
            return report
        } catch let error as MediaSourceError {
            throw error
        } catch {
            throw MediaSourceError.unreadable("The selected video's technical information could not be read.")
        }
    }

    static func frameTimestamps(
        url: URL,
        duration: Double? = nil,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> [CMTime] {
        let progressReporter: FrameProgressReporter?
        if let duration, duration.isFinite, duration > 0, let progress {
            progressReporter = FrameProgressReporter(duration: duration, progress: progress)
        } else {
            progressReporter = nil
        }
        let result = try await FFmpegRunner.run(tool: .ffprobe, arguments: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ], outputLine: { line in
            progressReporter?.receive(line)
        })
        let seconds: [Double] = String(decoding: result.standardOutput, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .compactMap { raw -> Double? in
                guard let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
                      seconds.isFinite else { return nil }
                return seconds
            }
        progressReporter?.finish()
        if let progress {
            progress(1)
        }
        guard let first = seconds.first else { return [] }
        return seconds.map { timestamp in
            CMTime(seconds: max(timestamp - first, 0), preferredTimescale: 1_000_000)
        }
    }

    static func validateForMP4Conversion(_ report: Report) throws {
        if report.isHDR { throw MediaSourceError.unsupportedHDR }
        if report.hasAlpha { throw MediaSourceError.unsupportedAlpha }
    }
}
