import Foundation

/// Generates a one-line summary (<=25 chars) for an inbox item,
/// telling the user "what does this person want from you?"
///
/// Examples:
///   "红字为修改部分请查收" → "等你确认方案修改稿"
///   "@你 方案定了吗"       → "张总问你方案排期"
///
/// Follows the same actor + HTTP + audit pattern as AIReplySuggester.
actor AIInboxSummarizer {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "inbox_summary_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Generate a one-line summary for an inbox item.
    /// Returns nil on failure (caller should fall back to raw preview).
    func summarize(_ context: InboxContext) async -> String? {
        guard await aiService.currentConfig().summaryEnabled else { return nil }
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIInboxSummarizer: prompt load failed: \(error)")
            return nil
        }

        // Use the pre-tagged transcript from InboxContextBuilder. It
        // labels each line as "我: ..." for user-outbound messages
        // and "{senderName}: ..." for peer messages — without this,
        // the model can't tell the user's own "收到" from a peer
        // reply and has produced summaries like "对方仅回复收到"
        // for messages the user actually sent.
        //
        // We deliberately do NOT pass pendingCommitments /
        // pendingAsks — they previously polluted summaries with
        // unrelated old tasks. Example: a @华武 ask from 3 days ago
        // about "费率谈判材料" got blended into a completely
        // different trigger message about 微银通, producing
        // "发材料、交计划、准备会议" when none of those appeared
        // in the actual message. ChatAnalyzer (which has a richer
        // reasoning loop) is the right place to cross-reference
        // pending items; the inbox summarizer's single job is
        // "what does THIS message ask".
        let contextStr = context.taggedTranscript

        let userPrompt = template
            .replacingOccurrences(of: "{sender_name}", with: context.triggerMessage.senderName)
            .replacingOccurrences(of: "{sender_role}", with: context.senderRole.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: context.triggerMessage.chatName)
            .replacingOccurrences(of: "{chat_kind}", with: context.isGroupChat ? "群聊" : "私聊")
            .replacingOccurrences(of: "{message_body}", with: context.triggerMessageText)
            .replacingOccurrences(of: "{context_messages}", with: contextStr)
            .replacingOccurrences(of: "{my_last_reply}", with: context.myLastReplyText ?? "无")

        let result = await call(userPrompt)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        if let text = result.text, !text.isEmpty {
            // Clean: remove quotes, trim, cap at 30 chars
            let cleaned = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\u{201C}", with: "")
                .replacingOccurrences(of: "\u{201D}", with: "")
            let summary = String(cleaned.prefix(30))
            await audit(input: context.triggerMessageText, output: summary, latencyMs: latencyMs, status: .ok, error: nil)
            return summary
        }

        await audit(
            input: context.triggerMessageText,
            output: "",
            latencyMs: latencyMs,
            status: result.error != nil ? .httpError : .parseError,
            error: result.error
        )
        return nil
    }

    // MARK: - HTTP call

    private struct CallResult {
        let text: String?
        let error: String?
    }

    private func call(_ userPrompt: String) async -> CallResult {
        let trackID = "inbox:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "收件摘要")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let content = try await aiService.complete(
                system: "你是用户的微信消息管家。只输出摘要文本，不要任何其他内容。",
                user: userPrompt,
                options: CompleteOptions(timeout: 30, temperature: 0.1, maxTokens: 100)
            )
            return CallResult(text: content, error: nil)
        } catch {
            return CallResult(text: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Audit

    private func audit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) async {
        let model = await aiService.currentConfig().model
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .summarizer,
            model: model,
            promptVersion: promptVersion,
            inputText: String(input.prefix(100)),
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIInboxSummarizer: audit write failed: \(error)")
        }
    }
}
