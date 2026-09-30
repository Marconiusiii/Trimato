import AVFoundation
import Foundation

/// A static digital plate response: input diffusion feeds two cross-coupled,
/// damped allpass tanks. Generated off the main actor and convolved by FFmpeg.
/// Topology reference: Dattorro, Effect Design Part 1 (1997), also described at
/// https://faustlibraries.grame.fr/libs/reverbs/#dattorro-reverb
/// This is an independent implementation, not a recording of a physical plate.
nonisolated enum PlateReverb {
    private struct Delay {
        var samples: [Double]
        var index = 0
        init(_ length: Int) { samples = Array(repeating: 0, count: max(1, length)) }
        mutating func tick(_ input: Double) -> Double {
            let output = samples[index]
            samples[index] = input
            index = (index + 1) % samples.count
            return output
        }
        mutating func allpass(_ input: Double, gain: Double) -> Double {
            let delayed = samples[index]
            let stored = input - gain * delayed
            _ = tick(stored)
            return delayed + gain * stored
        }
        func tap(_ distance: Int) -> Double {
            samples[(index + samples.count - min(distance, samples.count)) % samples.count]
        }
    }

    static func response(filter: ClipFilter, sampleRate: Int) throws -> [Float] {
        try filter.validate()
        guard (8_000...192_000).contains(sampleRate) else {
            throw MediaSourceError.unreadable("Plate Reverb could not process this sample rate. Convert the audio to a sample rate between 8000 and 192000 Hz.")
        }
        let length = filter.value("length")
        let rate = Double(sampleRate)
        func scaled(_ samples: Int) -> Int { max(1, Int((Double(samples) * rate / 29_761).rounded())) }
        var diffusion = [142, 107, 379, 277].map { Delay(scaled($0)) }
        var leftAP1 = Delay(scaled(672)), rightAP1 = Delay(scaled(908))
        var leftDelay = Delay(scaled(4453)), rightDelay = Delay(scaled(4217))
        var leftAP2 = Delay(scaled(1800)), rightAP2 = Delay(scaled(2656))
        var leftEnd = Delay(scaled(3720)), rightEnd = Delay(scaled(3163))
        // Keep the tank dense and stable. Shape its static response with an
        // explicit decay envelope so short Length settings aren't dominated
        // by the allpass filters' own ringing time.
        let leftGain = 0.995, rightGain = 0.995
        let cutoff = 1_500 * pow(10, filter.value("brightness") / 100)
        let damping = exp(-2 * .pi * min(cutoff, rate * 0.45) / rate)
        var leftFeedback = 0.0, rightFeedback = 0.0
        var leftLow = 0.0, rightLow = 0.0, inputLow = 0.0
        let bandwidth = damping
        let count = Int(ceil((length * 2 + 0.25) * rate))
        var result = [Float](repeating: 0, count: count)
        let taps = [266, 2974, 1913, 1996, 1990, 187, 1066].map(scaled)
        for frame in 0..<count {
            if frame % 4096 == 0 { try Task.checkCancellation() }
            inputLow = (1 - bandwidth) * (frame == 0 ? 1 : 0) + bandwidth * inputLow
            var input = inputLow
            for stage in diffusion.indices {
                input = diffusion[stage].allpass(input, gain: stage < 2 ? 0.75 : 0.625)
            }
            let left = leftDelay.tick(leftAP1.allpass(input + rightFeedback * rightGain, gain: -0.7))
            let right = rightDelay.tick(rightAP1.allpass(input + leftFeedback * leftGain, gain: -0.7))
            leftLow = (1 - damping) * left + damping * leftLow
            rightLow = (1 - damping) * right + damping * rightLow
            leftFeedback = leftEnd.tick(leftAP2.allpass(leftLow, gain: 0.5))
            rightFeedback = rightEnd.tick(rightAP2.allpass(rightLow, gain: 0.5))
            let pickup = leftDelay.tap(taps[0]) + leftDelay.tap(taps[1]) - leftAP2.tap(taps[2])
                + leftEnd.tap(taps[3]) - rightDelay.tap(taps[4]) - rightAP2.tap(taps[5]) - rightEnd.tap(taps[6])
            result[frame] = Float(pickup * exp(-6.907755 * Double(frame) / rate / length))
        }
        // Normalize once, independent of Amount, for a useful and repeatable wet level.
        let energy = result.reduce(0.0) { $0 + Double($1) * Double($1) }
        let gain = 1 / sqrt(max(energy, 1e-20))
        let fadeFrames = max(1, Int(rate * 0.02))
        for frame in result.indices {
            if frame % 4096 == 0 { try Task.checkCancellation() }
            let fade = min(1, Double(count - 1 - frame) / Double(fadeFrames))
            result[frame] *= Float(gain * fade)
        }
        return result
    }

    static func writeResponse(filter: ClipFilter, sampleRate: Int, to url: URL) throws {
        let samples = try response(filter: filter, sampleRate: sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Input 1 is the temporary response prepared by ClipFilterRenderer.
    static func graph(filter: ClipFilter) -> String {
        let wet = filter.value("amount") / 100
        guard wet > 0 else { return "anull" }
        let key = "plate" + filter.id.uuidString.replacingOccurrences(of: "-", with: "")
        return "asplit=2[\(key)d][\(key)w];[\(key)w][1:a:0]afir=dry=1:wet=1:irnorm=-1:irgain=1:irfmt=mono:minp=64:maxp=512[\(key)r];[\(key)d][\(key)r]amix=inputs=2:duration=first:normalize=0:weights='\(1 - wet) \(wet)'"
    }
}
