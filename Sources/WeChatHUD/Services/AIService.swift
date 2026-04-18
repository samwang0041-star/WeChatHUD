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
        let slot = config.primarySlot
        // Codex slots are valid even with empty baseURL — the URL is hardcoded
        // and auth comes from the codex CLI login state, not user-entered values.
        if slot.providerID == "openai-codex" {
            return !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !slot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send a chat completion request. In `.auto` mode, tries the primary
    /// slot first and falls back to the other on failure.
    func complete(system: String, user: String) async throws -> String {
        let primary = config.primarySlot
        let fallback = config.fallbackSlot

        do {
            return try await send(slot: primary, system: system, user: user)
        } catch {
            if let fb = fallback, !fb.baseURL.isEmpty {
                print("[WCHUD-AI] primary failed (\(error.localizedDescription)), trying fallback…")
                return try await send(slot: fb, system: system, user: user)
            }
            throw error
        }
    }

    /// Test a specific slot's connection.
    func testSlot(_ slot: AIProviderSlot) async throws -> String {
        try await send(slot: slot, system: "Reply with OK.", user: "Test")
    }

    /// Test the connection to the AI provider.
    func testConnection() async throws -> String {
        try await testSlot(config.primarySlot)
    }

    // MARK: - Helpers

    private func send(slot: AIProviderSlot, system: String, user: String) async throws -> String {
        // Codex provider has its own transport (ChatGPT OAuth + Responses API).
        // Forward to CodexBackend; everything else stays on the OpenAI-compatible
        // `/chat/completions` path below.
        if slot.providerID == "openai-codex" {
            let model = slot.model.trimmingCharacters(in: .whitespaces)
            let resolvedModel = model.isEmpty ? "gpt-5.4" : model
            return try await CodexBackend.shared.complete(
                system: system, user: user, model: resolvedModel
            )
        }

        let baseURL = normalizeURL(slot.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIError.invalidURL(slot.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !slot.apiKey.isEmpty {
            request.setValue("Bearer \(slot.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        // Qwen3.5 optimization: suppress thinking mode to save tokens and latency
        let effectiveSystem = system + "\n\n不要进入 thinking 模式，不要输出 <think> 标签或思维过程。"

        let body: [String: Any] = [
            "model": slot.model,
            "messages": [
                ["role": "system", "content": effectiveSystem],
                ["role": "user", "content": user]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            // Disable qwen3-style reasoning tokens — otherwise
            // DashScope's qwen3.6-plus burns 800+ tokens on an
            // internal chain-of-thought before emitting a single
            // character of output, which makes every call take
            // 15-30s and often exceed our timeout. Non-reasoning
            // models silently ignore this field.
            "enable_thinking": false
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
