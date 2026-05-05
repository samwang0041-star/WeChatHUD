import Foundation

/// Generates 3 reply candidates for an inbound WeChat message in
/// 3 different tones (friendly / formal / brief). Designed to be
/// surfaced as a context menu on a "待决" row so the user can
/// one-click a reply without typing.
///
/// Pure service. No DB writes (apart from audit log via the shared
/// HUDStore). Reads its config from `loadAIConfig()` so it
/// always tracks whatever model the user has set.
///
/// See `docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md`
/// for the role definitions and gating.
actor AIReplySuggester {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "reply_suggester_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// One reply suggestion. `tone` matches the prompt's friendly /
    /// formal / brief vocabulary.
    struct Suggestion: Decodable {
        let text: String
        let tone: String
        let rationale: String
        let intent: String?
        let safeToSend: Bool

        enum CodingKeys: String, CodingKey {
            case text, tone, rationale, intent
            case safeToSend = "safe_to_send"
        }

        init(text: String, tone: String, rationale: String, intent: String? = nil, safeToSend: Bool = true) {
            self.text = text
            self.tone = tone
            self.rationale = rationale
            self.intent = intent
            self.safeToSend = safeToSend
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            tone = try c.decode(String.self, forKey: .tone)
            rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
            intent = try c.decodeIfPresent(String.self, forKey: .intent)
            safeToSend = try c.decodeIfPresent(Bool.self, forKey: .safeToSend) ?? false
        }
    }

    /// Top-level schema returned by the model. Stays decoupled from
    /// the public Suggestion type.
    private struct ResultDTO: Decodable {
        let suggestions: [Suggestion]
    }

    /// Input bundle. `askType` and `relationship` come from the
    /// caller's existing PendingAsk + whitelist lookup so we don't
    /// re-classify the message just to suggest replies.
    struct Input {
        let messageBody: String
        let senderName: String
        let chatName: String
        let isGroup: Bool
        let askType: AskType
        /// "work" / "life" / "other" — comes from whitelist category,
        /// or "unknown" if not on whitelist.
        let relationship: String
        /// Optional style hint from StyleProfiler to match user's writing style.
        let styleHint: String?
        /// Optional feedback context — what the user liked/disliked in past suggestions.
        let feedbackContext: String?
        /// Speaker-labelled recent context around the target message.
        let contextWindow: String?
        /// User's latest outbound message in this conversation.
        let myLastReply: String?
        /// Compact result from the current-message analysis layer.
        let analysisSummary: String?
        /// Relationship hierarchy in machine-readable form.
        let relationshipHierarchy: String?
        /// Tone preference inferred from the relationship profile.
        let tonePreference: String?
        /// Known constraints: memory, pending asks, commitments, or safety notes.
        let knownConstraints: String?

        init(messageBody: String, senderName: String, chatName: String,
             isGroup: Bool, askType: AskType, relationship: String,
             styleHint: String? = nil, feedbackContext: String? = nil,
             contextWindow: String? = nil, myLastReply: String? = nil,
             analysisSummary: String? = nil, relationshipHierarchy: String? = nil,
             tonePreference: String? = nil, knownConstraints: String? = nil) {
            self.messageBody = messageBody
            self.senderName = senderName
            self.chatName = chatName
            self.isGroup = isGroup
            self.askType = askType
            self.relationship = relationship
            self.styleHint = styleHint
            self.feedbackContext = feedbackContext
            self.contextWindow = contextWindow
            self.myLastReply = myLastReply
            self.analysisSummary = analysisSummary
            self.relationshipHierarchy = relationshipHierarchy
            self.tonePreference = tonePreference
            self.knownConstraints = knownConstraints
        }
    }

    /// Returns 3 candidate replies, or nil if the model failed twice.
    /// Audits every call (success and failure) to `ai_audit`.
    func suggest(_ input: Input) async -> [Suggestion]? {
        guard await aiService.currentConfig().suggestionsEnabled else { return nil }
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIReplySuggester: prompt load failed: \(error)")
            return nil
        }

        var userPrompt = template
            .replacingOccurrences(of: "{message_body}", with: clean(input.messageBody))
            .replacingOccurrences(of: "{sender_name}", with: clean(input.senderName))
            .replacingOccurrences(of: "{chat_name}", with: clean(input.chatName))
            .replacingOccurrences(of: "{chat_kind}", with: input.isGroup ? "群聊" : "私聊")
            .replacingOccurrences(of: "{ask_type}", with: input.askType.rawValue)
            .replacingOccurrences(of: "{relationship}", with: input.relationship)
            .replacingOccurrences(of: "{relationship_hierarchy}", with: input.relationshipHierarchy ?? "unknown")
            .replacingOccurrences(of: "{tone_preference}", with: input.tonePreference ?? "unknown")
            .replacingOccurrences(of: "{context_window}", with: input.contextWindow ?? "（无可用上下文）")
            .replacingOccurrences(of: "{my_last_reply}", with: input.myLastReply ?? "（无）")
            .replacingOccurrences(of: "{analysis_summary}", with: input.analysisSummary ?? "（无）")
            .replacingOccurrences(of: "{known_constraints}", with: input.knownConstraints ?? "（无）")

        // Append style hint if available (from StyleProfiler)
        if let hint = input.styleHint {
            userPrompt += "\n\n[风格参考] \(hint)"
        }
        // Append feedback context (from AI learning loop)
        if let feedback = input.feedbackContext {
            userPrompt += "\n\n[用户偏好反馈] \(feedback)"
        }

        // First attempt
        let first = await call(userPrompt)
        if let parsed = parse(first.text, input: input) {
            await audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil, model: first.model)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            await audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err, model: first.model)
            return nil
        }

        // Stricter retry
        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let parsed = parse(second.text, input: input) {
            await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry", model: second.model)
            return parsed
        }

        await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry", model: second.model)
        return nil
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "reply:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "回复建议")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个回复建议助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.4, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String, input: Input) -> [Suggestion]? {
        guard let dto = AIJSONExtractor.decodeFirstObject(from: raw, as: ResultDTO.self) else { return nil }
        let validTones: Set<String> = ["recommended", "friendly", "formal", "brief", "professional", "concise", "友好", "正式", "简洁"]
        let sensitiveKeywords = (store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).sensitiveKeywords
        let sensitiveSourceKeywords = sensitiveKeywords + Self.semanticSensitiveSourceKeywords
        let sourceText = [
            input.messageBody,
            input.contextWindow,
            input.analysisSummary,
            input.knownConstraints
        ].compactMap { $0 }.joined(separator: "\n")
        let sourceHasSensitiveSignal = Self.containsAnyKeyword(sourceText, keywords: sensitiveSourceKeywords)
        let highCommitmentIntents: Set<String> = ["accept", "decline"]
        let filtered = dto.suggestions
            .filter { $0.safeToSend }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { validTones.contains($0.tone.lowercased()) || validTones.contains($0.tone) }
            .filter { suggestion in
                !Self.containsAnyKeyword(suggestion.text, keywords: sensitiveKeywords)
            }
            .filter { suggestion in
                guard input.askType == .none else { return true }
                return !Self.isLowInformationSmalltalk(suggestion.text)
            }
            .filter { suggestion in
                guard sourceHasSensitiveSignal else { return true }
                let intent = suggestion.intent?.lowercased() ?? ""
                return !highCommitmentIntents.contains(intent)
                    && Self.isConservativeHandoff(suggestion.text)
            }
            .prefix(3)
        if filtered.isEmpty {
            return [Self.conservativeFallbackSuggestion(sourceHasSensitiveSignal: sourceHasSensitiveSignal)]
        }
        return Array(filtered)
    }

    nonisolated private static func isLowInformationSmalltalk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let collapsed = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let lower = collapsed.lowercased()
        let banned: Set<String> = [
            "👍", "👌", "ok", "okay", "哈哈", "不错", "可以", "惬意",
            "👍惬意", "收到", "了解", "挺好", "舒服"
        ]
        if banned.contains(lower) || banned.contains(collapsed) {
            return true
        }
        if collapsed.count <= 2 {
            return true
        }
        return false
    }

    nonisolated private static func containsAnyKeyword(_ text: String, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let lower = text.lowercased()
        return keywords.contains { keyword in
            !keyword.isEmpty && lower.contains(keyword.lowercased())
        }
    }

    nonisolated private static func isConservativeHandoff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 30 else { return false }
        let allowPatterns = ["看下", "确认", "核实", "晚点", "稍后", "回你", "再回", "查一下"]
        let denyPatterns = ["可以", "没问题", "同意", "确认签", "转", "汇", "付款", "报价", "辞退", "离职"]
        return allowPatterns.contains { trimmed.contains($0) }
            && !denyPatterns.contains { trimmed.contains($0) }
    }

    nonisolated private static var semanticSensitiveSourceKeywords: [String] {
        [
            "报价", "付款", "打款", "支付", "签", "签字", "签约",
            "审批", "批准", "同意", "可以吗", "能不能", "确认付款",
            "合同", "发票", "人事", "离职", "辞退", "医疗", "法务"
        ]
    }

    nonisolated private static func conservativeFallbackSuggestion(sourceHasSensitiveSignal: Bool) -> Suggestion {
        Suggestion(
            text: sourceHasSensitiveSignal ? "我确认下再回你" : "我看下再回你",
            tone: "recommended",
            rationale: sourceHasSensitiveSignal ? "涉及敏感信息" : "需人工确认",
            intent: "delay",
            safeToSend: true
        )
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .ranker,           // reply suggestion is a "ranker" role per design
            model: model,
            promptVersion: promptVersion,
            inputText: "[\(input.senderName)@\(input.chatName)|\(input.askType.rawValue)] \(input.messageBody)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIReplySuggester: failed to write audit: \(error)")
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
}
