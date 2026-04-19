import Foundation

/// Generates a single best auto-reply in the user's communication style.
/// Unlike AIReplySuggester (3 suggestions for manual pick), this produces
/// one reply with confidence/risk assessment for autonomous sending.
actor AutoReplyGenerator {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    /// The AI's decision for a single message.
    struct Decision: Decodable {
        /// The reply text to send. Nil if skip/pending/readNoReply.
        let reply: String?
        /// Confidence 0.0-1.0 that this reply is appropriate.
        let confidence: Double
        /// Risk assessment.
        let risk: String        // "low" / "medium" / "high"
        /// Why the AI chose this reply (or chose to skip).
        let reasoning: String
        /// Whether to skip replying entirely (e.g., sticker, system msg).
        let skip: Bool?
        /// Whether to hold for user review (e.g., money, decisions).
        let pending: Bool?
        /// Whether to mark as read but not reply (e.g., "嗯", "好的", conversation ender).
        let readNoReply: Bool?

        enum CodingKeys: String, CodingKey {
            case reply, confidence, risk, reasoning, skip, pending
            case readNoReply = "read_no_reply"
        }
    }

    struct Input {
        let messageBody: String
        let senderName: String
        let chatName: String
        let chatUsername: String
        let contactRole: ContactRole
        let attentionLevel: AttentionLevel
        /// Context window (formatted by ContextWindowBuilder).
        let contextWindow: String
        /// User's style profile description.
        let styleDescription: String
        /// Recent outgoing examples as few-shot.
        let fewShotExamples: [String]
        /// User's frequent phrases.
        let frequentPhrases: [String]
        /// Message pairs: "peer → user" for contextual few-shot.
        var messagePairs: [(question: String, answer: String)] = []
        /// Punctuation style description.
        var punctuationStyle: String = ""
        /// Sentence structure style.
        var sentenceStyle: String = ""
        /// Typing rhythm description.
        var typingRhythm: String = ""
        /// Message length distribution.
        var lengthP25: Int = 5
        var lengthP50: Int = 15
        var lengthP75: Int = 30
        /// Per-contact style hint (e.g., "你和他聊天比较随意，爱开玩笑").
        var contactStyleHint: String = ""
        /// Media context if message contains non-text content (image/voice/video/file).
        var mediaContext: String? = nil
        /// Conversation memory (formatted text block). Nil if no memory exists.
        var conversationMemory: String? = nil
        /// Session ledger — entries appended for this chat during the
        /// current autopilot session. Used to keep the model consistent
        /// with what it has already said. Empty = fresh session.
        var sessionLedger: [LedgerEntry] = []
        /// Optional style override appended to prompt.
        var replyStyleSuffix: String = ""
    }

    /// Generate a reply decision for the given input.
    func generate(_ input: Input) async -> Decision? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: "autopilot_reply_v3")
        } catch {
            // Fallback chain: v3 → v2 → v1. Keeps autopilot functional
            // even if the tuned prompt goes missing from the bundle.
            print("[WCHUD] AutoReplyGenerator: v3 prompt load failed, trying v2 fallback")
            do {
                template = try promptLoader.load(version: "autopilot_reply_v2")
            } catch {
                print("[WCHUD] AutoReplyGenerator: v2 prompt load failed, trying v1 fallback")
                do {
                    template = try promptLoader.load(version: "autopilot_reply_v1")
                } catch {
                    print("[WCHUD] AutoReplyGenerator: all prompt versions failed: \(error)")
                    return nil
                }
            }
        }

        let fewShotText = input.fewShotExamples.isEmpty
            ? "（暂无历史记录）"
            : input.fewShotExamples.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let phrasesText = input.frequentPhrases.isEmpty
            ? "（暂无）"
            : input.frequentPhrases.joined(separator: "、")

        let pairsText = input.messagePairs.isEmpty
            ? "（暂无）"
            : input.messagePairs.enumerated().map { "  \($0.offset + 1). 对方：\($0.element.question) → 用户：\($0.element.answer)" }.joined(separator: "\n")

        let memoryText = input.conversationMemory ?? "（暂无记忆）"
        let ledgerText = Self.formatLedger(input.sessionLedger)

        // Append media context to message body if present
        let messageBody = input.mediaContext != nil
            ? "\(clean(input.messageBody))\n[媒体提示: \(input.mediaContext!)]"
            : clean(input.messageBody)

        let userPrompt = template
            .replacingOccurrences(of: "{message_body}", with: messageBody)
            .replacingOccurrences(of: "{sender_name}", with: clean(input.senderName))
            .replacingOccurrences(of: "{chat_name}", with: clean(input.chatName))
            .replacingOccurrences(of: "{contact_role}", with: input.contactRole.label)
            .replacingOccurrences(of: "{attention_level}", with: input.attentionLevel.label)
            .replacingOccurrences(of: "{context_window}", with: input.contextWindow)
            .replacingOccurrences(of: "{contact_style_hint}", with: input.contactStyleHint.isEmpty ? "（暂无特征数据）" : input.contactStyleHint)
            .replacingOccurrences(of: "{conversation_memory}", with: memoryText)
            .replacingOccurrences(of: "{session_ledger}", with: ledgerText)
            .replacingOccurrences(of: "{style_description}", with: input.styleDescription)
            .replacingOccurrences(of: "{punctuation_style}", with: input.punctuationStyle.isEmpty ? "（暂无数据）" : input.punctuationStyle)
            .replacingOccurrences(of: "{sentence_style}", with: input.sentenceStyle.isEmpty ? "（暂无数据）" : input.sentenceStyle)
            .replacingOccurrences(of: "{typing_rhythm}", with: input.typingRhythm.isEmpty ? "（暂无数据）" : input.typingRhythm)
            .replacingOccurrences(of: "{length_p25}", with: String(input.lengthP25))
            .replacingOccurrences(of: "{length_p50}", with: String(input.lengthP50))
            .replacingOccurrences(of: "{length_p75}", with: String(input.lengthP75))
            .replacingOccurrences(of: "{few_shot_examples}", with: fewShotText)
            .replacingOccurrences(of: "{message_pairs}", with: pairsText)
            .replacingOccurrences(of: "{frequent_phrases}", with: phrasesText)
            + input.replyStyleSuffix

        // First attempt
        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            await audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            await audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        // Retry with stricter instruction
        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry")
            return parsed
        }

        await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry")
        return nil
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "autoreply:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "自动回复")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let content = try await aiService.complete(
                system: "你是一个微信自动回复助手。你的任务是模仿用户的聊天风格，生成一条最合适的回复。严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.3, maxTokens: 512)
            )
            return ModelResponse(text: content, error: nil)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription)
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> Decision? {
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
        do {
            return try JSONDecoder().decode(Decision.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) async {
        let model = await aiService.currentConfig().model
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .autopilot,
            model: model,
            promptVersion: "autopilot_reply_v3",
            inputText: "[\(input.senderName)@\(input.chatName)|\(input.contactRole.rawValue)] \(input.messageBody)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AutoReplyGenerator: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Render the session ledger as a compact log block for `{session_ledger}`.
    /// Keeps only the most recent 8 entries (a single reply doesn't need
    /// the full 20-entry history) and trims peer quotes to 50 chars.
    static func formatLedger(_ entries: [LedgerEntry]) -> String {
        guard !entries.isEmpty else {
            return "（会话刚开始，你还没发过消息。）"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return entries.suffix(8).map { e in
            let time = fmt.string(from: e.timestamp)
            let peer = e.peerLastMessage.flatMap { text -> String in
                let snippet = text.count > 50 ? String(text.prefix(50)) + "…" : text
                return "对方: \"\(snippet)\""
            }
            let prefix = peer.map { "[\(time) \($0)]" } ?? "[\(time)]"
            return "\(prefix) → 你回:「\(e.outgoingText)」"
        }.joined(separator: "\n")
    }
}
