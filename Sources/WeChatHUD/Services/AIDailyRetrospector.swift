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
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_retrospect_v1"
    ) {
        self.store = store
        self.aiService = aiService
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
            await audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            await audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry")
            return parsed
        }

        await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry")
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
        let trackID = "retro:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "日报/周报")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let content = try await aiService.complete(
                system: "你是一个工作日复盘助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 90, temperature: 0.2, maxTokens: 768)
            )
            return ModelResponse(text: content, error: nil)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription)
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

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) async {
        let model = await aiService.currentConfig().model
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: model,
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
}
