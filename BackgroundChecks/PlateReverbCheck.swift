import AppKit
import AVFoundation
@testable import Trimato

@main struct PlateReverbCheck {
    static func energy(_ samples: [Float], from: Int = 0, to: Int? = nil) -> Double {
        samples[from..<min(to ?? samples.count, samples.count)].reduce(0) { $0 + Double($1) * Double($1) }
    }
    static func main() async throws {
        precondition(NSApp == nil)
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plate-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func samples(_ url: URL, channels: Int = 1, rate: Int = 48000) async throws -> [Float] {
            let decoded = directory.appendingPathComponent(UUID().uuidString + ".f32")
            var arguments = ["-v", "error", "-nostdin", "-y", "-i", url.path, "-map", "0:a:0"]
            // Compare the same channel: a mono-to-stereo project mix should not
            // be summed back to mono with a different downmix gain.
            if channels == 1 { arguments += ["-af", "pan=mono|c0=c0"] }
            arguments += ["-ac", String(channels), "-ar", String(rate), "-f", "f32le", decoded.path]
            _ = try await FFmpegRunner.run(tool: .ffmpeg, arguments: arguments)
            return try Data(contentsOf: decoded).withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
            }
        }
        var plate = ClipFilter(kind: .plateReverb)
        precondition(plate.kind.isAudio && plate.value("length") == 1.8)
        let saved = try JSONEncoder().encode(plate)
        let decodedPlate = try JSONDecoder().decode(ClipFilter.self, from: saved)
        precondition(decodedPlate == plate)
        let old = ClipFilter(kind: .reverb, values: ["room": 2, "amount": 30])
        let decodedOld = try JSONDecoder().decode(ClipFilter.self, from: JSONEncoder().encode(old))
        precondition(decodedOld == old)
        for (key, value) in [("amount", -1.0), ("amount", 101), ("length", 0.0), ("length", 7), ("brightness", 101), ("brightness", Double.nan)] {
            var invalid = plate; invalid.values[key] = value
            do { try invalid.validate(); fatalError("Invalid value accepted") } catch { }
        }
        let initial = try PlateReverb.response(filter: plate, sampleRate: 48000)
        precondition(initial.allSatisfy(\.isFinite) && abs(energy(initial) - 1) < 0.001)
        let repeated = try PlateReverb.response(filter: plate, sampleRate: 48000)
        precondition(initial == repeated, "Non-deterministic response")
        for rate in [44100, 96000, 192000] {
            let response = try PlateReverb.response(filter: plate, sampleRate: rate)
            precondition(response.allSatisfy(\.isFinite) && abs(energy(response) - 1) < 0.001)
        }
        var short = plate; short.values["length"] = 0.3
        var long = plate; long.values["length"] = 4
        let shortResponse = try PlateReverb.response(filter: short, sampleRate: 48000)
        let longResponse = try PlateReverb.response(filter: long, sampleRate: 48000)
        let shortTail = energy(shortResponse, from: 24000)
        let longTail = energy(longResponse, from: 24000)
        precondition(longTail > shortTail * 10, "Length failed to extend decay")
        precondition(shortTail < 0.001, "Short decay retained an overly long tail")
        func differenceEnergy(_ values: [Float]) -> Double {
            zip(values, values.dropFirst()).reduce(0) { $0 + pow(Double($1.0 - $1.1), 2) }
        }
        var dark = plate; dark.values["brightness"] = 0
        var bright = plate; bright.values["brightness"] = 100
        let darkResponse = try PlateReverb.response(filter: dark, sampleRate: 48000)
        let brightResponse = try PlateReverb.response(filter: bright, sampleRate: 48000)
        let darkHigh = differenceEnergy(darkResponse), brightHigh = differenceEnergy(brightResponse)
        precondition(brightHigh > darkHigh * 1.1, "Brightness did not increase high-frequency energy")
        print("PASS: deterministic finite responses at 44.1/48/96/192 kHz; longer decay and brighter spectrum; validated controls; old/new filter round trips. Tail energies \(shortTail), \(longTail); brightness measures \(darkHigh), \(brightHigh)")
        for channels in [1, 2] {
            let source = directory.appendingPathComponent("source-\(channels).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: AVAudioChannelCount(channels))!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) {
                    let time = Double(frame) / 48000
                    buffer.floatChannelData![channel][frame] = channel == 0 && time < 0.5
                        ? Float(0.1 * sin(2 * .pi * 440 * time)) : 0
                }
            }
            try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
            let baseline = try await samples(source, channels: channels)
            var wetOutputs: [[Float]] = []
            for amount in [0.0, 25.0, 100.0] {
                plate.values["amount"] = amount
                let output = try await ClipFilterRenderer.render(source: source, filters: [plate], audio: true, duration: 3)
                defer { try? FileManager.default.removeItem(at: output) }
                let decoded = try await samples(output, channels: channels)
                precondition(decoded.count == baseline.count && decoded.allSatisfy(\.isFinite), "Output duration or samples changed")
                precondition(decoded.allSatisfy { abs($0) < 1 }, "Unexpected clipping on low-level fixture")
                if amount == 0 { precondition(zip(decoded, baseline).allSatisfy { abs($0 - $1) < 1e-6 }, "Zero Amount changed audio") }
                else { wetOutputs.append(decoded) }
                if channels == 2 { precondition(stride(from: 1, to: decoded.count, by: 2).allSatisfy { abs(decoded[$0]) < 1e-7 }, "Channel separation lost") }
            }
            let lowTail = energy(wetOutputs[0], from: 30000 * channels)
            let highTail = energy(wetOutputs[1], from: 30000 * channels)
            precondition(lowTail > 1e-5 && highTail > lowTail * 10, "Amount failed to control tail level")
            plate.enabled = false
            let bypass = try await ClipFilterRenderer.render(source: source, filters: [plate], audio: true, duration: 3)
            defer { try? FileManager.default.removeItem(at: bypass) }
            let bypassed = try await samples(bypass, channels: channels)
            precondition(zip(bypassed, baseline).allSatisfy { abs($0 - $1) < 1e-6 })
            plate.enabled = true
            plate.values["amount"] = 25
            if channels == 1 {
                let filterDirectory = try TemporaryMediaSession.directory(named: "TrimatoClipFilters")
                let before = Set(try FileManager.default.contentsOfDirectory(atPath: filterDirectory.path))
                var echo = ClipFilter(kind: .echo); echo.values["amount"] = 10
                let combined = try await ClipFilterRenderer.render(source: source,
                    filters: [ClipFilter(kind: .reverb), plate, echo], audio: true, duration: 3)
                let combinedSamples = try await samples(combined)
                precondition(combinedSamples.count == baseline.count && combinedSamples.allSatisfy(\.isFinite))
                try FileManager.default.removeItem(at: combined)
                let afterRender = Set(try FileManager.default.contentsOfDirectory(atPath: filterDirectory.path))
                precondition(afterRender == before, "Rendering left a response or output behind")
                let cancelled = Task {
                    try await ClipFilterRenderer.render(source: source, filters: [plate], audio: true, duration: 3)
                }
                cancelled.cancel()
                do { _ = try await cancelled.value; fatalError("Cancelled render completed") } catch is CancellationError { }
                let afterCancel = Set(try FileManager.default.contentsOfDirectory(atPath: filterDirectory.path))
                precondition(afterCancel == before, "Cancelled render left files behind")
                let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)))
                var project = TrimatoProject(name: "Plate persistence")
                let record = MediaAssetRecord(name: "Plate", originalPath: source.path, duration: ProjectTime(seconds: 3), hasAudio: true, sourceEdit: [segment])
                let id = project.putRecording(record, at: .zero)
                try project.setClipEffects(id: id, audio: .neutral, filters: [plate])
                let restored = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
                precondition(restored.timelineClip(id: id)?.filters == [plate])
                let result = try await ProjectCompositionBuilder.build(project: restored, mediaURLs: [record.id: source], purpose: .finalExport)
                defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
                let export = directory.appendingPathComponent("project.wav")
                try await AudioOnlyExporter.export(asset: result.composition, audioMix: result.audioMix,
                    timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 48000)),
                    format: .wav24, to: export, progress: { _ in })
                let actual = try await samples(export)
                precondition(actual.count == wetOutputs[0].count)
                let error = zip(actual, wetOutputs[0]).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(actual.count)
                precondition(error < 1e-8, "Preview/export mismatch: \(error)")
                let range = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 0.25), duration: ProjectTime(seconds: 1)))]
                let trimmed = try await ClipFilterRenderer.render(source: source, filters: [plate], audio: true, duration: 1, segments: range)
                defer { try? FileManager.default.removeItem(at: trimmed) }
                let selected = try await samples(trimmed)
                precondition(selected.count == 48000)
                let reference = wetOutputs[0][12000..<60000]
                precondition(zip(selected, reference).allSatisfy { abs($0 - $1) < 1e-5 }, "Range lost pre-cut reverb history")
            }
        }
        let task = Task.detached {
            var effect = ClipFilter(kind: .plateReverb)
            effect.values["length"] = 6
            return try PlateReverb.response(filter: effect, sampleRate: 192000)
        }
        task.cancel()
        do { _ = try await task.value; fatalError("Cancelled generation completed") } catch is CancellationError { }
        precondition(NSApp == nil)
        print("PASS: mono/stereo renders; exact duration and zero/bypass audio; channel separation; useful Amount range; saved project; preview/final export parity; selected-range history; combined room/plate/echo chain; cancellation and response cleanup. No app or audio playback.")
    }
}
