import Foundation

enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case microphoneAndSystem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        case .microphoneAndSystem: "Mic + System"
        }
    }
}

enum ASRBackend: String, Codable, CaseIterable, Identifiable {
    case aliyunCloud
    case localFunASR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aliyunCloud: "Aliyun Cloud"
        case .localFunASR: "Local FunASR"
        }
    }
}

struct AppConfig: Codable, Equatable {
    static let defaultAliyunWorkspaceID = ""
    static let defaultAliyunASRModel = "fun-asr-realtime"

    var asrBackend: ASRBackend = .aliyunCloud
    var asrWebSocketURL: String = "ws://127.0.0.1:10095"
    var aliyunASRAPIKey: String = ""
    var aliyunWorkspaceID: String = AppConfig.defaultAliyunWorkspaceID
    var aliyunASRModel: String = ""
    var asrLanguage: String = ""
    var asrHotwords: String = ""
    var llmBaseURL: String = "http://127.0.0.1:8000/v1"
    var llmAPIKey: String = ""
    var llmModel: String = ""
    var audioSource: AudioSource = .microphoneAndSystem
    var lockMicrophoneInputDevice: Bool = false
    var enableMicrophoneVoiceEnhancement: Bool = true
    var microphoneSpeakerName: String = ""
    var systemAudioSpeakerName: String = ""
    var systemPrompt: String = AppConfig.defaultSystemPrompt
    var maxHistoryCharacters: Int = 500
    var maxAnswerHistory: Int = 10
    var minSegmentCharacters: Int = 6
    var maxCompletionTokens: Int = 220
    var requestTimeoutSeconds: Double = 3.5
    var enableFusionLane: Bool = true
    var enableTranscriptAutosave: Bool = false
    var enableAPILogOutput: Bool = true
    var apiLogOutputLevel: APILogOutputLevel = .errorsOnly

    static let defaultSystemPrompt = "You are a real-time meeting observer assistant. Answer only the current explicit question, or supplement with facts, definitions, risks, or next steps directly relevant to the ongoing discussion. Do not fabricate real-time information; state uncertainty if there is no basis. Keep responses concise, preferably within three sentences. Do not elaborate on the reasoning process. Do not summarize the entire meeting. Return an empty string if the input is not a question and no supplementation is needed."
    private static let legacyDefaultSystemPrompt = "你是实时会议旁听助手。只回答当前明确问题，或补充对当前讨论直接有用的事实、定义、风险、下一步。不要编造实时信息；没有依据就说不确定。回答要短，优先 3 句内。不要展开推理过程。不要总结整场会议。若输入不是问题且无需补充，返回空字符串。"

    private static let defaultsKey = "MeetingSidekickfree.AppConfig.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asrBackend = try container.decodeIfPresent(ASRBackend.self, forKey: .asrBackend) ?? .aliyunCloud
        asrWebSocketURL = try container.decodeIfPresent(String.self, forKey: .asrWebSocketURL) ?? "ws://127.0.0.1:10095"
        aliyunASRAPIKey = try container.decodeIfPresent(String.self, forKey: .aliyunASRAPIKey) ?? ""
        aliyunWorkspaceID = try container.decodeIfPresent(String.self, forKey: .aliyunWorkspaceID) ?? AppConfig.defaultAliyunWorkspaceID
        aliyunASRModel = try container.decodeIfPresent(String.self, forKey: .aliyunASRModel) ?? ""
        asrLanguage = try container.decodeIfPresent(String.self, forKey: .asrLanguage) ?? ""
        asrHotwords = try container.decodeIfPresent(String.self, forKey: .asrHotwords) ?? ""
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? "http://127.0.0.1:8000/v1"
        llmAPIKey = try container.decodeIfPresent(String.self, forKey: .llmAPIKey) ?? ""
        let decodedLLMModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
        llmModel = decodedLLMModel == "qwen3.6-27b" ? "" : decodedLLMModel
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .microphoneAndSystem
        lockMicrophoneInputDevice = try container.decodeIfPresent(Bool.self, forKey: .lockMicrophoneInputDevice) ?? false
        enableMicrophoneVoiceEnhancement = try container.decodeIfPresent(Bool.self, forKey: .enableMicrophoneVoiceEnhancement) ?? true
        microphoneSpeakerName = try container.decodeIfPresent(String.self, forKey: .microphoneSpeakerName) ?? ""
        systemAudioSpeakerName = try container.decodeIfPresent(String.self, forKey: .systemAudioSpeakerName) ?? ""
        let decodedSystemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? AppConfig.defaultSystemPrompt
        systemPrompt = decodedSystemPrompt == AppConfig.legacyDefaultSystemPrompt ? AppConfig.defaultSystemPrompt : decodedSystemPrompt
        maxHistoryCharacters = try container.decodeIfPresent(Int.self, forKey: .maxHistoryCharacters) ?? 500
        maxAnswerHistory = try container.decodeIfPresent(Int.self, forKey: .maxAnswerHistory) ?? 10
        minSegmentCharacters = try container.decodeIfPresent(Int.self, forKey: .minSegmentCharacters) ?? 6
        maxCompletionTokens = try container.decodeIfPresent(Int.self, forKey: .maxCompletionTokens) ?? 220
        requestTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds) ?? 3.5
        enableFusionLane = try container.decodeIfPresent(Bool.self, forKey: .enableFusionLane) ?? true
        enableTranscriptAutosave = try container.decodeIfPresent(Bool.self, forKey: .enableTranscriptAutosave) ?? false
        enableAPILogOutput = try container.decodeIfPresent(Bool.self, forKey: .enableAPILogOutput) ?? true
        apiLogOutputLevel = try container.decodeIfPresent(APILogOutputLevel.self, forKey: .apiLogOutputLevel) ?? .errorsOnly
    }

    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: AppConfig.defaultsKey)
    }

    var effectiveAliyunWorkspaceID: String {
        Self.normalizedAliyunWorkspaceID(aliyunWorkspaceID)
    }

    var aliyunASREndpoint: String {
        guard !effectiveAliyunWorkspaceID.isEmpty else { return "" }
        return "wss://\(effectiveAliyunWorkspaceID).cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
    }

    var effectiveAliyunASRModel: String {
        let cleaned = aliyunASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? Self.defaultAliyunASRModel : cleaned
    }

    static func normalizedAliyunWorkspaceID(_ rawValue: String) -> String {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "llm-" else { return "" }
        return cleaned.hasPrefix("llm-") ? cleaned : "llm-\(cleaned)"
    }
}
