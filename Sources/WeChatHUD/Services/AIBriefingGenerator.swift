import Foundation

/// Generates a structured briefing (situation + suggestion + 3 reply candidates)
/// when the user expands an inbox item. Returns `InboxBriefing?`.
///
/// Follows the same actor + HTTP + audit + retry pattern as AIReplySuggester.
actor AIBriefingGenerator {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "inbox_briefing_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Generate a structured briefing for an inbox item.
    /// Returns nil on failure (caller should fall back to basic display).
    func generate(_ context: InboxContext, styleHint: String? = nil) async -> InboxBriefing? {
        guard await aiService.currentConfig().summaryEnabled else { return nil }
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIBriefingGenerator: prompt load failed: \(error)")
            return nil
        }

        // Build context messages string
        let contextStr = context.recentMessages.prefix(8).map { msg in
            "\(msg.senderName): \(String(AIService.sanitizeForAI(msg.text).prefix(80)))"
        }.joined(separator: "\n")

        let commitmentsStr = context.pendingCommitments.isEmpty
            ? "无"
            : context.pendingCommitments.map { $0.content }.joined(separator: "; ")

        let asksStr = context.pendingAsks.isEmpty
            ? "无"
            : context.pendingAsks.map { $0.summary }.joined(separator: "; ")

        let timeSinceReply: String
        if let interval = context.timeSinceMyLastReply {
            let minutes = Int(interval / 60)
            if minutes < 60 {
                timeSinceReply = "\(minutes)分钟前"
            } else {
                timeSinceReply = "\(minutes / 60)小时\(minutes % 60)分钟前"
            }
        } else {
            timeSinceReply = "无记录"
        }

        var userPrompt = template
            .replacingOccurrences(of: "{sender_name}", with: context.triggerMessage.senderName)
            .replacingOccurrences(of: "{sender_role}", with: context.senderRole.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: context.triggerMessage.chatName)
            .replacingOccurrences(of: "{chat_kind}", with: context.isGroupChat ? "群聊" : "私聊")
            .replacingOccurrences(of: "{message_body}", with: renderMessageBody(context))
            .replacingOccurrences(of: "{context_messages}", with: contextStr)
            .replacingOccurrences(of: "{my_last_reply}", with: context.myLastReplyText ?? "无")
            .replacingOccurrences(of: "{time_since_reply}", with: timeSinceReply)
            .replacingOccurrences(of: "{pending_commitments}", with: commitmentsStr)
            .replacingOccurrences(of: "{pending_asks}", with: asksStr)
            .replacingOccurrences(of: "{is_overdue}", with: context.isOverdue ? "是" : "否")
            .replacingOccurrences(of: "{overdue_minutes}", with: "\(context.overdueMinutes)")
            .replacingOccurrences(of: "{inbound_count}", with: "\(context.inboundCountSinceMyLastReply)")

        // Append style hint if available
        if let hint = styleHint {
            userPrompt += "\n\n[风格参考] \(hint)"
        }

        // First attempt
        let first = await call(userPrompt)
        if let briefing = parse(first.text) {
            await audit(input: context.triggerMessageText, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil, model: first.model)
            return briefing
        }
        if first.text.isEmpty, let err = first.error {
            await audit(input: context.triggerMessageText, output: "", latencyMs: ms(since: started), status: .httpError, error: err, model: first.model)
            return nil
        }

        // Stricter retry
        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let briefing = parse(second.text) {
            await audit(input: context.triggerMessageText, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry", model: second.model)
            return briefing
        }

        await audit(
            input: context.triggerMessageText,
            output: second.text,
            latencyMs: ms(since: started),
            status: .parseError,
            error: second.error ?? "JSON parse failed after retry",
            model: second.model
        )
        return nil
    }

    // MARK: - HTTP call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "brief:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "聊天总结")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是用户的微信消息管家。严格按要求输出 JSON，不要任何其他内容。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.3, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> InboxBriefing? {
        guard let briefing = AIJSONExtractor.decodeFirstObject(from: raw, as: InboxBriefing.self) else { return nil }
        return briefing.replies.isEmpty ? nil : briefing
    }

    private func renderMessageBody(_ context: InboxContext) -> String {
        let sanitized = AIService.sanitizeForAI(context.triggerMessageText)
        if context.mediaType == .image, ["[图片]", ""].contains(sanitized) {
            if let mediaAnalysis = context.mediaAnalysisText, !mediaAnalysis.isEmpty {
                return "发来一张图片。\n\(AIService.sanitizeForAI(mediaAnalysis))"
            }
            return "发来一张图片"
        }
        return sanitized
    }

    // MARK: - Helpers

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - Audit

    private func audit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .briefer,
            model: model,
            promptVersion: promptVersion,
            inputText: String(input.prefix(100)),
            outputText: String(output.prefix(300)),
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIBriefingGenerator: audit write failed: \(error)")
        }
    }
}
