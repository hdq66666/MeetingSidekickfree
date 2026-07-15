import Foundation

struct AliyunHotwordVocabularyConfiguration: Hashable, Sendable {
    let endpoint: String
    let apiKey: String
    let model: String
    let entries: [ASRHotwordEntry]

    init(settings: ASRConnectionSettings, entries: [ASRHotwordEntry]) {
        endpoint = settings.aliyunEndpoint
        apiKey = settings.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        model = settings.aliyunModel
        self.entries = entries
    }
}

struct AliyunHotwordVocabularyOperations: Sendable {
    let create: @Sendable (AliyunHotwordVocabularyConfiguration) async throws -> String
    let waitUntilReady: @Sendable (AliyunHotwordVocabularyConfiguration, String) async throws -> Void
    let delete: @Sendable (AliyunHotwordVocabularyConfiguration, String) async throws -> Void

    static let live = AliyunHotwordVocabularyOperations(
        create: { configuration in
            try await AliyunHotwordVocabularyAPI.create(configuration: configuration)
        },
        waitUntilReady: { configuration, vocabularyID in
            try await AliyunHotwordVocabularyAPI.waitUntilReady(
                configuration: configuration,
                vocabularyID: vocabularyID
            )
        },
        delete: { configuration, vocabularyID in
            try await AliyunHotwordVocabularyAPI.delete(
                configuration: configuration,
                vocabularyID: vocabularyID
            )
        }
    )
}

actor AliyunHotwordVocabularyManager {
    private struct CachedVocabulary {
        let configuration: AliyunHotwordVocabularyConfiguration
        let vocabularyID: String
    }

    private struct PendingVocabulary {
        let token: UUID
        let configuration: AliyunHotwordVocabularyConfiguration
        let task: Task<String, Error>
    }

    private struct FailedVocabulary {
        let configuration: AliyunHotwordVocabularyConfiguration
        let message: String
    }

    private let operations: AliyunHotwordVocabularyOperations
    private var cachedVocabulary: CachedVocabulary?
    private var pendingVocabulary: PendingVocabulary?
    private var failedVocabulary: FailedVocabulary?

    init(operations: AliyunHotwordVocabularyOperations = .live) {
        self.operations = operations
    }

    func vocabularyID(for configuration: AliyunHotwordVocabularyConfiguration) async throws -> String {
        if let cachedVocabulary, cachedVocabulary.configuration == configuration {
            return cachedVocabulary.vocabularyID
        }
        if let failedVocabulary, failedVocabulary.configuration == configuration {
            throw ASRClientError.hotwordsRequestFailed(failedVocabulary.message)
        }
        if let pendingVocabulary, pendingVocabulary.configuration == configuration {
            return try await pendingVocabulary.task.value
        }

        try await retireResources(forDifferentConfiguration: configuration)

        let token = UUID()
        let operations = operations
        let task = Task {
            try await Self.createReadyVocabulary(configuration: configuration, operations: operations)
        }
        pendingVocabulary = PendingVocabulary(token: token, configuration: configuration, task: task)

        do {
            let vocabularyID = try await task.value
            guard pendingVocabulary?.token == token else {
                throw CancellationError()
            }
            pendingVocabulary = nil
            cachedVocabulary = CachedVocabulary(configuration: configuration, vocabularyID: vocabularyID)
            return vocabularyID
        } catch {
            if pendingVocabulary?.token == token {
                pendingVocabulary = nil
                failedVocabulary = FailedVocabulary(
                    configuration: configuration,
                    message: Self.hotwordsFailureMessage(error)
                )
            }
            throw error
        }
    }

    @discardableResult
    func reset() async throws -> Bool {
        let pendingVocabulary = pendingVocabulary
        let cachedVocabulary = cachedVocabulary
        self.pendingVocabulary = nil
        self.cachedVocabulary = nil
        failedVocabulary = nil

        var deletedVocabulary = false
        var firstError: Error?

        if let pendingVocabulary {
            do {
                let vocabularyID = try await pendingVocabulary.task.value
                do {
                    try await operations.delete(pendingVocabulary.configuration, vocabularyID)
                    deletedVocabulary = true
                } catch {
                    self.cachedVocabulary = CachedVocabulary(
                        configuration: pendingVocabulary.configuration,
                        vocabularyID: vocabularyID
                    )
                    firstError = error
                }
            } catch {
                // Preparation failures are reported by the clients and clean up after allocation.
            }
        }

        if let cachedVocabulary {
            do {
                try await operations.delete(cachedVocabulary.configuration, cachedVocabulary.vocabularyID)
                deletedVocabulary = true
            } catch {
                self.cachedVocabulary = cachedVocabulary
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
        return deletedVocabulary
    }

    private func retireResources(forDifferentConfiguration configuration: AliyunHotwordVocabularyConfiguration) async throws {
        if let pendingVocabulary, pendingVocabulary.configuration != configuration {
            self.pendingVocabulary = nil
            if let vocabularyID = try? await pendingVocabulary.task.value {
                do {
                    try await operations.delete(pendingVocabulary.configuration, vocabularyID)
                } catch {
                    cachedVocabulary = CachedVocabulary(
                        configuration: pendingVocabulary.configuration,
                        vocabularyID: vocabularyID
                    )
                    throw error
                }
            }
        }

        if let cachedVocabulary, cachedVocabulary.configuration != configuration {
            try await operations.delete(cachedVocabulary.configuration, cachedVocabulary.vocabularyID)
            self.cachedVocabulary = nil
        }

        if failedVocabulary?.configuration != configuration {
            failedVocabulary = nil
        }
    }

    private static func hotwordsFailureMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        let prefix = "Aliyun ASR hotwords request failed: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    private static func createReadyVocabulary(
        configuration: AliyunHotwordVocabularyConfiguration,
        operations: AliyunHotwordVocabularyOperations
    ) async throws -> String {
        let vocabularyID = try await operations.create(configuration)
        do {
            try Task.checkCancellation()
            try await operations.waitUntilReady(configuration, vocabularyID)
            try Task.checkCancellation()
            return vocabularyID
        } catch {
            let preparationError = error
            do {
                try await operations.delete(configuration, vocabularyID)
            } catch {
                throw ASRClientError.hotwordsRequestFailed(
                    "\(preparationError.localizedDescription); cleanup failed: \(error.localizedDescription)"
                )
            }
            throw preparationError
        }
    }
}

private enum AliyunHotwordVocabularyAPI {
    static func create(configuration: AliyunHotwordVocabularyConfiguration) async throws -> String {
        let response = try await sendRequest(
            configuration: configuration,
            input: [
                "action": "create_vocabulary",
                "target_model": configuration.model,
                "prefix": "msfree",
                "vocabulary": configuration.entries.map(\.aliyunPayload)
            ]
        )
        guard let output = response["output"] as? [String: Any],
              let vocabularyID = output["vocabulary_id"] as? String,
              !vocabularyID.isEmpty else {
            throw ASRClientError.invalidHotwordsResponse
        }
        return vocabularyID
    }

    static func waitUntilReady(
        configuration: AliyunHotwordVocabularyConfiguration,
        vocabularyID: String
    ) async throws {
        for attempt in 0..<6 {
            try Task.checkCancellation()
            let response = try await sendRequest(
                configuration: configuration,
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

    static func delete(
        configuration: AliyunHotwordVocabularyConfiguration,
        vocabularyID: String
    ) async throws {
        _ = try await sendRequest(
            configuration: configuration,
            input: [
                "action": "delete_vocabulary",
                "vocabulary_id": vocabularyID
            ]
        )
    }

    private static func sendRequest(
        configuration: AliyunHotwordVocabularyConfiguration,
        input: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = hotwordsURL(from: configuration.endpoint) else {
            throw ASRClientError.invalidHotwordsEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
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

    private static func hotwordsURL(from websocketEndpoint: String) -> URL? {
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
}
