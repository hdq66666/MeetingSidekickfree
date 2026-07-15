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
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var aliyunPreparationTask: Task<Void, Never>?
    private var localSnapshotReconciler = LocalFunASRSnapshotReconciler()
    private let aliyunHotwordManager: AliyunHotwordVocabularyManager
    private let sendQueue = DispatchQueue(label: "MeetingSidekickfree.ASRWebSocket.send")
    private let aliyunRefreshInterval: TimeInterval = 270
    private let maxAliyunReconnectAttempts = 4

    init(aliyunHotwordManager: AliyunHotwordVocabularyManager = AliyunHotwordVocabularyManager()) {
        self.aliyunHotwordManager = aliyunHotwordManager
    }

    func connect(settings: ASRConnectionSettings) throws {
        reconnectAttempt = 0
        try replaceConnection(settings: settings)
    }

    private func replaceConnection(settings: ASRConnectionSettings) throws {
        close()
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
        guard URL(string: settings.aliyunEndpoint) != nil else {
            throw ASRClientError.invalidURL
        }

        let apiKey = settings.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ASRClientError.missingAPIKey
        }

        log(.info, logSource, "connect aliyun \(settings.aliyunEndpoint)")
        connectionID = UUID()
        let connectionID = connectionID
        let taskID = UUID().uuidString
        self.taskID = taskID
        readyToSendAudio = false
        prepareAliyunHotwordsThenOpenConnection(
            settings: settings,
            taskID: taskID,
            connectionID: connectionID
        )
    }

    func sendPCM(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self, !self.isClosing else { return }
            guard let task = self.task, self.readyToSendAudio else {
                self.queuePendingAudioFrame(data)
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

    private func queuePendingAudioFrame(_ data: Data) {
        pendingAudioFrames.append(data)
        if pendingAudioFrames.count > 80 {
            pendingAudioFrames.removeFirst(pendingAudioFrames.count - 80)
        }
        if pendingAudioFrames.count == 1 || pendingAudioFrames.count % 20 == 0 {
            log(.warning, logSource, "queue audio frames until task-started: \(pendingAudioFrames.count)")
        }
    }

    func close() {
        isClosing = true
        reportedConnectionFailure = true
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        aliyunPreparationTask?.cancel()
        aliyunPreparationTask = nil
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

    private func prepareAliyunHotwordsThenOpenConnection(
        settings: ASRConnectionSettings,
        taskID: String,
        connectionID: UUID
    ) {
        let entries = ASRHotwordFormatter.entries(from: settings.hotwords)
        guard !entries.isEmpty else {
            openAliyunConnection(settings: settings, taskID: taskID, connectionID: connectionID, vocabularyID: nil)
            return
        }

        guard Self.modelSupportsAliyunHotwords(settings.aliyunModel) else {
            log(.warning, logSource, "ignore hotwords: Aliyun hotwords require Fun-ASR or Paraformer model")
            openAliyunConnection(settings: settings, taskID: taskID, connectionID: connectionID, vocabularyID: nil)
            return
        }

        log(.info, logSource, "prepare shared aliyun hotwords vocabulary: \(entries.count) words, weight=4")
        let configuration = AliyunHotwordVocabularyConfiguration(settings: settings, entries: entries)
        aliyunPreparationTask?.cancel()
        aliyunPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let vocabularyID = try await self.aliyunHotwordManager.vocabularyID(for: configuration)
                guard self.isCurrentConnection(connectionID: connectionID, taskID: taskID),
                      !Task.isCancelled else { return }
                self.log(.info, self.logSource, "aliyun hotwords vocabulary ready: \(vocabularyID)")
                self.openAliyunConnection(
                    settings: settings,
                    taskID: taskID,
                    connectionID: connectionID,
                    vocabularyID: vocabularyID
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentConnection(connectionID: connectionID, taskID: taskID) else { return }
                self.log(
                    .warning,
                    self.logSource,
                    "prepare aliyun hotwords failed; continue without hotwords: \(self.errorDetails(error))"
                )
                self.openAliyunConnection(
                    settings: settings,
                    taskID: taskID,
                    connectionID: connectionID,
                    vocabularyID: nil
                )
            }
        }
    }

    private func openAliyunConnection(
        settings: ASRConnectionSettings,
        taskID: String,
        connectionID: UUID,
        vocabularyID: String?
    ) {
        guard isCurrentConnection(connectionID: connectionID, taskID: taskID),
              let url = URL(string: settings.aliyunEndpoint) else { return }

        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(settings.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        sendAliyunRunTask(settings: settings, taskID: taskID, vocabularyID: vocabularyID)
        receiveLoop(connectionID: connectionID)
    }

    private func isCurrentConnection(connectionID: UUID, taskID: String) -> Bool {
        !isClosing && connectionID == self.connectionID && taskID == self.taskID
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
                    self.log(.error, self.logSource, "handle message failed: \(self.errorDetails(error))")
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
            reconnectAttempt = 0
            reportedConnectionFailure = false
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
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
                handleConnectionFailure(
                    ASRClientErrorMessage(message),
                    context: "task failed",
                    allowReconnect: false
                )
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
        do {
            try replaceConnection(settings: settings)
        } catch {
            handleConnectionFailure(error, context: "reconnect failed")
        }
    }

    private func handleConnectionFailure(
        _ error: Error,
        context: String,
        connectionID: UUID? = nil,
        allowReconnect: Bool = true
    ) {
        if let connectionID, connectionID != self.connectionID {
            return
        }
        guard !isClosing, !reportedConnectionFailure else { return }
        reportedConnectionFailure = true
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        readyToSendAudio = false
        let failedTask = task
        task = nil
        failedTask?.cancel(with: .goingAway, reason: nil)

        if allowReconnect,
           settings?.backend == .aliyunCloud,
           reconnectAttempt < maxAliyunReconnectAttempts {
            reconnectAttempt += 1
            let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 8.0)
            log(
                .warning,
                logSource,
                "\(context): \(errorDetails(error)); reconnecting in \(Int(delay))s "
                    + "(attempt \(reconnectAttempt)/\(maxAliyunReconnectAttempts))"
            )
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reconnectWorkItem = nil
                self.reconnectAliyun(reason: "transport failure")
            }
            reconnectWorkItem = item
            sendQueue.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }

        log(.error, logSource, "\(context): \(errorDetails(error))")
        onError?(error)
    }

    private func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
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
