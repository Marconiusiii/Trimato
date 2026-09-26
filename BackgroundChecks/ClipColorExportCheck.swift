import AVFoundation
import CryptoKit
import Foundation
@testable import Trimato

// Runs without windows, playback, or persistent preference changes.
@main struct ClipColorExportCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        UserDefaults.standard.setVolatileDomain([AppPreferenceKey.preserveHDR: true], forName: UserDefaults.argumentDomain)
        precondition(AppPreferences.preserveHDR())
        let ranges = [CMTimeRange(start: CMTime(seconds: 0.1, preferredTimescale: 600), duration: CMTime(seconds: 0.3, preferredTimescale: 600)),
                      CMTimeRange(start: CMTime(seconds: 0.6, preferredTimescale: 600), duration: CMTime(seconds: 0.3, preferredTimescale: 600))]
        for sourceName in ["hlg", "pq", "sdr"] {
            let source = directory.appendingPathComponent(sourceName + ".mov")
            let before = SHA256.hash(data: try Data(contentsOf: source))
            let asset = AVURLAsset(url: source)
            let detected = try await VideoColorPolicy.resolve(asset: asset, preserveHDR: true)
            precondition(detected == (sourceName == "sdr" ? .sdr : .hlg))
            for format in [ExportFormat.h264MP4, .compactMP4, .h264QuickTime, .hevcMP4, .proRes422LT, .original, .m4a] {
                let output = directory.appendingPathComponent(sourceName + "-" + format.rawValue).appendingPathExtension(format == .original ? "mov" : format.fileExtension)
                try await ClipExporter.export(asset: asset, sourceRanges: ranges, sourceContentType: .quickTimeMovie,
                    format: format, to: output, preserveSpatialAudio: false, progress: { _ in })
                try await verify(output, video: !format.isAudioOnly,
                    hdr: sourceName != "sdr" && format.supportsHDR, duration: 0.6)
                print("PASS \(sourceName) to \(format.rawValue)")
            }
            let regularURL = directory.appendingPathComponent(sourceName + "-h264MP4.mp4")
            let compactURL = directory.appendingPathComponent(sourceName + "-compactMP4.mp4")
            let regularBytes = try regularURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            let compactBytes = try compactURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            print("\(sourceName) bytes: regular \(regularBytes), compact \(compactBytes)")
            let comparison = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-i", regularURL.path, "-i", compactURL.path,
                "-lavfi", "ssim", "-an", "-f", "null", "-"])
            print(comparison.standardError.split(separator: "\n").filter { $0.contains("SSIM") }.joined(separator: "\n"))
            do {
                let output = directory.appendingPathComponent(sourceName + "-fallback.mp4")
                try await FFmpegClipExporter.export(sourceURL: source, sourceRanges: ranges, hasAudio: true,
                    format: .compactMP4, to: output, audioMode: .highQualityStereo, progress: { _ in })
                try await verify(output, video: true, hdr: false, duration: 0.6)
                print("PASS \(sourceName) fallback export")
            }
            let after = SHA256.hash(data: try Data(contentsOf: source))
            precondition(after == before, "Source changed")
        }
        if CommandLine.arguments.count > 2 {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            let before = SHA256.hash(data: try Data(contentsOf: source))
            let realRanges = [CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 4, preferredTimescale: 600))]
            for format in [ExportFormat.h264MP4, .compactMP4, .h264QuickTime] {
                let output = directory.appendingPathComponent("iphone-" + format.rawValue).appendingPathExtension(format.fileExtension)
                try await ClipExporter.export(asset: AVURLAsset(url: source), sourceRanges: realRanges,
                    sourceContentType: .quickTimeMovie, format: format, to: output,
                    preserveSpatialAudio: format == .h264QuickTime, progress: { _ in })
                try await verify(output, video: true, hdr: false, duration: 4)
                print("PASS iPhone recording to \(format.rawValue)")
            }
            let regular = directory.appendingPathComponent("iphone-h264MP4.mp4")
            let compact = directory.appendingPathComponent("iphone-compactMP4.mp4")
            let regularSize = try regular.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            let compactSize = try compact.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            print("iPhone bytes: regular \(regularSize), compact \(compactSize)")
            precondition(compactSize < regularSize, "Compact preset did not reduce iPhone output size")
            let comparison = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-i", regular.path, "-i", compact.path,
                "-lavfi", "ssim", "-an", "-f", "null", "-"])
            print(comparison.standardError.split(separator: "\n").filter { $0.contains("SSIM") }.joined(separator: "\n"))
            let after = SHA256.hash(data: try Data(contentsOf: source))
            precondition(before == after, "iPhone source changed")
        }
        var definition = GeneratorDefinition()
        definition.kind = .solidColor
        definition.width = 320; definition.height = 180; definition.frameRate = 30
        definition.duration = ProjectTime(seconds: 1.2)
        var record = definition.assetRecord()
        record.generator = nil
        record.hasAudio = true
        let hdrSource = directory.appendingPathComponent("hlg.mov")
        record.originalPath = hdrSource.path
        var project = TrimatoProject(name: "Compact export check")
        project.format = ProjectFormat(mode: .custom, width: 320, height: 180, frameRate: 30)
        project.media = [record]
        _ = try project.append(asset: record)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Caption")])
        let projectOutput = directory.appendingPathComponent("project-compact.mp4")
        try await ProjectExporter.export(project: project, mediaURLs: [record.id: hdrSource],
            timeRange: ProjectTimeRange(start: ProjectTime(seconds: 0.3), duration: ProjectTime(seconds: 0.6)),
            format: .compactMP4, to: projectOutput, audioMode: .highQualityStereo, progress: { _ in }, preserveHDR: true)
        try await verify(projectOutput, video: true, hdr: false, duration: 0.6)
        print("PASS HDR project compact export with captions and selected range")
        UserDefaults.standard.setVolatileDomain([AppPreferenceKey.preserveHDR: false], forName: UserDefaults.argumentDomain)
        let standardOutput = directory.appendingPathComponent("hdr-setting-off.mp4")
        try await ClipExporter.export(asset: AVURLAsset(url: directory.appendingPathComponent("hlg.mov")), sourceRanges: ranges,
            sourceContentType: .quickTimeMovie, format: .hevcMP4, to: standardOutput, preserveSpatialAudio: false, progress: { _ in })
        try await verify(standardOutput, video: true, hdr: false, duration: 0.6)
        precondition(!AppPreferences.preserveHDR(), "Export changed preference")
        do {
            try VideoColorPolicy.hlg.validate(format: .h264MP4)
            preconditionFailure("Project HDR validation was bypassed")
        } catch { }
        print("PASS preference disabled and project validation unchanged")
    }

    static func verify(_ url: URL, video: Bool, hdr: Bool, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let actualDuration = try await asset.load(.duration).seconds
        precondition(abs(actualDuration - duration) < 0.12, "Incorrect duration: \(actualDuration)")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(!audioTracks.isEmpty, "Missing audio")
        if video {
            let policy = try await VideoColorPolicy.resolve(asset: asset, preserveHDR: true)
            precondition(policy == (hdr ? .hlg : .sdr), "Incorrect color range")
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let description = try await track.load(.formatDescriptions).first!
            if !hdr {
                let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                precondition(transfer == AVVideoTransferFunction_ITU_R_709_2, "Missing SDR color information")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            precondition(reader.startReading())
            var frames = 0
            var variedFrame = false
            while let sample = output.copyNextSampleBuffer() {
                frames += 1
                let buffer = CMSampleBufferGetImageBuffer(sample)!
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var low: UInt8 = 255, high: UInt8 = 0
                for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 4) {
                    for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 4) {
                        let value = bytes[y * stride + x * 4]
                        low = min(low, value); high = max(high, value)
                    }
                }
                variedFrame = variedFrame || Int(high) - Int(low) > 20
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            precondition(reader.status == .completed && frames >= 12 && variedFrame, "Invalid decoded video")
        }
        let reader = try AVAssetReader(asset: asset)
        let audio = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(audio)
        precondition(reader.startReading())
        var samples = 0
        while let sample = audio.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
        precondition(reader.status == .completed && samples > 10_000, "Invalid decoded audio")
    }
}
