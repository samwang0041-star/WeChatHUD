import Foundation

/// Generates an end-of-day retrospective: a one-line summary, a
/// "tomorrow's first thing" recommendation, and a copy-paste-ready
/// WeChat daily report draft.
///
/// Designed to be triggered automatically at 17:45 (or whenever the
/// user clicks 收尾 in the HUD), reading from `pending_asks` and
/// existing audit data, and producing structured output the user can
/// glance at or paste into WeChat.
///
/// Pure service. Reads its config from `loadAIConfig()` so it
/// tracks whatever model the user has set.
actor AIDailyRetrospector {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_retrospect_v1"
    ) {
        self.store = store
        var inflated = config
        // Daily report is the longest output of any role; bump tokens.
        inflated.maxTokens = 1024
        inflated.temperature = 0.3
        self.config = inflated
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Output of one retrospective call.
    struct Retrospective: Decodable {
        let todaySummary: String
        let tomorrowFirstThing: NextAction
        let stats: Stats
        let wechatDailyReport: String

        enum CodingKeys: String, CodingKey {
            case todaySummary = "today_summary"
            case tomorrowFirstThing = "tomorrow_first_thing"
            case stats
            case wechatDailyReport = "wechat_daily_report"
        }
    }

    struct NextAction: Decodable {
        let action: String
        let reason: String
        let relatedAskId: Int

        enum CodingKeys: String, CodingKey {
            case action
            case reason
            case relatedAskId = "related_ask_id"
        }
    }

    struct Stats: Decodable {
        let asksHandled: Int
        let asksPending: Int
        let asksOverdue: Int

        enum CodingKeys: String, CodingKey {
            case asksHandled = "asks_handled"
            case asksPending = "asks_pending"
            case asksOverdue = "asks_overdue"
        }
    }

    struct Input {
        let date: String           // ISO date "2026-04-12"
        let handled: [PendingAsk]  // status == .done, updated today
        let pending: [PendingAsk]  // status == .pending
        let messageCount: Int      // total send + receive today
        let focusDurationMinutes: Int
    }

    /// Returns the structured retrospective, or nil on parse/HTTP failure.
    func retrospect(_ input: Input) async -> Retrospective? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIDailyRetrospector: prompt load failed: \(error)")
            return nil
        }

        let handledList = formatAskList(input.handled, includeAge: false)
        let pendingList = formatAskList(input.pending, includeAge: true)

        let userPrompt = template
            .replacingOccurrences(of: "{date}", with: input.date)
            .replacingOccurrences(of: "{handled_count}", with: "\(input.handled.count)")
            .replacingOccurrences(of: "{handled_list}", with: handledList)
            .replacingOccurrences(of: "{pending_count}", with: "\(input.pending.count)")
            .replacingOccurrences(of: "{pending_list}", with: pendingList)
            .replacingOccurrences(of: "{message_count}", with: "\(input.messageCount)")
            .replacingOccurrences(of: "{focus_duration}", with: focusFormat(input.focusDurationMinutes))

        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry")
            return parsed
        }

        audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry")
        return nil
    }

    // MARK: - Formatting

    /// Format an ask list as numbered bullets, optionally with creation
    /// age. The model uses these as input — keep them compact and
    /// deterministic so the prompt context isn't bloated.
    private func formatAskList(_ asks: [PendingAsk], includeAge: Bool) -> String {
        if asks.isEmpty { return "无" }
        let now = Date()
        return asks.enumerated().map { (i, ask) in
            var line = "\(i + 1). [\(ask.senderName)] \(ask.summary) - work"
            if includeAge {
                let age = Int(now.timeIntervalSince(ask.createdAt))
                let ageStr: String
                if age < 3600 {
                    ageStr = "创建 \(age / 60)min 前"
                } else if age < 86400 {
                    ageStr = "创建 \(age / 3600)h 前"
                } else {
                    ageStr = "创建 \(age / 86400)d 前"
                }
                line += " - \(ageStr)"
                if let dl = ask.deadlineAt, dl < now {
                    let overdueSecs = Int(now.timeIntervalSince(dl))
                    let overdueStr = overdueSecs < 3600 ? "\(overdueSecs / 60)m" : "\(overdueSecs / 3600)h"
                    line += " - 已超时 \(overdueStr)"
                }
            }
            // Inject ID so the model can reference it via related_ask_id
            line += " [id=\(ask.id)]"
            return line
        }.joined(separator: "\n")
    }

    private func focusFormat(_ minutes: Int) -> String {
        if minutes <= 0 { return "0" }
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let baseURL = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            return ModelResponse(text: "", error: "invalid url: \(config.baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 90

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "你是一个工作日复盘助手，严格按要求输出 JSON。"],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return ModelResponse(text: "", error: "no http response")
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return ModelResponse(text: "", error: "HTTP \(http.statusCode): \(body.prefix(200))")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return ModelResponse(text: "", error: "could not extract content")
            }
            return ModelResponse(text: stripThinking(content), error: nil)
        } catch {
            return ModelResponse(text: "", error: "request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> Retrospective? {
        guard !raw.isEmpty else { return nil }
        var cleaned = raw
        if let fenceRange = cleaned.range(of: "```") {
            cleaned = String(cleaned[fenceRange.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let endFence = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("{") {
            if let lo = cleaned.firstIndex(of: "{"), let hi = cleaned.lastIndex(of: "}") {
                cleaned = String(cleaned[lo...hi])
            }
        }
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Retrospective.self, from: data)
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: config.model,
            promptVersion: promptVersion,
            inputText: "[date:\(input.date)|handled=\(input.handled.count)|pending=\(input.pending.count)|msgs=\(input.messageCount)]",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIDailyRetrospector: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func normalizeURL(_ url: String) -> String {
        var u = url
        if !u.contains("://") { u = "http://\(u)" }
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }

    private func stripThinking(_ text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
