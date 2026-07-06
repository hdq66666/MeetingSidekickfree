import Foundation

final class MicrophoneVoiceEnhancer {
    private let lock = NSLock()
    private let highPassAlpha: Double
    private var previousInput = 0.0
    private var previousHighPass = 0.0
    private var previousEmphasisInput = 0.0
    private var smoothedGain = 1.0

    init(sampleRate: Double = PCM16Converter.sampleRate, highPassCutoff: Double = 90.0) {
        let dt = 1.0 / sampleRate
        let rc = 1.0 / (2.0 * Double.pi * highPassCutoff)
        highPassAlpha = rc / (rc + dt)
    }

    func process(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }

        lock.lock()
        defer { lock.unlock() }

        let samples = decodeSamples(from: data)
        guard !samples.isEmpty else { return data }

        var processed = [Double]()
        processed.reserveCapacity(samples.count)
        var squareSum = 0.0

        for sample in samples {
            let input = Double(sample) / 32768.0
            let highPassed = highPassAlpha * (previousHighPass + input - previousInput)
            previousInput = input
            previousHighPass = highPassed

            let emphasized = highPassed - 0.28 * previousEmphasisInput
            previousEmphasisInput = highPassed

            processed.append(emphasized)
            squareSum += emphasized * emphasized
        }

        let rms = sqrt(squareSum / Double(processed.count))
        let targetRMS = 0.14
        let desiredGain = rms > 0.000_01 ? min(1.65, max(0.85, targetRMS / rms)) : 1.0
        let smoothing = desiredGain > smoothedGain ? 0.18 : 0.05
        smoothedGain = smoothedGain + (desiredGain - smoothedGain) * smoothing

        var output = [Int16]()
        output.reserveCapacity(processed.count)
        for value in processed {
            let scaled = value * smoothedGain
            let limited = max(-0.98, min(0.98, scaled))
            output.append(Int16((limited * 32767.0).rounded()))
        }

        return encodeSamples(output)
    }

    func reset() {
        lock.lock()
        previousInput = 0.0
        previousHighPass = 0.0
        previousEmphasisInput = 0.0
        smoothedGain = 1.0
        lock.unlock()
    }

    private func decodeSamples(from data: Data) -> [Int16] {
        let sampleCount = data.count / 2
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let offset = index * 2
                let word = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                samples.append(Int16(bitPattern: word))
            }
        }

        return samples
    }

    private func encodeSamples(_ samples: [Int16]) -> Data {
        var littleEndianSamples = samples.map { $0.littleEndian }
        return littleEndianSamples.withUnsafeMutableBytes { Data($0) }
    }
}
