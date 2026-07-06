import Foundation

struct LLMResult: Equatable {
    let text: String
    let latencyMS: Int
}

enum OpenAIClientError: Error, LocalizedError {
    case invalidBaseURL
    case emptyResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid LLM base URL."
        case .emptyResponse:
            return "The LLM response did not contain text."
        case let .httpError(code, body):
            return "LLM HTTP \(code): \(body)"
        }
    }
}

final class OpenAIClient {
    func complete(
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        timeout: Double
    ) async throws -> LLMResult {
        guard let endpoint = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw OpenAIClientError.invalidBaseURL
        }

        let started = ContinuousClock.now
        let body = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0.1,
            topP: 0.9,
            maxTokens: maxTokens,
            stream: false,
            chatTemplateKwargs: ChatTemplateKwargs(enableThinking: false)
        )

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.httpError(http.statusCode, bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let text = decoded.choices.first?.message?.content ?? decoded.choices.first?.text ?? ""
        let cleaned = TextUtilities.normalized(text)
        let elapsed = started.duration(to: ContinuousClock.now)
        let latency = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)

        return LLMResult(text: cleaned, latencyMS: latency)
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let topP: Double
    let maxTokens: Int
    let stream: Bool
    let chatTemplateKwargs: ChatTemplateKwargs?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case stream
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatTemplateKwargs: Encodable {
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage?
        let text: String?
    }
}
