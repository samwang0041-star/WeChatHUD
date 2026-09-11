import Foundation

/// Scans YOUR outgoing messages for promises/commitments.
actor CommitmentTracker {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    struct CommitmentResult {
        let isCommitment: Bool
        let content: String
        let commitTo: String
        let deadlineExtracted: String
        let confidence: Double
        let sourceText: String
        let contextText: String
        let captureReason: String
        let nextStep: String
        let deadlineLabel: String
        let commitmentKind: String
    }

    /// Outcome of a fulfillment check run against a pending commitment.
    /// Pure-algorithm — no AI. If you need more nuance later, wrap
    /// ambiguous `.stillPending` cases in an AI semantic pass.
    enum FulfillmentSignal {
        /// Subsequent self-message evidence shows the promise was kept.
        case fulfilled(reason: String)
        /// Deadline has passed with no evidence of fulfillment.
        case overdue
        /// No evidence yet, deadline not yet passed.
        case stillPending
    }

    /// Keywords that strongly indicate "this thing was delivered".
    /// Kept as plain strings (no regex) because case-sensitivity in
    /// Chinese doesn't matter and the list is small.
    private static let fulfillmentKeywords: [String] = [
        "发你了", "发给你了", "发给您了", "已发", "已给你", "已发送",
        "给你了", "给您了", "传你了", "传给你", "推你了", "推给你",
        "搞定了", "搞定", "完成了", "完成", "已完成",
        "处理完了", "处理好了", "处理完", "处理完毕",
        "做好了", "做完了", "做完", "弄好了", "弄完",
        "OK了", "ok了", "Ok了", "好了", "办好了",
        "安排好了", "安排完了", "跟进完了"
    ]

    /// Decide whether a commitment can be considered fulfilled given
    /// a set of the user's outbound messages that landed AFTER the
    /// commitment was made in the same chat.
    static func evaluateFulfillment(
        commitment: Commitment,
        subsequentSelfMessages: [MessageInfo],
        now: Date = Date()
    ) -> FulfillmentSignal {
        // An unqualified “完成/好了” or attachment cannot identify which promise
        // was fulfilled. Require the specific subject and a declarative completion
        // in the same later message; uncertain evidence stays available for review.
        let subject = fulfillmentSubject(commitment.content)
        if subject.count >= 4 {
            for msg in subsequentSelfMessages where
                msg.chatUsername == commitment.chatUsername &&
                msg.createTime > Int(commitment.createdAt.timeIntervalSince1970) {
                let text = compactFulfillmentText(msg.text)
                let uncertain = ["没", "未", "不", "还差", "等", "将", "会", "准备", "打算",
                                 "明天", "稍后", "回头", "能否", "是否", "如果", "吗", "么", "？", "?",
                                 "部分", "初稿", "草稿", "进度", "一半", "%", "其中", "你说", "他说", "据说", "说过",
                                 "待", "需要", "完成后", "完成前", "完成时", "完成再", "完成就", "预计", "计划", "正在", "怎么"]
                guard !uncertain.contains(where: { text.contains($0) }),
                      text.contains(subject),
                      let matched = fulfillmentKeywords.first(where: { text.contains($0) }) else { continue }
                return .fulfilled(reason: "后续消息明确交付「\(subject)」：\(matched)")
            }
        }

        // 3. Deadline check — no evidence but deadline has passed.
        if let deadline = commitment.deadlineAt, deadline < now {
            return .overdue
        }

        return .stillPending
    }

    private static func compactFulfillmentText(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// Remove only delivery boilerplate, keeping the full remaining subject.
    /// Short/generic subjects intentionally need manual confirmation.
    private static func fulfillmentSubject(_ content: String) -> String {
        var subject = compactFulfillmentText(content)
        let prefixes = ["我会", "我来", "我", "明天", "今天", "稍后", "回头", "把", "发送", "发"]
        while let prefix = prefixes.first(where: { subject.hasPrefix($0) }) {
            subject.removeFirst(prefix.count)
        }
        for suffix in ["发给你", "发给您", "给你", "给您", "发你"] {
            if subject.hasSuffix(suffix) {
                subject.removeLast(suffix.count)
                break
            }
        }
        return subject.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Quick pre-filter: does message contain commitment signal words?
    /// This is additive — signals passed to AI as hints.
    static func hasCommitmentSignal(_ text: String) -> Bool {
        let signals = [
            "明天", "下周", "今天内", "稍后", "一会儿", "马上",
            "我去", "我来", "我发", "我问", "我看看", "我处理",
            "我安排", "我跟进", "我确认", "帮你", "给你", "发你",
            "回头", "等我", "好的", "没问题", "可以", "行",
            "OK", "ok", "收到", "了解", "月底前", "周五之前"
        ]
        return signals.contains(where: { text.contains($0) })
    }

    /// Analyze a message you sent. Returns nil if AI unavailable.
    func analyze(
        yourMessage: MessageInfo,
        contextMessages: [AnnotatedMessage],
        recipientName: String,
        recipientRole: ContactRole
    ) async -> CommitmentResult? {
        let template: String
        do { template = try promptLoader.load(version: "commitment_v1") }
        catch { print("[WCHUD] CommitmentTracker: prompt load failed: \(error)"); return nil }

        let signals = CommitmentTracker.hasCommitmentSignal(yourMessage.text)
            ? "算法检测到承诺信号词" : "算法未检测到明显信号词"

        // Absolute time with weekday, not "3小时前": the model has to decide
        // what "下周三" and "明天" mean, and it can only do that if it knows
        // the message's own calendar day. Relative wording was the only anchor
        // before, which left every weekday deadline unresolvable.
        let contextText = contextMessages.map {
            "[\(MessageInfo.formatAbsoluteForPrompt($0.createTime))] \($0.senderName): \(AIService.sanitizeForAI($0.text))"
        }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{recipient_name}", with: recipientName)
            .replacingOccurrences(of: "{recipient_role}", with: recipientRole.label)
            .replacingOccurrences(of: "{message_time}", with: MessageInfo.formatAbsoluteForPrompt(yourMessage.createTime))
            .replacingOccurrences(of: "{commitment_signals}", with: signals)
            .replacingOccurrences(of: "{context_messages}", with: contextText)
            .replacingOccurrences(of: "{user_message}", with: AIService.sanitizeForAI(yourMessage.text))

        let started = Date()
        let response = await callModel(prompt: prompt)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let model: String
        if let actualModel = response.model {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }

        guard let body = response.text else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: response.error ?? "no response"
            ))
            return nil
        }

        if let result = parseResult(body) {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: body,
                latencyMs: latency, status: .ok, errorMessage: nil
            ))
            return result
        }

        // Parse failed — same pattern as AIClassifier/AIReplySuggester:
        // retry once with a strict-JSON reminder appended. Many models
        // cooperate the second time even when the first answer had
        // a trailing comma, code fence, or chatty preamble.
        let strictPrompt = prompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要 markdown 代码块，不要任何解释性文字。"
        let retry = await callModel(prompt: strictPrompt)
        let retryLatency = Int(Date().timeIntervalSince(started) * 1000)
        let retryModel = retry.model ?? model
        if let retryBody = retry.text, let result = parseResult(retryBody) {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: retryModel, promptVersion: "commitment_v1_retry",
                inputText: yourMessage.text, outputText: retryBody,
                latencyMs: retryLatency, status: .ok, errorMessage: nil
            ))
            return result
        }

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .commitmentTracker,
            model: retryModel, promptVersion: "commitment_v1",
            inputText: yourMessage.text, outputText: body,
            latencyMs: retryLatency, status: .parseError,
            errorMessage: "JSON parse failed on both initial and strict-retry"
        ))
        return nil
    }

    private struct ModelResponse {
        let text: String?
        let error: String?
        let model: String?
    }

    private func callModel(prompt: String) async -> ModelResponse {
        let trackID = "commitment:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "承诺识别")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "只输出 JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 30, temperature: 0.05, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: nil, error: error.localizedDescription, model: nil)
        }
    }

    private func parseResult(_ text: String) -> CommitmentResult? {
        let cleaned = cleanJSON(text)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isCommitment = json["is_commitment"] as? Bool else { return nil }
        // When AI says it IS a commitment, require content and commit_to
        // to be present — empty strings indicate a malformed response.
        if isCommitment {
            guard let content = json["content"] as? String, !content.isEmpty,
                  let commitTo = json["commit_to"] as? String, !commitTo.isEmpty else {
                return nil
            }
            return CommitmentResult(
                isCommitment: true,
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                commitTo: commitTo,
                deadlineExtracted: json["deadline_extracted"] as? String ?? "none",
                confidence: json["confidence"] as? Double ?? 0.0,
                sourceText: json["source_text"] as? String ?? "",
                contextText: json["context_summary"] as? String ?? "",
                captureReason: json["capture_reason"] as? String ?? "",
                nextStep: json["next_step"] as? String ?? "",
                deadlineLabel: json["deadline_label"] as? String ?? "",
                commitmentKind: json["commitment_kind"] as? String ?? ""
            )
        }
        // Not a commitment — fields are irrelevant, safe to use defaults.
        return CommitmentResult(
            isCommitment: false,
            content: "",
            commitTo: "",
            deadlineExtracted: "none",
            confidence: json["confidence"] as? Double ?? 0.0,
            sourceText: "",
            contextText: "",
            captureReason: json["capture_reason"] as? String ?? "",
            nextStep: "",
            deadlineLabel: "",
            commitmentKind: ""
        )
    }

    private func cleanJSON(_ text: String) -> String {
        AIJSONExtractor.firstObjectString(from: text)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
