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
    /// When true and thinking is disabled, compatible providers may receive
    /// `"enable_thinking": false`. DeepSeek and Kimi use their documented
    /// `"thinking": {"type": ...}` parameter instead.
    var emitEnableThinkingFlag: Bool = true
    /// nil → use AIConfig.thinkingEnabled.
    var thinkingEnabled: Bool? = nil
    /// Ask providers that support OpenAI-style JSON mode to enforce JSON.
    var responseFormatJSON: Bool = false

    static let `default` = CompleteOptions()
}

struct AICompletionResult {
    let text: String
    let providerID: String
    let model: String
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
        let slot = config.provider
        // Codex slots are valid even with empty baseURL — the URL is hardcoded
        // and auth comes from the codex CLI login state, not user-entered values.
        if slot.providerID == "openai-codex" {
            return !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !slot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send a chat completion request to the configured provider.
    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, options: .default)
    }

    /// Unified completion entry point. All services should call this instead
    /// of building their own `/chat/completions` request. Routes to Codex when
    /// the configured provider is `openai-codex`, otherwise OpenAI-compatible.
    func complete(
        system: String,
        user: String,
        options: CompleteOptions
    ) async throws -> String {
        try await completeWithMetadata(system: system, user: user, options: options).text
    }

func completeWithMetadata(
    system: String,
    user: String,
    options: CompleteOptions
) async throws -> AICompletionResult {
    // Global rate limiter — prevents API burst when multiple services
    // fire concurrently (autopilot batches, prefetch, proactive alerts).
    // Default: 4 calls/second, enough for normal usage, gentle on API.
    await AIRateLimiter.shared.acquire()

    let slot = config.provider
    return try await send(slot: slot, system: system, user: user, options: options)
    }

    /// Test a specific slot's connection.
    func testSlot(_ slot: AIProviderSlot) async throws -> String {
        try await send(
            slot: slot,
            system: "Reply with OK.",
            user: "Test",
            options: .default
        ).text
    }

    /// Test the connection to the AI provider.
    func testConnection() async throws -> String {
        try await testSlot(config.provider)
    }

    // MARK: - Helpers

    private func send(
        slot: AIProviderSlot,
        system: String,
        user: String,
        options: CompleteOptions
    ) async throws -> AICompletionResult {
        if slot.providerID == "openai-codex" {
            let model = (options.modelOverride ?? slot.model)
                .trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else {
                throw AIError.requestFailed("AI model is empty for provider \(slot.providerID)")
            }
            let text = try await CodexBackend.shared.complete(
                system: system, user: user, model: model
            )
            return AICompletionResult(text: text, providerID: slot.providerID, model: model)
        }

        let baseURL = Self.normalizeBaseURL(slot.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIError.invalidURL(slot.baseURL)
        }

        let isDeepSeek = slot.providerID == "deepseek"
            || Self.normalizeBaseURL(slot.baseURL).contains("api.deepseek.com")

        let thinkingOn = options.thinkingEnabled ?? (options.responseFormatJSON ? false : config.thinkingEnabled)

        var effectiveSystemSuffix = options.extraSystemSuffix
        if !thinkingOn, let suffix = effectiveSystemSuffix,
           suffix.contains("不要进入 thinking 模式") {
            // keep the suppression suffix
        } else if thinkingOn {
            effectiveSystemSuffix = nil
        }
        let effectiveSystem = system + (effectiveSystemSuffix ?? "")
        let model = (options.modelOverride ?? slot.model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIError.requestFailed("AI model is empty for provider \(slot.providerID)")
        }
        let isKimi = isKimiProvider(slot: slot, url: url, model: model)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !slot.apiKey.isEmpty {
            request.setValue("Bearer \(slot.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if isKimiCodingURL(url) {
            request.setValue("claude-code/0.1.0", forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = options.timeout

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": effectiveSystem],
                ["role": "user", "content": user]
            ],
            "max_tokens": effectiveMaxTokens(
                slot: slot,
                requested: options.maxTokens ?? config.maxTokens,
                thinkingOn: thinkingOn
            ),
            "stream": false
        ]
        if !isKimi {
            body["temperature"] = options.temperature ?? config.temperature
        }
        if options.responseFormatJSON, supportsJSONResponseFormat(slot: slot) {
            body["response_format"] = ["type": "json_object"]
        }
        if isDeepSeek {
            body["thinking"] = ["type": thinkingOn ? "enabled" : "disabled"]
            if thinkingOn {
                body["reasoning_effort"] = "high"
            }
        } else if isKimi {
            body["thinking"] = ["type": thinkingOn ? "enabled" : "disabled"]
            if thinkingOn {
                body["reasoning_effort"] = "medium"
            }
        } else if options.emitEnableThinkingFlag, !thinkingOn, shouldEmitEnableThinkingFlag(slot: slot) {
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
              let message = first["message"] as? [String: Any] else {
            throw AIError.parseFailed("Cannot parse response")
        }
        let finishReason = first["finish_reason"] as? String
        let content = message["content"] as? String ?? ""
        // DeepSeek and Kimi return reasoning chains in a separate field.
        if (isDeepSeek || isKimi), let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            let providerName = isDeepSeek ? "DeepSeek" : "Kimi"
            if thinkingOn {
                print("[WCHUD-AI] \(providerName) reasoning_content length=\(reasoning.count)")
            } else {
                print("[WCHUD-AI] \(providerName) reasoning_content ignored (thinking disabled)")
            }
        }
        if finishReason == "length" {
            throw AIError.requestFailed("Output truncated by max_tokens (finish_reason=length)")
        }
        // When Kimi Coding or DeepSeek reasoner runs out of tokens it often leaves content empty.
        if content.isEmpty {
            throw AIError.requestFailed("Empty content from AI response")
        }
        let responseModel = (json["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actualModel: String
        if let responseModel, !responseModel.isEmpty {
            actualModel = responseModel
        } else {
            actualModel = model
        }
        return AICompletionResult(
            text: thinkingOn ? content : stripThinking(content),
            providerID: slot.providerID,
            model: actualModel
        )
    }

    /// Fetch available models from an OpenAI-compatible `/models` endpoint.
    func fetchModels(slot: AIProviderSlot) async throws -> [String] {
        if slot.providerID == "openai-codex" {
            return ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.3-codex"]
        }
        let baseURL = Self.normalizeBaseURL(slot.baseURL)
        guard let url = URL(string: "\(baseURL)/models") else {
            throw AIError.invalidURL(slot.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if !slot.apiKey.isEmpty {
            request.setValue("Bearer \(slot.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if isKimiCodingURL(url) {
            request.setValue("claude-code/0.1.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.requestFailed("HTTP \(code): \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            throw AIError.parseFailed("Cannot parse /models response")
        }
        let models = dataArr.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return models.sorted()
    }

    /// Normalizes a user-entered provider base URL into the form every request
    /// builder expects: an explicit scheme, no trailing slash, and a `/v1`
    /// suffix. Schemeless input defaults to **https**, except for loopback
    /// hosts (localhost / 127.0.0.1 / ::1) which default to **http** — a local
    /// server (Ollama, LM Studio, Hermes) almost never speaks TLS, and forcing
    /// https there broke every local setup. `static` (not private) so the
    /// policy is testable without standing up an `AIService` actor.
    static func normalizeBaseURL(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.contains("://") {
            let authority = u.split(separator: "/", maxSplits: 1,
                                    omittingEmptySubsequences: false).first.map(String.init) ?? u
            u = (isLoopbackAuthority(authority) ? "http://" : "https://") + u
        }
        while u.hasSuffix("/") { u.removeLast() }
        // Avoid double /v1
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }

    /// True when the `host[:port]` authority names the local machine. Bracketed
    /// IPv6 (`[::1]:11434`) is unwrapped before the comparison.
    private static func isLoopbackAuthority(_ authority: String) -> Bool {
        var host = authority
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex)..<close])
            }
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    /// Kimi Coding's forced-reasoning monologue can consume 500–1500 tokens
    /// before emitting any real content. If the caller asked for fewer than
    /// 2048 tokens, bump it to a safe floor so we don't get an empty answer.
    private func effectiveMaxTokens(slot: AIProviderSlot, requested: Int, thinkingOn: Bool) -> Int {
        let isKimi = slot.baseURL.contains("api.kimi.com")
            || Self.normalizeBaseURL(slot.baseURL).contains("api.kimi.com")
        let isDeepSeek = slot.providerID == "deepseek"
            || Self.normalizeBaseURL(slot.baseURL).contains("api.deepseek.com")
        if (isKimi || (isDeepSeek && thinkingOn)), requested < 2048 {
            return 2048
        }
        return requested
    }

    private func supportsJSONResponseFormat(slot: AIProviderSlot) -> Bool {
        let normalized = Self.normalizeBaseURL(slot.baseURL)
        return slot.providerID == "deepseek"
            || normalized.contains("api.deepseek.com")
            || isKimiProvider(slot: slot, url: nil, model: slot.model)
            || slot.providerID == "openai"
            || normalized.contains("api.openai.com")
    }

    private func isKimiCodingURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host == "api.kimi.com" || host.hasSuffix(".api.kimi.com") else {
            return false
        }
        return url.path.lowercased().contains("/coding")
    }

    private func isKimiProvider(slot: AIProviderSlot, url: URL?, model: String?) -> Bool {
        let provider = slot.providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["kimicode", "kimi-coding", "kimi-coding-cn", "kimi-for-coding", "moonshot"].contains(provider) {
            return true
        }
        let baseURL = Self.normalizeBaseURL(slot.baseURL).lowercased()
        if baseURL.contains("api.kimi.com")
            || baseURL.contains("moonshot.ai")
            || baseURL.contains("moonshot.cn") {
            return true
        }
        if let host = url?.host?.lowercased(),
           host == "api.kimi.com"
            || host.hasSuffix(".api.kimi.com")
            || host.contains("moonshot.ai")
            || host.contains("moonshot.cn") {
            return true
        }
        let bareModel = (model ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        return bareModel == "kimi"
            || bareModel == "kimi-for-coding"
            || bareModel.hasPrefix("kimi-")
            || bareModel.hasPrefix("kimi_")
            || bareModel.hasPrefix("moonshot-")
            || bareModel.hasPrefix("moonshot_")
            || bareModel.hasPrefix("k1.")
            || bareModel.hasPrefix("k1-")
            || bareModel.hasPrefix("k2.")
            || bareModel.hasPrefix("k2-")
            || bareModel.hasPrefix("k2p")
            || bareModel.hasPrefix("k25")
    }

    private func shouldEmitEnableThinkingFlag(slot: AIProviderSlot) -> Bool {
        let provider = slot.providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseURL = Self.normalizeBaseURL(slot.baseURL).lowercased()
        return provider == "dashscope"
            || provider == "qwen"
            || provider == "alibaba"
            || baseURL.contains("dashscope.aliyuncs.com")
            || baseURL.contains("portal.qwen.ai")
    }

    private func stripThinking(_ text: String) -> String {
        // Remove <think>...</think> blocks
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip WeChat-specific placeholders that can trigger provider content
    /// filters (e.g. Kimi returns HTTP 400 for "[表情]"). Returns the
    /// sanitized text — empty string if nothing remains.
    static func sanitizeForAI(_ text: String) -> String {
        var t = text
        let placeholders = [
            "[表情]", "[图片]", "[照片]", "[语音]", "[视频]",
            "[文件]", "[链接]", "[位置]", "[红包]", "[转账]",
            "[动画表情]", "[系统消息]", "[引用]", "[小程序]",
        ]
        for ph in placeholders {
            t = t.replacingOccurrences(of: ph, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Global AI call rate limiter. Simple sliding window: at most
/// `maxCallsPerSecond` calls may start within any 1-second window.
/// Non-blocking (async wait) so callers don't need to handle busy-wait.
actor AIRateLimiter {
    static let shared = AIRateLimiter()
    private var timestamps: [Date] = []
    private let maxCallsPerSecond = 4

    /// Admit a call, waiting outside the actor when the window is full.
    ///
    /// The previous implementation slept *inside* `acquire`, between reading
    /// `timestamps` and appending to it. Every caller that arrived during that
    /// suspension observed a window that was still empty, so N concurrent
    /// callers all passed the check and the limiter admitted all of them.
    /// Reservation is now a single synchronous hop; only the wait is async.
    func acquire() async {
        while true {
            let wait = reserve()
            if wait <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Record an admitted call, or report how long to wait before retrying.
    /// Synchronous on purpose: check-and-record must be one actor-isolated
    /// step for the limit to hold under concurrency.
    private func reserve() -> TimeInterval {
        let now = Date()
        // Drop timestamps older than 1s
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 1.0 }

        if timestamps.count >= maxCallsPerSecond {
            let oldest = timestamps[0]
            let wait = 1.0 - now.timeIntervalSince(oldest)
            if wait > 0 { return wait }
        }
        timestamps.append(Date())
        return 0
    }

    /// Pure form of the admission decision, so the limit can be tested without
    /// sleeping. Appends on admission and returns 0; otherwise returns the
    /// remaining wait and records nothing.
    static func waitTime(now: Date, timestamps: inout [Date], maxCallsPerSecond: Int = 4) -> TimeInterval {
        timestamps.removeAll { now.timeIntervalSince($0) >= 1.0 }
        if timestamps.count >= maxCallsPerSecond, let oldest = timestamps.first {
            return max(1.0 - now.timeIntervalSince(oldest), 0.001)
        }
        timestamps.append(now)
        return 0
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
