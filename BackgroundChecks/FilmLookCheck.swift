import AppKit
import AVFoundation
import CoreImage
import Foundation
@testable import Trimato

@main struct FilmLookCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "FilmLookCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func pixels(_ url: URL) async throws -> [UInt8] {
        let result = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-i", url.path,
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
        return Array(result.standardOutput)
    }
    static func chroma(_ values: [UInt8]) -> Double {
        var sum = 0.0
        for y in 64..<128 { for x in 0..<256 {
            let index = (y * 256 + x) * 3
            let rgb = values[index..<index+3]
            sum += Double(rgb.max()! - rgb.min()!)
        }}
        return sum / (64 * 256)
    }
    static func gray(_ values: [UInt8], at x: Int) -> Double {
        let index = (32 * 256 + x) * 3
        return (Double(values[index]) + Double(values[index+1]) + Double(values[index+2])) / 3
    }
    static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }
    static func filter(_ kind: ClipFilterKind, amount: Double, enabled: Bool = true) -> ClipFilter {
        var result = ClipFilter(kind: kind); result.values["amount"] = amount; result.enabled = enabled
        return result
    }
    static func floatingPointChecks() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let samples: [Float] = [0.06,0.06,0.06,1, 0.6,0.6,0.6,1, 0.4,0.22,0.16,1,
                                0.15,0.32,0.23,1, 2,2,2,1, 3,3,3,1, 0.2,0.1,0.05,0.5, 0,0,0,0]
        let data = samples.withUnsafeBytes { Data($0) }
        let source = CIImage(bitmapData: data, bytesPerRow: samples.count * 4, size: CGSize(width: 8, height: 1),
                             format: .RGBAf, colorSpace: space)
        for kind in [ClipFilterKind.bleachBypass, .technicolor] {
            var previousDistance = 0.0
            for amount in [0.0, 50, 100] {
                let image = HDRVideoRenderer.apply(filter(kind, amount: amount), to: source)
                var actual = [Float](repeating: 0, count: samples.count)
                context.render(image, toBitmap: &actual, rowBytes: samples.count * 4,
                               bounds: source.extent, format: .RGBAf, colorSpace: space)
                try require(actual.allSatisfy(\.isFinite), "Non-finite HDR pixels")
                for index in stride(from: 3, to: actual.count, by: 4) {
                    try require(abs(actual[index] - samples[index]) < 0.0001, "Alpha changed")
                }
                let difference = zip(actual, samples).reduce(0.0) { $0 + Double(abs($1.0-$1.1)) }
                if amount == 0 { try require(difference < 0.0001, "Zero Amount changed HDR pixels") }
                else {
                    try require(difference > previousDistance, "Amount did not increase HDR effect strength")
                    try require(actual[0] < samples[0] && actual[4] > samples[4], "HDR contrast direction is wrong")
                    try require(actual[16] > 1 && actual[20] > actual[16], "HDR highlights clipped to SDR white")
                    let separation = actual[8] - actual[10]
                    try require(kind == .bleachBypass ? separation < samples[8]-samples[10] : separation > samples[8]-samples[10],
                                "HDR color separation is wrong")
                    for index in [0,4,16,20] {
                        try require(abs(actual[index]-actual[index+1]) < 0.0001 && abs(actual[index]-actual[index+2]) < 0.0001,
                                    "Neutral HDR grays acquired a color cast")
                    }
                }
                previousDistance = difference
            }
        }
        var shifted = filter(.technicolor, amount: 100)
        shifted.values["cyanOffset"] = 3; shifted.values["magentaOffset"] = -2
        var shiftedPixels = [Float](repeating: 0, count: samples.count)
        context.render(HDRVideoRenderer.apply(shifted, to: source), toBitmap: &shiftedPixels,
                       rowBytes: samples.count*4, bounds: source.extent, format: .RGBAf, colorSpace: space)
        for index in stride(from: 3, to: samples.count, by: 4) {
            try require(abs(shiftedPixels[index]-samples[index]) < 0.0001, "HDR offsets moved transparency")
        }
        print("PASS: HDR float pixels preserve alpha and extended highlights; zero is identity; strength, neutral grays, contrast and color separation checked")
    }
    static func offsetChecks(source: URL) async throws {
        let ids = ["cyanOffset", "magentaOffset", "yellowOffset"]
        try require(FilmLook.offsetDescription(0) == "Centered" && FilmLook.offsetDescription(-1) == "1 pixel left"
                    && FilmLook.offsetDescription(2) == "2 pixels right", "Offset wording is wrong")
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        var samples: [Float] = []
        for x in 0..<64 { samples += [Float(x)/32, Float((x*3)%64)/32, Float((x*7)%64)/32, 1] }
        let image = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: 64*16,
                            size: CGSize(width: 64, height: 1), format: .RGBAf, colorSpace: space)
        func render(_ effect: ClipFilter) -> [Float] {
            var output = [Float](repeating: 0, count: 256)
            let result = HDRVideoRenderer.apply(effect, to: image)
            precondition(result.extent == image.extent)
            context.render(result, toBitmap: &output, rowBytes: 64*16, bounds: image.extent, format: .RGBAf, colorSpace: space)
            return output
        }
        func sdr(_ effect: ClipFilter) async throws -> [UInt16] {
            let output = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-i", source.path,
                "-vf", effect.graph, "-frames:v", "1", "-pix_fmt", "rgb48le", "-f", "rawvideo", "pipe:1"])
            let bytes = Array(output.standardOutput)
            return stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8 }
        }
        let centered = filter(.technicolor, amount: 100)
        let reference = render(centered)
        let sdrReference = try await sdr(centered)
        for (channel, key) in ids.enumerated() {
            for offset in [-20, -3, 3, 20] {
                var shifted = centered; shifted.values[key] = Double(offset)
                let actual = render(shifted)
                for x in 0..<64 { for component in 0..<4 {
                    let sourceX = component == channel ? min(max(x-offset, 0), 63) : x
                    try require(abs(actual[x*4+component]-reference[sourceX*4+component]) < 0.0001,
                                "HDR offset failed: channel=\(channel), offset=\(offset), x=\(x), component=\(component), actual=\(actual[x*4+component]), expected=\(reference[sourceX*4+component])")
                }}
                let actualSDR = try await sdr(shifted)
                for y in [16, 80] { for x in 0..<256 { for component in 0..<3 {
                    let sourceX = component == channel ? min(max(x-offset, 0), 255) : x
                    let expected = sdrReference[(y*256+sourceX)*3+component]
                    try require(abs(Int(actualSDR[(y*256+x)*3+component])-Int(expected)) <= 1,
                                "SDR offset direction, edge extension or channel isolation failed")
                }}}
                let restored = try JSONDecoder().decode(ClipFilter.self, from: JSONEncoder().encode(shifted))
                try require(restored == shifted, "Offset did not survive saving")
                shifted.values["amount"] = 0
                let zero = render(shifted)
                try require(zip(zero,samples).allSatisfy { abs($0-$1) < 0.0001 }, "Zero strength retained an offset")
            }
        }
        var old = ClipFilter(kind: .technicolor); old.values = ["amount": 50]
        try require(ids.allSatisfy { old.value($0) == 0 }, "Old settings do not default to centered")
        print("PASS: all three offsets at +/-3 and +/-20 pixels; exact horizontal direction, unaffected channels, edge extension, HDR highlights, saved offsets and zero-strength identity; plain-language values")
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        precondition(NSApp == nil)
        try floatingPointChecks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-film-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ppm = directory.appendingPathComponent("chart.ppm")
        var data = Data("P6\n256 128\n255\n".utf8)
        let colors: [[UInt8]] = [[165,90,70],[75,155,95],[85,95,165],[165,145,70],
                                [80,155,160],[155,90,150],[180,135,110],[110,120,140]]
        for y in 0..<128 { for x in 0..<256 {
            data.append(contentsOf: y < 64 ? [UInt8(x),UInt8(x),UInt8(x)] : colors[x/32])
        }}
        try data.write(to: ppm)
        let source = directory.appendingPathComponent("chart.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-loop", "1", "-framerate", "8", "-i", ppm.path,
            "-t", "1", "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv444p10le", "-c:v", "prores_ks", "-profile:v", "4",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", source.path])
        try await offsetChecks(source: source)
        let originalBytes = try Data(contentsOf: source)
        let baseline = try await ClipFilterRenderer.render(source: source, filters: [], audio: false, duration: 1)
        let baselinePixels = try await pixels(baseline)
        try require(baselinePixels.count == 256 * 128 * 3, "Unexpected chart dimensions")
        for kind in [ClipFilterKind.bleachBypass, .technicolor] {
            var previous = 0.0
            for amount in [0.0, 50, 100] {
                let effect = filter(kind, amount: amount)
                try effect.validate()
                let output = try await ClipFilterRenderer.render(source: source, filters: [effect], audio: false, duration: 1)
                let actual = try await pixels(output)
                let report = try await FFmpegMediaProbe.inspect(url: output)
                try require(report.videoStream?.width == 256 && report.videoStream?.height == 128 && abs(report.duration - 1) < 0.01,
                            "Filter changed geometry or duration")
                let delta = distance(actual, baselinePixels)
                if amount == 0 { try require(delta == 0, "Zero Amount was not an exact decoded-pixel bypass") }
                else {
                    try require(delta > previous, "Amount did not increase SDR effect strength")
                    try require(gray(actual, at: 64) < gray(baselinePixels, at: 64) && gray(actual, at: 192) > gray(baselinePixels, at: 192),
                                "SDR contrast direction is wrong")
                    try require(kind == .bleachBypass ? chroma(actual) < chroma(baselinePixels) : chroma(actual) > chroma(baselinePixels),
                                "SDR color separation is wrong")
                    for x in stride(from: 16, to: 240, by: 16) {
                        let i = (32 * 256 + x) * 3
                        try require(abs(Int(actual[i])-Int(actual[i+1])) <= 2 && abs(Int(actual[i])-Int(actual[i+2])) <= 2, "Neutral SDR gray acquired a cast")
                    }
                }
                previous = delta
                print("\(kind.title) Amount \(amount): mean pixel change \(delta), chroma \(chroma(actual))")
            }
            let bypassed = filter(kind, amount: 83, enabled: false)
            let output = try await ClipFilterRenderer.render(source: source, filters: [bypassed], audio: false, duration: 1)
            let bypassedPixels = try await pixels(output)
            try require(bypassedPixels == baselinePixels, "Disabled filter changed pixels")
            let restored = try JSONDecoder().decode(ClipFilter.self, from: JSONEncoder().encode(bypassed))
            try require(restored == bypassed, "Saved bypass/amount did not round-trip")
            var invalid = bypassed; invalid.values["amount"] = 101
            do { try invalid.validate(); throw NSError(domain: "Missing validation", code: 1) }
            catch let error as MediaSourceError { _ = error }
        }
        print("PASS: SDR production renders, zero/disabled bypass, strength, neutral grays, color/contrast direction, geometry, duration and saved settings")
        let hdr = try await HDRVideoRenderer.render(source: source, policy: .hlg)
        for kind in [ClipFilterKind.bleachBypass, .technicolor] {
            let output = try await ClipFilterRenderer.render(source: hdr, filters: [filter(kind, amount: 50)], audio: false, duration: 1)
            let report = try await FFmpegMediaProbe.inspect(url: output)
            try require(report.isHDR && report.videoStream?.colorPrimaries == "bt2020" && report.videoStream?.colorTransfer == "arib-std-b67",
                        "HDR output lost its color metadata")
            try require(abs(report.duration - 1) < 0.01 && report.videoStream?.width == 256 && report.videoStream?.height == 128,
                        "HDR output changed geometry or duration")
            let decoded = try await pixels(output)
            try require(decoded.count == baselinePixels.count, "HDR export did not decode")
        }
        let alphaSource = directory.appendingPathComponent("alpha-source.mov")
        _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-i", source.path,
            "-vf", "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/(W-1)',format=yuva444p10le",
            "-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", alphaSource.path])
        func alpha(_ url: URL) async throws -> [UInt8] {
            Array(try await FFmpegRunner.run(tool: .ffmpeg, arguments: ["-v", "error", "-nostdin", "-i", url.path,
                "-vf", "alphaextract", "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"]).standardOutput)
        }
        let sourceAlpha = try await alpha(alphaSource)
        for kind in [ClipFilterKind.bleachBypass, .technicolor] {
            var effect = filter(kind, amount: 100)
            if kind == .technicolor { effect.values["cyanOffset"] = 20; effect.values["yellowOffset"] = -20 }
            let output = try await ClipFilterRenderer.render(source: alphaSource, filters: [effect], audio: false, duration: 1)
            let outputAlpha = try await alpha(output)
            try require(outputAlpha.count == sourceAlpha.count && zip(outputAlpha,sourceAlpha).allSatisfy { abs(Int($0)-Int($1)) <= 1 },
                        "Encoded filter output changed the transparency mask")
        }
        print("PASS: both production SDR filters preserve encoded transparency; shifted HDR colors leave the original alpha mask in place")
        var project = TrimatoProject(name: "Film look export check")
        project.format = ProjectFormat(mode: .custom, width: 256, height: 128, frameRate: 8)
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 1)))
        let record = MediaAssetRecord(name: "Chart", originalPath: source.path, duration: ProjectTime(seconds: 1),
            naturalWidth: 256, naturalHeight: 128, frameRate: 8, hasAudio: false, sourceEdit: [segment], playbackMode: .nativePassthrough)
        project.media = [record]
        let clipID = try project.append(asset: record)
        var effect = filter(.technicolor, amount: 75)
        effect.values["cyanOffset"] = -3; effect.values["magentaOffset"] = 2; effect.values["yellowOffset"] = 1
        try project.setClipEffects(id: clipID, audio: nil, filters: [effect])
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        try require(reopened.timelineClip(id: clipID)?.filters == [effect], "Project did not preserve effect controls")
        let preview = try await ClipFilterRenderer.render(source: source, filters: [effect], audio: false, duration: 1)
        let exported = directory.appendingPathComponent("project-export.mov")
        try await ProjectExporter.export(project: reopened, mediaURLs: [record.id: source], format: .proRes422HQ,
                                         to: exported, progress: { _ in }, preserveHDR: true)
        let exportedPixels = try await pixels(exported)
        let previewPixels = try await pixels(preview)
        let exportDifference = distance(exportedPixels, previewPixels)
        try require(exportedPixels.count == previewPixels.count && exportDifference < 4,
                    "Project export differs excessively from clip preview: \(exportDifference)")
        print("PASS: saved project reopened with offsets and strength; finished project export matches clip preview within codec tolerance (mean difference \(exportDifference)/255)")
        let finalBytes = try Data(contentsOf: source)
        try require(finalBytes == originalBytes, "Source file changed")
        precondition(NSApp == nil)
        print("PASS: both filters rendered through production HDR routing; HDR tags and timing preserved; source unchanged; no app, windows or audio playback")
        print("Artifacts: \(directory.path)")
    }
}
