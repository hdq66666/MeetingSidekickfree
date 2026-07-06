import Foundation

enum AudioMixSource {
    case microphone
    case systemAudio
}

final class PCM16AudioMixer {
    var onFrame: ((Data) -> Void)?

    private let samplesPerFrame = 1_600
    private let maxQueuedSamples = 32_000
    private let queue = DispatchQueue(label: "MeetingSidekickfree.PCM16AudioMixer")
    private var timer: DispatchSourceTimer?
    private var microphoneSamples: [Int16] = []
    private var systemSamples: [Int16] = []

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                self?.emitMixedFrame()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func append(_ data: Data, source: AudioMixSource) {
        guard !data.isEmpty else { return }
        let samples = Self.samples(from: data)
        guard !samples.isEmpty else { return }

        queue.async {
            switch source {
            case .microphone:
                self.microphoneSamples.append(contentsOf: samples)
                self.trimQueue(&self.microphoneSamples)
            case .systemAudio:
                self.systemSamples.append(contentsOf: samples)
                self.trimQueue(&self.systemSamples)
            }
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            microphoneSamples.removeAll(keepingCapacity: false)
            systemSamples.removeAll(keepingCapacity: false)
        }
    }

    private func emitMixedFrame() {
        guard !microphoneSamples.isEmpty || !systemSamples.isEmpty else { return }

        let microphone = popSamples(from: &microphoneSamples, count: samplesPerFrame)
        let system = popSamples(from: &systemSamples, count: samplesPerFrame)
        var mixed = [Int16]()
        mixed.reserveCapacity(samplesPerFrame)

        for index in 0..<samplesPerFrame {
            let microphoneSample = Int(microphone[index])
            let systemSample = Int(system[index])
            let sum = microphoneSample + systemSample
            let clamped = min(Int(Int16.max), max(Int(Int16.min), sum))
            mixed.append(Int16(clamped))
        }

        let data = Self.data(from: mixed)
        if !data.isEmpty {
            onFrame?(data)
        }
    }

    private func popSamples(from samples: inout [Int16], count: Int) -> [Int16] {
        if samples.count >= count {
            let result = Array(samples.prefix(count))
            samples.removeFirst(count)
            return result
        }

        var result = samples
        result.append(contentsOf: repeatElement(0, count: count - samples.count))
        samples.removeAll(keepingCapacity: true)
        return result
    }

    private func trimQueue(_ samples: inout [Int16]) {
        guard samples.count > maxQueuedSamples else { return }
        samples.removeFirst(samples.count - maxQueuedSamples)
    }

    private static func samples(from data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)

        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(after: index)
            guard next < data.endIndex else { break }
            let low = UInt16(data[index])
            let high = UInt16(data[next]) << 8
            samples.append(Int16(bitPattern: low | high))
            index = data.index(after: next)
        }

        return samples
    }

    private static func data(from samples: [Int16]) -> Data {
        let littleEndianSamples = samples.map(\.littleEndian)
        return littleEndianSamples.withUnsafeBytes { Data($0) }
    }
}
