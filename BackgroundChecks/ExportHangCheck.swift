import AVFoundation
import Foundation
import Darwin
@testable import Trimato

/// File-only reproduction of the tester's track arrangement; no windows or playback.
@main struct ExportHangCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let data = try Data(contentsOf: input)
        let project = try JSONDecoder().decode(TrimatoProject.self, from: data)
        var urls: [UUID: URL] = [:]
        for (index, media) in project.media.enumerated() {
            let video = media.hasVideo
            let ext = video ? "mp4" : "wav"
            let url = directory.appendingPathComponent("source-\(index).\(ext)")
            let duration = media.duration.seconds + 0.05
            var arguments = ["-v", "error", "-nostdin", "-y"]
            if video {
                arguments += ["-f", "lavfi", "-i", "color=c=blue:s=1728x1118:r=25:d=\(duration)"]
            }
            arguments += ["-f", "lavfi", "-i", "sine=frequency=\(220 + index * 110):sample_rate=48000:duration=\(duration)"]
            if video { arguments += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "1000000", "-c:a", "aac"] }
            else { arguments += ["-c:a", "pcm_s16le"] }
            arguments += ["-ac", "2", url.path]
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments)
            }
            urls[media.id] = url
            print("Source ready \(index): \(media.duration.seconds) seconds, \(ext)")
        }
        if CommandLine.arguments.contains("--cancel") {
            let destination = directory.appendingPathComponent("cancelled.mp4")
            let original = Data("existing output must survive cancellation".utf8)
            try original.write(to: destination)
            let export = Task { @MainActor in
                try await ProjectExporter.export(project: project, mediaURLs: urls,
                    format: .h264MP4, to: destination, audioMode: .highQualityStereo,
                    progress: { _ in }, preserveHDR: false)
            }
            try await Task.sleep(for: .seconds(2))
            export.cancel()
            do {
                try await export.value
                throw NSError(domain: "ExportHangCheck", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Export unexpectedly completed before cancellation"])
            } catch is CancellationError {
                guard try Data(contentsOf: destination) == original else {
                    throw NSError(domain: "ExportHangCheck", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Cancellation changed existing output"])
                }
            }
            print("PASS: export cancellation returned and preserved existing output")
            return
        }
        let destination = directory.appendingPathComponent("project.mp4")
        let started = Date()
        var lastBucket = -1
        try await ProjectExporter.export(project: project, mediaURLs: urls, format: .h264MP4,
            to: destination, audioMode: .highQualityStereo, progress: { value in
                let bucket = Int(value * 100)
                if bucket != lastBucket {
                    lastBucket = bucket
                    print("Export \(bucket)% after \(Int(Date().timeIntervalSince(started))) seconds")
                }
            }, preserveHDR: false)
        try await ExportOutputValidator.validate(destination, duration: project.duration.seconds, video: true, audio: true)
        guard try Data(contentsOf: input) == data else { fatalError("Input project changed") }
        print("PASS: full project exported and validated, duration \(project.duration.seconds), original JSON unchanged")
    }
}
