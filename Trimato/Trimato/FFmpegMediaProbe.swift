import AVFoundation
import Foundation

struct FFmpegMediaProbe {
    struct Report: Decodable, Equatable {
        struct Stream: Decodable, Equatable {
            let codecType: String?
            let codecName: String?
            let pixelFormat: String?
            let colorTransfer: String?

            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type"
                case codecName = "codec_name"
                case pixelFormat = "pix_fmt"
                case colorTransfer = "color_transfer"
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

    private struct FrameReport: Decodable {
        struct Frame: Decodable {
            let bestEffortTimestampTime: String?

            enum CodingKeys: String, CodingKey {
                case bestEffortTimestampTime = "best_effort_timestamp_time"
            }
        }

        let frames: [Frame]
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

    static func frameTimestamps(url: URL) async throws -> [CMTime] {
        let result = try await FFmpegRunner.run(tool: .ffprobe, arguments: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time",
            "-of", "json",
            url.path
        ])
        let report = try JSONDecoder().decode(FrameReport.self, from: result.standardOutput)
        let seconds: [Double] = report.frames.compactMap { frame -> Double? in
            guard let raw = frame.bestEffortTimestampTime,
                  let seconds = Double(raw), seconds.isFinite else { return nil }
            return seconds
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
