import Foundation

actor AIService {
    private var config: AIConfig

    init(config: AIConfig = AIConfig()) {
        self.config = config
    }

    func updateConfig(_ config: AIConfig) {
        self.config = config
    }

    func currentConfig() -> AIConfig {
        config
    }

    func isConfigured() -> Bool {
        !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send a chat completion request and return the response text.
    func complete(system: String, user: String) async throws -> String {
        let baseURL = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIError.invalidURL(config.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.requestFailed("No HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseFailed("Cannot parse response")
        }

        return stripThinking(content)
    }

    /// Test the connection to the AI provider.
    func testConnection() async throws -> String {
        let result = try await complete(system: "Reply with OK.", user: "Test")
        return result
    }

    // MARK: - Helpers

    private func normalizeURL(_ url: String) -> String {
        var u = url
        if !u.contains("://") { u = "http://\(u)" }
        while u.hasSuffix("/") { u.removeLast() }
        // Avoid double /v1
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }

    private func stripThinking(_ text: String) -> String {
        // Remove <think>...</think> blocks
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AIError: Error, LocalizedError {
    case invalidURL(String)
    case requestFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Invalid AI URL: \(u)"
        case .requestFailed(let m): return "AI request failed: \(m)"
        case .parseFailed(let m): return "AI response parse failed: \(m)"
        }
    }
}
