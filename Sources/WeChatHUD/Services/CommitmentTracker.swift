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

    /// Hints in the commitment content that the thing being promised
    /// is a tangible deliverable (file/image/link). NOUNS only — we
    /// deliberately don't include generic verbs like "发/给" because
    /// phrases like "给个决定" or "发个通知" contain them but don't
    /// imply a file will be sent. Only a concrete deliverable noun
    /// gates the file-send-as-fulfillment heuristic.
    private static let deliverableHints: [String] = [
        "文件", "方案", "资料", "材料", "链接",
        "图", "照片", "截图", "文档", "名单", "表格", "PPT", "ppt",
        "合同", "报告", "草案", "清单"
    ]

    /// Decide whether a commitment can be considered fulfilled given
    /// a set of the user's outbound messages that landed AFTER the
    /// commitment was made in the same chat.
    static func evaluateFulfillment(
        commitment: Commitment,
        subsequentSelfMessages: [MessageInfo],
        now: Date = Date()
    ) -> FulfillmentSignal {
        // 1. Text evidence — any fulfillment keyword in later messages.
        for msg in subsequentSelfMessages {
            if let matched = fulfillmentKeywords.first(where: { msg.text.contains($0) }) {
                return .fulfilled(reason: "后续消息含「\(matched)」")
            }
        }

        // 2. Deliverable evidence — commitment mentions sending
        //    something AND we see a file-class outbound message.
        let isDeliverable = deliverableHints.contains { commitment.content.contains($0) }
        if isDeliverable {
            for msg in subsequentSelfMessages {
                // baseType 3=image, 43=video, 49=link (WeChat layout).
                if msg.baseType == 3 || msg.baseType == 43 || msg.baseType == 49 {
                    let label: String
                    switch msg.baseType {
                    case 3:  label = "图片"
                    case 43: label = "视频"
                    case 49: label = "链接/文件"
                    default: label = "媒体"
                    }
                    return .fulfilled(reason: "后续发送了\(label)")
                }
            }
        }

        // 3. Deadline check — no evidence but deadline has passed.
        if let deadline = commitment.deadlineAt, deadline < now {
            return .overdue
        }

        return .stillPending
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

        let contextText = contextMessages.map {
            "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \(AIService.sanitizeForAI($0.text))"
        }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{recipient_name}", with: recipientName)
            .replacingOccurrences(of: "{recipient_role}", with: recipientRole.label)
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
                options: CompleteOptions(timeout: 30, temperature: 0.05, maxTokens: 256, responseFormatJSON: true)
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
                content: content,
                commitTo: commitTo,
                deadlineExtracted: json["deadline_extracted"] as? String ?? "none",
                confidence: json["confidence"] as? Double ?? 0.0
            )
        }
        // Not a commitment — fields are irrelevant, safe to use defaults.
        return CommitmentResult(
            isCommitment: false,
            content: "",
            commitTo: "",
            deadlineExtracted: "none",
            confidence: json["confidence"] as? Double ?? 0.0
        )
    }

    private func cleanJSON(_ text: String) -> String {
        AIJSONExtractor.firstObjectString(from: text)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
