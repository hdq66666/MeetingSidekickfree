import Foundation

enum ASRClientError: Error, LocalizedError {
    case invalidURL
    case missingWorkspace
    case missingAPIKey
    case disconnected
    case unrecognizedMessage
    case invalidHotwordsEndpoint
    case invalidHotwordsResponse
    case hotwordsRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid ASR WebSocket URL."
        case .missingWorkspace: "Aliyun workspace ID is required."
        case .missingAPIKey: "Aliyun ASR API key is required."
        case .disconnected: "ASR WebSocket disconnected."
        case .unrecognizedMessage: "ASR WebSocket returned an unsupported message."
        case .invalidHotwordsEndpoint: "Invalid Aliyun ASR hotwords endpoint."
        case .invalidHotwordsResponse: "Aliyun ASR hotwords returned an unsupported response."
        case let .hotwordsRequestFailed(message): "Aliyun ASR hotwords request failed: \(message)"
        }
    }
}

struct ASRConnectionSettings {
    let backend: ASRBackend
    let localURL: String
    let aliyunEndpoint: String
    let aliyunAPIKey: String
    let aliyunModel: String
    let language: String
    let hotwords: String
    let streamName: String
    let speakerName: String?
}

final class ASRWebSocketClient {
    var onEvent: ((ASREvent) -> Void)?
    var onError: ((Error) -> Void)?
    var onLog: ((APILogLevel, String, String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var settings: ASRConnectionSettings?
    private var taskID: String?
    private var readyToSendAudio = false
    private var pendingAudioFrames: [Data] = []
    private var sentAudioFrameCount = 0
    private var isClosing = false
    private var reportedConnectionFailure = false
    private var connectionID = UUID()
    private var refreshWorkItem: DispatchWorkItem?
    private var aliyunVocabularyTask: Task<Void, Never>?
    private var aliyunVocabularyID: String?
    private var localSnapshotReconciler = LocalFunASRSnapshotReconciler()
    private let sendQueue = DispatchQueue(label: "MeetingSidekickfree.ASRWebSocket.send")
    private let aliyunRefreshInterval: TimeInterval = 270

    func connect(settings: ASRConnectionSettings) throws {
        self.settings = settings
        isClosing = false
        reportedConnectionFailure = false

        switch settings.backend {
        case .localFunASR:
            try connectLocal(settings: settings)
        case .aliyunCloud:
            try connectAliyun(settings: settings)
        }
    }

    private func connectLocal(settings: ASRConnectionSettings) throws {
        guard let url = URL(string: settings.localURL) else {
            throw ASRClientError.invalidURL
        }

        log(.info, logSource, "connect local \(settings.localURL)")
        close()
        isClosing = false
        reportedConnectionFailure = false
        connectionID = UUID()
        let connectionID = connectionID
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        readyToSendAudio = true
        task.resume()
        sendControl("START")
        let cleanedLanguage = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedLanguage.isEmpty {
            sendControl("LANGUAGE:\(cleanedLanguage)")
        }
        let cleanedHotwords = ASRHotwordFormatter.normalizedInput(settings.hotwords)
        if !cleanedHotwords.isEmpty {
            sendControl("HOTWORDS:\(cleanedHotwords)")
        }
        receiveLoop(connectionID: connectionID)
    }

    private func connectAliyun(settings: ASRConnectionSettings) throws {
        guard !settings.aliyunEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRClientError.missingWorkspace
        }
        guard let url = URL(string: settings.aliyunEndpoint) else {
            throw ASRClientError.invalidURL
        }

        let apiKey = settings.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ASRClientError.missingAPIKey
        }

        log(.info, logSource, "connect aliyun \(settings.aliyunEndpoint)")
        close()
        isClosing = false
        reportedConnectionFailure = false
        connectionID = UUID()
        let connectionID = connectionID
        let taskID = UUID().uuidString
        self.taskID = taskID
        readyToSendAudio = false

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        prepareAliyunHotwordsThenRunTask(settings: settings, taskID: taskID, connectionID: connectionID)
        receiveLoop(connectionID: connectionID)
    }

    func sendPCM(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self, let task = self.task else { return }
            guard self.readyToSendAudio else {
                self.pendingAudioFrames.append(data)
                if self.pendingAudioFrames.count > 80 {
                    self.pendingAudioFrames.removeFirst(self.pendingAudioFrames.count - 80)
                }
                if self.pendingAudioFrames.count == 1 || self.pendingAudioFrames.count % 20 == 0 {
                    self.log(.warning, self.logSource, "queue audio frames until task-started: \(self.pendingAudioFrames.count)")
                }
                return
            }
            self.sentAudioFrameCount += 1
            if self.sentAudioFrameCount == 1 || self.sentAudioFrameCount % 20 == 0 {
                self.log(.send, self.logSource, "audio frame #\(self.sentAudioFrameCount), \(data.count) bytes")
            }
            let connectionID = self.connectionID
            task.send(.data(data)) { [weak self] error in
                if let error {
                    self?.handleConnectionFailure(error, context: "send audio failed", connectionID: connectionID)
                }
            }
        }
    }

    func close() {
        isClosing = true
        reportedConnectionFailure = false
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        aliyunVocabularyTask?.cancel()
        aliyunVocabularyTask = nil
        deleteAliyunVocabularyIfNeeded()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        taskID = nil
        readyToSendAudio = false
        sentAudioFrameCount = 0
        localSnapshotReconciler.reset()
        sendQueue.async { [weak self] in
            self?.pendingAudioFrames.removeAll()
        }
    }

    func stopSessionThenClose(after delay: TimeInterval = 0.8) {
        isClosing = true
        switch settings?.backend {
        case .aliyunCloud:
            sendAliyunFinishTask()
        case .localFunASR, .none:
            sendControl("STOP")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.close()
        }
    }

    private func sendControl(_ text: String) {
        log(.send, logSource, abbreviated(text, limit: 900))
        let connectionID = connectionID
        task?.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleConnectionFailure(error, context: "send control failed", connectionID: connectionID)
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        sendControl(text)
    }

    private func prepareAliyunHotwordsThenRunTask(settings: ASRConnectionSettings, taskID: String, connectionID: UUID) {
        let entries = ASRHotwordFormatter.entries(from: settings.hotwords)
        guard !entries.isEmpty else {
            sendAliyunRunTask(settings: settings, taskID: taskID, vocabularyID: nil)
            return
        }

        guard Self.modelSupportsAliyunHotwords(settings.aliyunModel) else {
            log(.warning, logSource, "ignore hotwords: Aliyun hotwords require Fun-ASR or Paraformer model")
            sendAliyunRunTask(settings: settings, taskID: taskID, vocabularyID: nil)
            return
        }

        log(.info, logSource, "create aliyun hotwords vocabulary: \(entries.count) words, weight=4")
        aliyunVocabularyTask?.cancel()
        aliyunVocabularyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let vocabularyID = try await self.createAliyunVocabulary(settings: settings, entries: entries)
                guard connectionID == self.connectionID, self.taskID == taskID, !Task.isCancelled else {
                    try? await Self.deleteAliyunVocabulary(settings: settings, vocabularyID: vocabularyID)
                    return
                }
                self.aliyunVocabularyID = vocabularyID
                self.log(.info, self.logSource, "aliyun hotwords vocabulary ready: \(vocabularyID)")
                self.sendAliyunRunTask(settings: settings, taskID: taskID, vocabularyID: vocabularyID)
            } catch {
                self.handleConnectionFailure(error, context: "prepare aliyun hotwords failed", connectionID: connectionID)
            }
        }
    }

    private func sendAliyunRunTask(settings: ASRConnectionSettings, taskID: String, vocabularyID: String?) {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000
        ]

        if let vocabularyID, !vocabularyID.isEmpty {
            parameters["vocabulary_id"] = vocabularyID
        }

        let cleanedLanguage = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedLanguage.isEmpty {
            parameters["language_hints"] = [Self.aliyunLanguageHint(from: cleanedLanguage)]
        }

        sendJSON([
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": settings.aliyunModel,
                "parameters": parameters,
                "input": [:]
            ]
        ])
    }

    private func createAliyunVocabulary(settings: ASRConnectionSettings, entries: [ASRHotwordEntry]) async throws -> String {
        let response = try await Self.sendAliyunVocabularyRequest(
            settings: settings,
            input: [
                "action": "create_vocabulary",
                "target_model": settings.aliyunModel,
                "prefix": "msfree",
                "vocabulary": entries.map(\.aliyunPayload)
            ]
        )
        guard let output = response["output"] as? [String: Any],
              let vocabularyID = output["vocabulary_id"] as? String,
              !vocabularyID.isEmpty else {
            throw ASRClientError.invalidHotwordsResponse
        }

        try await waitUntilAliyunVocabularyReady(settings: settings, vocabularyID: vocabularyID)
        return vocabularyID
    }

    private func waitUntilAliyunVocabularyReady(settings: ASRConnectionSettings, vocabularyID: String) async throws {
        for attempt in 0..<6 {
            let response = try await Self.sendAliyunVocabularyRequest(
                settings: settings,
                input: [
                    "action": "query_vocabulary",
                    "vocabulary_id": vocabularyID
                ]
            )
            guard let output = response["output"] as? [String: Any],
                  let status = output["status"] as? String else {
                throw ASRClientError.invalidHotwordsResponse
            }

            if status == "OK" {
                return
            }
            if attempt == 5 {
                throw ASRClientError.hotwordsRequestFailed("vocabulary status is \(status)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func deleteAliyunVocabularyIfNeeded() {
        guard let vocabularyID = aliyunVocabularyID else { return }
        aliyunVocabularyID = nil
        guard let settings, settings.backend == .aliyunCloud else { return }
        log(.info, logSource, "delete aliyun hotwords vocabulary: \(vocabularyID)")
        Task.detached {
            try? await Self.deleteAliyunVocabulary(settings: settings, vocabularyID: vocabularyID)
        }
    }

    private static func deleteAliyunVocabulary(settings: ASRConnectionSettings, vocabularyID: String) async throws {
        _ = try await sendAliyunVocabularyRequest(
            settings: settings,
            input: [
                "action": "delete_vocabulary",
                "vocabulary_id": vocabularyID
            ]
        )
    }

    private static func sendAliyunVocabularyRequest(settings: ASRConnectionSettings, input: [String: Any]) async throws -> [String: Any] {
        guard let url = aliyunHotwordsURL(from: settings.aliyunEndpoint) else {
            throw ASRClientError.invalidHotwordsEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "speech-biasing",
            "input": input
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ASRClientError.hotwordsRequestFailed(body)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASRClientError.invalidHotwordsResponse
        }
        if let code = object["code"] as? String, !code.isEmpty {
            let message = object["message"] as? String ?? code
            throw ASRClientError.hotwordsRequestFailed(message)
        }
        return object
    }

    private static func aliyunHotwordsURL(from websocketEndpoint: String) -> URL? {
        var endpoint = websocketEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.hasPrefix("wss://") {
            endpoint = "https://" + String(endpoint.dropFirst(6))
        } else if endpoint.hasPrefix("ws://") {
            endpoint = "http://" + String(endpoint.dropFirst(5))
        }

        if let range = endpoint.range(of: "/api-ws/v1/inference/") {
            endpoint.replaceSubrange(range, with: "/api/v1/services/audio/asr/customization")
        } else if let range = endpoint.range(of: "/api-ws/v1/inference") {
            endpoint.replaceSubrange(range, with: "/api/v1/services/audio/asr/customization")
        } else {
            endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/api/v1/services/audio/asr/customization"
        }
        return URL(string: endpoint)
    }

    private static func modelSupportsAliyunHotwords(_ model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("fun-asr") || normalized.contains("paraformer")
    }

    private static func aliyunLanguageHint(from language: String) -> String {
        switch language.lowercased() {
        case "中文", "chinese", "zh", "zh-cn", "cn":
            return "zh"
        case "英文", "english", "en", "en-us":
            return "en"
        default:
            return language
        }
    }

    private func sendAliyunFinishTask() {
        guard let taskID else { return }
        sendJSON([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ])
    }

    private func receiveLoop(connectionID: UUID) {
        guard connectionID == self.connectionID else { return }
        task?.receive { [weak self] result in
            guard let self else { return }
            guard connectionID == self.connectionID else { return }

            switch result {
            case let .success(message):
                do {
                    try self.handle(message)
                    self.receiveLoop(connectionID: connectionID)
                } catch {
                    self.onError?(error)
                    self.receiveLoop(connectionID: connectionID)
                }

            case let .failure(error):
                self.handleConnectionFailure(error, context: "connection failed", connectionID: connectionID)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        switch message {
        case let .string(text):
            log(.receive, logSource, abbreviated(text, limit: 1_200))
            handleControlEvent(jsonString: text)
            emitParsedEvents(jsonString: text)

        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw ASRClientError.unrecognizedMessage
            }
            log(.receive, logSource, abbreviated(text, limit: 1_200))
            handleControlEvent(jsonString: text)
            emitParsedEvents(jsonString: text)

        @unknown default:
            throw ASRClientError.unrecognizedMessage
        }
    }

    private func emitParsedEvents(jsonString: String) {
        let events: [ASREvent]
        if settings?.backend == .localFunASR,
           let response = LocalFunASRResponse.parse(jsonString: jsonString) {
            events = localSnapshotReconciler.events(for: response)
        } else {
            events = ASREvent.parseEvents(jsonString: jsonString)
        }

        for var event in events {
            event.streamName = settings?.streamName
            event.speaker = settings?.speakerName
            onEvent?(event)
        }
    }

    private func handleControlEvent(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let header = dictionary["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return
        }

        switch event {
        case "task-started":
            readyToSendAudio = true
            log(.info, logSource, "task-started")
            scheduleAliyunRefreshIfNeeded()
            flushPendingAudioFrames()
        case "task-failed":
            let message = (dictionary["payload"] as? [String: Any])?["message"] as? String
                ?? header["error_message"] as? String
                ?? "Aliyun ASR task failed."
            if shouldReconnectAfterTaskFailure(message) {
                log(.warning, logSource, "task failed; reconnecting: \(message)")
                reconnectAliyun(reason: "task failed")
            } else {
                handleConnectionFailure(ASRClientErrorMessage(message), context: "task failed")
            }
        default:
            break
        }
    }

    private func flushPendingAudioFrames() {
        sendQueue.async { [weak self] in
            guard let self, let task = self.task else { return }
            let frames = self.pendingAudioFrames
            self.pendingAudioFrames.removeAll()
            if !frames.isEmpty {
                self.log(.send, self.logSource, "flush queued audio frames: \(frames.count)")
            }
            let connectionID = self.connectionID
            for frame in frames {
                task.send(.data(frame)) { [weak self] error in
                    if let error {
                        self?.handleConnectionFailure(error, context: "flush audio failed", connectionID: connectionID)
                    }
                }
            }
        }
    }

    private func scheduleAliyunRefreshIfNeeded() {
        guard settings?.backend == .aliyunCloud else { return }
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reconnectAliyun(reason: "scheduled refresh")
        }
        refreshWorkItem = item
        sendQueue.asyncAfter(deadline: .now() + aliyunRefreshInterval, execute: item)
    }

    private func shouldReconnectAfterTaskFailure(_ message: String) -> Bool {
        guard settings?.backend == .aliyunCloud else { return false }
        let lowered = message.lowercased()
        return lowered.contains("timeout") || lowered.contains("response stream")
    }

    private func reconnectAliyun(reason: String) {
        guard !isClosing, settings?.backend == .aliyunCloud, let settings else { return }
        log(.warning, logSource, "reconnect aliyun stream: \(reason)")
        close()
        do {
            try connect(settings: settings)
        } catch {
            handleConnectionFailure(error, context: "reconnect failed")
        }
    }

    private func handleConnectionFailure(_ error: Error, context: String, connectionID: UUID? = nil) {
        if let connectionID, connectionID != self.connectionID {
            return
        }
        guard !isClosing, !reportedConnectionFailure else { return }
        reportedConnectionFailure = true
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        readyToSendAudio = false
        task = nil
        log(.error, logSource, "\(context): \(error.localizedDescription)")
        onError?(error)
    }

    private func log(_ level: APILogLevel, _ source: String, _ message: String) {
        onLog?(level, source, message)
    }

    private func abbreviated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    private var logSource: String {
        guard let streamName = settings?.streamName, !streamName.isEmpty else {
            return "ASR"
        }
        return "ASR \(streamName)"
    }
}

private struct ASRClientErrorMessage: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
