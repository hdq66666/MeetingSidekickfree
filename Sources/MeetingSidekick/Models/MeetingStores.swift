import Foundation

@MainActor
final class TranscriptStore: ObservableObject {
    @Published var livePartials: [String: TranscriptSegment] = [:]
    @Published var transcript: [TranscriptSegment] = []

    func clear() {
        livePartials.removeAll()
        transcript.removeAll()
    }

    func clearPartial(for key: String) {
        var partials = livePartials
        partials[key] = nil
        livePartials = partials
    }

    func setPartial(_ segment: TranscriptSegment, for key: String) {
        var partials = livePartials
        partials[key] = segment
        livePartials = partials
    }

    func clearPartials(where shouldClear: (String) -> Bool) {
        livePartials = livePartials.filter { !shouldClear($0.key) }
    }

    func prependFinal(_ segment: TranscriptSegment, limit: Int) {
        var segments = transcript
        segments.insert(segment, at: 0)
        if segments.count > limit {
            segments.removeLast(segments.count - limit)
        }
        transcript = segments
    }
}

@MainActor
final class AnswerStore: ObservableObject {
    @Published var answerTurns: [AnswerTurn] = []

    func clear() {
        answerTurns.removeAll()
    }

    func prepend(_ turn: AnswerTurn, limit: Int) {
        var turns = answerTurns
        turns.insert(turn, at: 0)
        if turns.count > limit {
            turns.removeLast(turns.count - limit)
        }
        answerTurns = turns
    }

    func setCandidate(
        turnID: UUID,
        lane: AnswerLane,
        text: String? = nil,
        latencyMS: Int? = nil,
        status: CandidateStatus
    ) {
        var turns = answerTurns
        guard let turnIndex = turns.firstIndex(where: { $0.id == turnID }) else { return }
        var candidate = turns[turnIndex].candidates[lane] ?? CandidateAnswer(lane: lane)
        if let text {
            candidate.text = text
        }
        if let latencyMS {
            candidate.latencyMS = latencyMS
        }
        candidate.status = status
        turns[turnIndex].candidates[lane] = candidate
        answerTurns = turns
    }

    func setFinalText(turnID: UUID, text: String) {
        var turns = answerTurns
        guard let turnIndex = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[turnIndex].finalText = TextUtilities.normalized(text)
        answerTurns = turns
    }
}

@MainActor
final class APILogStore: ObservableObject {
    @Published var entries: [APILogEntry] = []

    func append(_ entry: APILogEntry, limit: Int) {
        var newEntries = entries
        newEntries.insert(entry, at: 0)
        if newEntries.count > limit {
            newEntries.removeLast(newEntries.count - limit)
        }
        entries = newEntries
    }

    func clear() {
        entries.removeAll()
    }
}

struct AudioLevelSnapshot: Equatable {
    static let floorDB: Double = -60
    static let ceilingDB: Double = 0
    static let silent = AudioLevelSnapshot(rmsDB: floorDB, peakDB: floorDB)

    let rmsDB: Double
    let peakDB: Double

    var rmsLevel: Double {
        Self.normalizedLevel(from: rmsDB)
    }

    var peakLevel: Double {
        Self.normalizedLevel(from: peakDB)
    }

    var peakText: String {
        peakDB <= Self.floorDB ? "-inf" : "\(Int(peakDB.rounded())) dB"
    }

    static func normalizedLevel(from db: Double) -> Double {
        let clamped = min(Self.ceilingDB, max(Self.floorDB, db))
        return (clamped - Self.floorDB) / (Self.ceilingDB - Self.floorDB)
    }
}

@MainActor
final class AudioLevelStore: ObservableObject {
    @Published var microphone = AudioLevelSnapshot.silent

    func setMicrophone(_ snapshot: AudioLevelSnapshot) {
        microphone = snapshot
    }

    func resetMicrophone() {
        microphone = .silent
    }
}

final class AudioLevelReporter: @unchecked Sendable {
    private let minEmitInterval: TimeInterval = 0.05
    private let floorAmplitude = pow(10, AudioLevelSnapshot.floorDB / 20)
    private let store: AudioLevelStore
    private let lock = NSLock()
    private var lastEmit = Date.distantPast

    init(store: AudioLevelStore) {
        self.store = store
    }

    func ingestPCM16(_ data: Data) {
        guard let snapshot = Self.snapshot(fromPCM16: data, floorAmplitude: floorAmplitude) else { return }

        let now = Date()
        lock.lock()
        let shouldEmit = now.timeIntervalSince(lastEmit) >= minEmitInterval
        if shouldEmit {
            lastEmit = now
        }
        lock.unlock()

        guard shouldEmit else { return }
        let store = store
        Task { @MainActor in
            store.setMicrophone(snapshot)
        }
    }

    func reset() {
        lock.lock()
        lastEmit = .distantPast
        lock.unlock()
        let store = store
        Task { @MainActor in
            store.resetMicrophone()
        }
    }

    private static func snapshot(fromPCM16 data: Data, floorAmplitude: Double) -> AudioLevelSnapshot? {
        guard data.count >= 2 else { return nil }

        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0

        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let sampleTotal = data.count / 2
            for index in 0..<sampleTotal {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: low | high)
                let amplitude = min(1.0, abs(Double(sample)) / 32768.0)
                peak = max(peak, amplitude)
                sumSquares += amplitude * amplitude
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return AudioLevelSnapshot(
            rmsDB: dbFS(max(rms, floorAmplitude)),
            peakDB: dbFS(max(peak, floorAmplitude))
        )
    }

    private static func dbFS(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, .leastNonzeroMagnitude))
    }
}
