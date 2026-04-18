import Foundation

/// Per-call knobs for `AIService.complete`. Every service that used to build
/// its own URLRequest now passes one of these so timeout / temperature /
/// system-side tweaks travel alongside the prompt.
///
/// Codex path ignores `temperature`, `maxTokens`, and `extraSystemSuffix` —
/// pi-ai's Responses API request body is fixed. OpenAI-compatible path honors
/// every field.
struct CompleteOptions {
    var timeout: TimeInterval = 120
    var temperature: Double? = nil   // nil → use AIConfig.temperature
    var maxTokens: Int? = nil        // nil → use AIConfig.maxTokens
    var modelOverride: String? = nil // nil → use slot.model
    /// Appended to the system prompt for non-Codex providers. Used by the
    /// existing "不要进入 thinking 模式" hint.
    var extraSystemSuffix: String? = "\n\n不要进入 thinking 模式，不要输出 <think> 标签或思维过程。"
    /// When true, the request body includes `"enable_thinking": false` (which
    /// suppresses Qwen-style thinking output). When false, the field is omitted
    /// entirely — useful for providers that reject unknown keys. Default true
    /// matches current behavior; set to false only for strict OpenAI-compatible
    /// providers that don't recognize the flag.
    var emitEnableThinkingFlag: Bool = true

    static let `default` = CompleteOptions()
}

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
        try await complete(system: system, user: user, options: .default)
    }

    /// Unified completion entry point. All services should call this instead
    /// of building their own `/chat/completions` request. Routes to Codex when
    /// the active slot is `openai-codex`, otherwise OpenAI-compatible.
    ///
    /// `.auto` mode is preserved: primary slot is tried first and the fallback
    /// slot takes over on failure. The fallback fires even when its baseURL is
    /// empty as long as the provider is Codex (empty URL is expected for Codex).
    func complete(
        system: String,
        user: String,
        options: CompleteOptions
    ) async throws -> String {
        let primary = config.primarySlot
        let fallback = config.fallbackSlot

        do {
            return try await send(slot: primary, system: system, user: user, options: options)
        } catch {
            if let fb = fallback, !fb.baseURL.isEmpty || fb.providerID == "openai-codex" {
                print("[WCHUD-AI] primary failed (\(error.localizedDescription)), trying fallback…")
                return try await send(slot: fb, system: system, user: user, options: options)
            }
            throw error
        }
    }

    /// Test a specific slot's connection.
    func testSlot(_ slot: AIProviderSlot) async throws -> String {
        try await send(
            slot: slot,
            system: "Reply with OK.",
            user: "Test",
            options: .default
        )
    }

    /// Test the connection to the AI provider.
    func testConnection() async throws -> String {
        try await testSlot(config.primarySlot)
    }

    // MARK: - Helpers

    private func send(
        slot: AIProviderSlot,
        system: String,
        user: String,
        options: CompleteOptions
    ) async throws -> String {
        if slot.providerID == "openai-codex" {
            let model = (options.modelOverride ?? slot.model)
                .trimmingCharacters(in: .whitespaces)
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
        request.timeoutInterval = options.timeout

        let effectiveSystem = system + (options.extraSystemSuffix ?? "")
        let model = options.modelOverride ?? slot.model

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": effectiveSystem],
                ["role": "user", "content": user]
            ],
            "temperature": options.temperature ?? config.temperature,
            "max_tokens": options.maxTokens ?? config.maxTokens,
            "stream": false
        ]
        if options.emitEnableThinkingFlag {
            body["enable_thinking"] = false
        }
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
