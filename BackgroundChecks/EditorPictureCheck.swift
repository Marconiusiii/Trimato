import AVFoundation
import AppKit
import SwiftUI
import Foundation
@testable import Trimato

@main struct EditorPictureCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "EditorPicture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { print("Editor picture check failed: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let projectURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: projectURL.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(TrimatoProject.self, from: data)
        let urls = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, URL(fileURLWithPath: $0.originalPath)) })
        print("Project: \(project.name), duration \(project.duration.seconds)")
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls, purpose: .preview)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        print("Spatial: \(result.spatialAudio != nil); remapped preview: \(result.spatialPlaybackAsset != nil)")
        try await inspect("base", asset: result.composition, composition: result.videoComposition)
        try await inspect("preview", asset: result.playbackAsset, composition: result.playbackVideoComposition)
        for time in [1.0, 7.5, 11, 16] {
            let baseline = try await frame("base", asset: result.composition, composition: result.videoComposition, at: time)
            let preview = try await frame("preview", asset: result.playbackAsset, composition: result.playbackVideoComposition, at: time)
            try require(baseline.2 > 0 && preview.2 > 0, "Missing picture at \(time)")
            try require(abs(baseline.0 - preview.0) < 1 && abs(baseline.1 - preview.1) < 2,
                        "Preview picture differs from the edited timeline at \(time)")
        }
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(asset: result.playbackAsset)
        item.videoComposition = result.playbackVideoComposition
        item.appliesPerFrameHDRDisplayMetadata = false
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player.replaceCurrentItem(with: item)
        let direct = PlayerNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        direct.playerLayer.player = player
        direct.layoutSubtreeIfNeeded()
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600000), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .seconds(1))
        print("Detached player: item status \(item.status.rawValue), error \(String(describing: item.error)), view \(direct.bounds), layer \(direct.playerLayer.frame), attached \(direct.playerLayer.superlayer != nil), displayReady \(direct.playerLayer.isReadyForDisplay)")
        try require(direct.playerLayer.isReadyForDisplay, "Player layer has no displayable video")
        for seconds in [1.0, 6.7, 7.5, 9.3, 11, 13.2, 16] {
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600000), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            var received = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(50))
                let position = player.currentTime()
                if let buffer = output.copyPixelBuffer(forItemTime: position, itemTimeForDisplay: nil) {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let row = CVPixelBufferGetBytesPerRow(buffer)
                    var maximum: UInt8 = 0
                    for y in stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 30) {
                        for x in stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 30) {
                            maximum = max(maximum, bytes[y * row + x * 4], bytes[y * row + x * 4 + 1], bytes[y * row + x * 4 + 2])
                        }
                    }
                    try require(maximum > 10, "AVPlayer returned black video at \(position.seconds)")
                    if position.seconds >= seconds + 0.25 {
                        print("AVPlayer advanced from \(seconds) to \(position.seconds), picture max=\(maximum)")
                        received = true
                        break
                    }
                }
            }
            player.pause()
            guard received else { throw NSError(domain: "EditorPicture", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVPlayer did not deliver picture near \(seconds)"]) }
        }
        player.replaceCurrentItem(with: nil)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let model = ProjectPlayerViewModel()
        let hosting = NSHostingView(rootView: ViewerProbe(controller: controller, model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }
        func visit(_ view: NSView) {
            if let video = view as? PlayerNSView {
                print("Hosted Editor: view \(video.frame), bounds \(video.bounds), layer \(video.playerLayer.frame), attached \(video.playerLayer.superlayer != nil)")
            }
            for child in view.subviews { visit(child) }
        }
        visit(hosting)
        try require(try Data(contentsOf: projectURL.appendingPathComponent("project.json")) == data, "Saved project changed")
        print("Project unchanged: true")
        print("No windows opened and no frames saved or displayed by this check.")
    }
    static func inspect(_ label: String, asset: AVAsset, composition: AVVideoComposition?) async throws {
        for track in try await asset.loadTracks(withMediaType: .video) {
            print("\(label) video id=\(track.trackID) enabled=\(try await track.load(.isEnabled)) size=\(try await track.load(.naturalSize)) range=\(try await track.load(.timeRange))")
            if let compositionTrack = track as? AVCompositionTrack {
                print("source segments: \(try await compositionTrack.load(.segments).count)")
            }
        }
        guard let composition else { print("\(label) has no video composition"); return }
        let duration = try await asset.load(.duration)
        print("\(label) asset duration=\(duration.seconds), instruction end=\(composition.instructions.last?.timeRange.end.seconds ?? -1)")
        let valid = composition.isValid(for: try await asset.load(.tracks), assetDuration: duration,
            timeRange: CMTimeRange(start: .zero, duration: duration), validationDelegate: nil)
        print("\(label) valid=\(valid)")
        try require(valid, "\(label) has invalid picture instructions")
        for instruction in composition.instructions {
            guard let instruction = instruction as? AVVideoCompositionInstruction else { continue }
            print("\(label) instruction: \(instruction.timeRange.start.seconds)..\(instruction.timeRange.end.seconds), passthrough=\(instruction.passthroughTrackID), layers=\(instruction.layerInstructions.map(\.trackID))")
            for layer in instruction.layerInstructions {
                var a = CGAffineTransform.identity, b = a, interval = CMTimeRange.invalid
                let transform = layer.getTransformRamp(for: instruction.timeRange.start, start: &a, end: &b, timeRange: &interval)
                var x: Float = 1, y: Float = 1
                let opacity = layer.getOpacityRamp(for: instruction.timeRange.start, startOpacity: &x, endOpacity: &y, timeRange: &interval)
                print(" transform \(transform): \(a), opacity \(opacity): \(x) -> \(y)")
            }
        }
    }
    static func frame(_ label: String, asset: AVAsset, composition: AVVideoComposition?, at time: Double) async throws -> (Double, Int, Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.appliesPreferredTrackTransform = true
        let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600000))
        let image = result.image
        let width = 64, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let stats = bytes.withUnsafeMutableBytes { buffer -> (Double, Int, Int) in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = buffer.bindMemory(to: UInt8.self)
            var sum = 0, bright = 0, maximum = 0
            for i in stride(from: 0, to: values.count, by: 4) {
                let value = max(Int(values[i]), Int(values[i+1]), Int(values[i+2]))
                sum += value; maximum = max(maximum, value); if value > 10 { bright += 1 }
            }
            return (Double(sum) / Double(width * height), maximum, bright)
        }
        print("\(label) at \(time): mean=\(stats.0), max=\(stats.1), nonblack=\(stats.2)")
        return stats
    }
}

private struct ViewerProbe: View {
    @Namespace var links
    let controller: ProjectController
    let model: ProjectPlayerViewModel
    var body: some View {
        MacEditorPane("Editor") {
            ProjectViewerView(controller: controller, openClipEditor: { _ in }, workspacePaneLinks: links, viewModel: model)
        }
    }
}
