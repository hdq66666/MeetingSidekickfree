import Foundation

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let speaker: String?
    let startMS: Int?
    let endMS: Int?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        speaker: String? = nil,
        startMS: Int? = nil,
        endMS: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.startMS = startMS
        self.endMS = endMS
        self.createdAt = createdAt
    }
}

enum AnswerLane: String, CaseIterable, Identifiable {
    case current
    case history500
    case answerMemory
    case fusion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current Segment"
        case .history500: "500 chars history"
        case .answerMemory: "10 answer turns"
        case .fusion: "Decision Output"
        }
    }

    var subtitle: String {
        switch self {
        case .current: "Lowest latency"
        case .history500: "Context fill"
        case .answerMemory: "Avoid repetition"
        case .fusion: "Final display"
        }
    }
}

enum CandidateStatus: Equatable {
    case idle
    case running
    case complete
    case skipped
    case failed(String)

    var title: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .complete: "done"
        case .skipped: "empty"
        case .failed: "failed"
        }
    }
}

struct CandidateAnswer: Identifiable, Equatable {
    let id = UUID()
    let lane: AnswerLane
    var text: String = ""
    var latencyMS: Int?
    var status: CandidateStatus = .idle
}

struct AnswerTurn: Identifiable, Equatable {
    let id: UUID
    let segment: TranscriptSegment
    let historyCharacterLimit: Int
    let answerHistoryLimit: Int
    var candidates: [AnswerLane: CandidateAnswer]
    var finalText: String = ""
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        segment: TranscriptSegment,
        historyCharacterLimit: Int = 500,
        answerHistoryLimit: Int = 10
    ) {
        self.id = id
        self.segment = segment
        self.historyCharacterLimit = historyCharacterLimit
        self.answerHistoryLimit = answerHistoryLimit
        self.candidates = Dictionary(
            uniqueKeysWithValues: AnswerLane.allCases.map { lane in
                (lane, CandidateAnswer(lane: lane))
            }
        )
    }
}

enum APILogLevel: String, Equatable {
    case info = "INFO"
    case send = "SEND"
    case receive = "RECV"
    case warning = "WARN"
    case error = "ERR"
}

enum APILogOutputLevel: String, Codable, CaseIterable, Identifiable {
    case all
    case errorsOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .errorsOnly: "Errors Only"
        }
    }

    func includes(_ level: APILogLevel) -> Bool {
        switch self {
        case .all:
            return true
        case .errorsOnly:
            return level == .error
        }
    }
}

struct APILogEntry: Identifiable, Equatable {
    let id = UUID()
    let createdAt: Date
    let level: APILogLevel
    let source: String
    let message: String

    init(level: APILogLevel, source: String, message: String, createdAt: Date = Date()) {
        self.level = level
        self.source = source
        self.message = message
        self.createdAt = createdAt
    }
}

struct ASREvent: Equatable {
    var text: String
    var stable: Bool
    var speaker: String?
    var startMS: Int?
    var endMS: Int?
    var streamName: String?

    var fingerprint: String {
        [
            streamName ?? "",
            String(startMS ?? -1),
            String(endMS ?? -1),
            text.lowercased()
        ].joined(separator: "|")
    }

    static func parseEvents(jsonString: String) -> [ASREvent] {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return []
        }

        var events: [ASREvent] = []

        events.append(contentsOf: parseAliyunEvents(from: dictionary))

        if let sentences = dictionary["sentences"] as? [[String: Any]] {
            for sentence in sentences {
                let text = extractText(from: sentence)
                guard !text.isEmpty else { continue }
                events.append(
                    ASREvent(
                        text: text,
                        stable: true,
                        speaker: sentence["spk"] as? String ?? sentence["speaker"] as? String,
                        startMS: intValue(sentence["start"]),
                        endMS: intValue(sentence["end"])
                    )
                )
            }
        }

        if let partial = dictionary["partial"] as? String {
            let cleaned = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                events.append(
                    ASREvent(
                        text: cleaned,
                        stable: false,
                        speaker: dictionary["spk"] as? String ?? dictionary["speaker"] as? String,
                        startMS: intValue(dictionary["partial_start_ms"]),
                        endMS: nil
                    )
                )
            }
        }

        let textKeys = ["text", "sentence", "transcript", "result", "content"]
        let text = textKeys
            .compactMap { dictionary[$0] as? String }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else { return events }

        let stable =
            (dictionary["stable"] as? Bool) ??
            (dictionary["is_final"] as? Bool) ??
            (dictionary["final"] as? Bool) ??
            (dictionary["done"] as? Bool) ??
            ((dictionary["mode"] as? String) == "2pass-offline")

        events.append(
            ASREvent(
                text: text,
                stable: stable,
                speaker: dictionary["speaker"] as? String,
                startMS: intValue(dictionary["start_ms"] ?? dictionary["start"]),
                endMS: intValue(dictionary["end_ms"] ?? dictionary["end"])
            )
        )
        return events
    }

    private static func extractText(from dictionary: [String: Any]) -> String {
        let textKeys = ["text", "sentence", "transcript", "result", "content"]
        return textKeys
            .compactMap { dictionary[$0] as? String }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func parseAliyunEvents(from dictionary: [String: Any]) -> [ASREvent] {
        guard let header = dictionary["header"] as? [String: Any],
              let event = header["event"] as? String,
              event == "result-generated" else {
            return []
        }

        guard let payload = dictionary["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any] else {
            return []
        }

        if let sentence = output["sentence"] as? [String: Any] {
            return eventFromAliyunSentence(sentence).map { [$0] } ?? []
        }

        if let sentences = output["sentences"] as? [[String: Any]] {
            return sentences.compactMap(eventFromAliyunSentence)
        }

        let text = extractText(from: output)
        guard !text.isEmpty else { return [] }
        return [
            ASREvent(
                text: text,
                stable: boolValue(output["sentence_end"]) ?? boolValue(output["is_final"]) ?? boolValue(output["final"]) ?? false,
                speaker: output["speaker"] as? String,
                startMS: intValue(output["begin_time"] ?? output["start_time"] ?? output["start"]),
                endMS: intValue(output["end_time"] ?? output["end"])
            )
        ]
    }

    private static func eventFromAliyunSentence(_ sentence: [String: Any]) -> ASREvent? {
        let text = extractText(from: sentence)
        guard !text.isEmpty else { return nil }
        return ASREvent(
            text: text,
            stable: boolValue(sentence["sentence_end"]) ?? boolValue(sentence["is_final"]) ?? boolValue(sentence["final"]) ?? false,
            speaker: sentence["speaker"] as? String,
            startMS: intValue(sentence["begin_time"] ?? sentence["start_time"] ?? sentence["start"]),
            endMS: intValue(sentence["end_time"] ?? sentence["end"])
        )
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let int = value as? Int {
            return int != 0
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
