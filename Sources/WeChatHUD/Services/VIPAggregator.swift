import Foundation

/// Periodically batches unbatched VIP traces from all groups and sends them to AI for analysis.
actor VIPAggregator {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    // MARK: - Result type

    struct AggregateResult: Codable {
        let summary: String
        let involvesUser: Bool
        let involveDetail: String?
        let mood: String
        let moodEvidence: String
        let moodTrendAnalysis: String
        let urgency: String
        let urgencyReason: String
        let recommendedAction: String
        let actionTiming: String
        let keyTopics: [String]

        enum CodingKeys: String, CodingKey {
            case summary
            case involvesUser       = "involves_user"
            case involveDetail      = "involve_detail"
            case mood
            case moodEvidence       = "mood_evidence"
            case moodTrendAnalysis  = "mood_trend_analysis"
            case urgency
            case urgencyReason      = "urgency_reason"
            case recommendedAction  = "recommended_action"
            case actionTiming       = "action_timing"
            case keyTopics          = "key_topics"
        }

        func applyingMoodPreference(enabled: Bool, hasHistory: Bool) -> Self {
            Self(summary: summary, involvesUser: involvesUser, involveDetail: involveDetail,
                 mood: enabled ? mood : "", moodEvidence: enabled ? moodEvidence : "",
                 moodTrendAnalysis: enabled && hasHistory ? moodTrendAnalysis : "",
                 urgency: urgency, urgencyReason: urgencyReason, recommendedAction: recommendedAction,
                 actionTiming: actionTiming, keyTopics: keyTopics)
        }
    }

    // MARK: - Public API

    /// Load unbatched traces for `vipUsername`, group them by chat, build a prompt, call AI,
    /// mark traces as batched on success, and return the parsed result.
    /// Returns nil when there are no traces, AI is unavailable, or parsing fails.
    func aggregate(
        vipUsername: String,
        vipName: String,
        vipRole: ContactRole,
        userNameVariants: [String],
        recentMoodHistory: String,
        lastInteraction: String,
        commitmentCount: Int
    ) async -> AggregateResult? {
        let traces = store.loadUnbatchedVIPTraces(vipUsername: vipUsername)
        guard !traces.isEmpty else { return nil }

        guard await aiService.isConfigured() else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "vip_aggregator_v1") }
        catch { print("[WCHUD] VIPAggregator: prompt load failed: \(error)"); return nil }

        // Group traces by chatName
        var byGroup: [String: [VIPTrace]] = [:]
        for trace in traces {
            byGroup[trace.chatName, default: []].append(trace)
        }

        let activityByGroup = byGroup.map { (chatName, groupTraces) -> String in
            let lines = groupTraces.map { t -> String in
                let ts = formatTime(t.msgTime)
                return "  [\(ts)] \(AIService.sanitizeForAI(t.rawText))"
            }.joined(separator: "\n")
            return "【\(chatName)】\n\(lines)"
        }.joined(separator: "\n\n")

        // Detect user mentions
        let mentionedChats = byGroup.compactMap { (chatName, groupTraces) -> String? in
            let hasMention = groupTraces.contains { trace in
                userNameVariants.contains(where: { trace.rawText.contains($0) })
            }
            return hasMention ? chatName : nil
        }
        let userMentionedIn = mentionedChats.isEmpty ? "未检测到" : mentionedChats.joined(separator: "、")

        // Role dimensions
        let dimensions = vipRole.vipTrackDimensions
        let roleDimensions = dimensions.isEmpty
            ? "通用分析维度：工作态度、关系变化、重要请求"
            : dimensions.joined(separator: "、")

        let prompt = template
            .replacingOccurrences(of: "{vip_name}", with: vipName)
            .replacingOccurrences(of: "{role_label}", with: vipRole.label)
            .replacingOccurrences(of: "{role_description}", with: vipRole.roleDescription)
            .replacingOccurrences(of: "{mood_history}", with: recentMoodHistory.isEmpty ? "暂无记录" : recentMoodHistory)
            .replacingOccurrences(of: "{last_interaction}", with: lastInteraction.isEmpty ? "暂无记录" : lastInteraction)
            .replacingOccurrences(of: "{commitment_count}", with: "\(commitmentCount)")
            .replacingOccurrences(of: "{activity_by_group}", with: activityByGroup)
            .replacingOccurrences(of: "{user_mentioned_in}", with: userMentionedIn)
            .replacingOccurrences(of: "{role_dimensions}", with: roleDimensions)

        let moodEnabled = store.loadAIConfig().moodDetectionEnabled
        let hasMoodHistory = !recentMoodHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let moodInstruction = moodEnabled
            ? "情绪只能作为有原文依据的语气线索，不得断言对方心理状态。没有历史证据时 mood_trend_analysis 必须为空字符串。"
            : "用户已关闭 VIP 情绪检测。不要分析或推断情绪、语气、态度变化，mood、mood_evidence、mood_trend_analysis 必须为空字符串。仅整理消息事实与行动。"
        let started = Date()
        let response = await callModel(prompt: prompt, instruction: moodInstruction)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let model: String
        if let actualModel = response.model {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }

        guard let body = response.text else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .vipAggregator,
                model: model, promptVersion: "vip_aggregator_v1",
                inputText: "vip:\(vipUsername) traces:\(traces.count)",
                outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: response.error ?? "no response"
            ))
            return nil
        }

        guard let result = parseResult(body) else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .vipAggregator,
                model: model, promptVersion: "vip_aggregator_v1",
                inputText: "vip:\(vipUsername) traces:\(traces.count)",
                outputText: body,
                latencyMs: latency, status: .parseError, errorMessage: "JSON parse failed"
            ))
            return nil
        }

        // Mark traces as batched
        let batchID = Self.makeBatchID(vipUsername: vipUsername)
        try? store.markVIPTracesBatched(ids: traces.map(\.id), batchID: batchID)

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .vipAggregator,
            model: model, promptVersion: "vip_aggregator_v1",
            inputText: "vip:\(vipUsername) traces:\(traces.count)",
            outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        // A setting disabled while the request was in flight also takes effect.
        return result.applyingMoodPreference(
            enabled: moodEnabled && store.loadAIConfig().moodDetectionEnabled,
            hasHistory: hasMoodHistory)
    }

    // MARK: - Private helpers

    /// Build the id that groups the traces consumed by one aggregation run.
    ///
    /// Uniqueness matters because `store.markVIPTracesBatched(ids:batchID:)`
    /// stamps every trace of this run with this one value, and any later
    /// per-batch lookup or cleanup works on the shared id. Two runs for the
    /// same VIP inside one wall-clock second would therefore collide: run 1's
    /// traces would look like they belong to run 2's batch, and a cleanup for
    /// one run could delete or re-read the other's output. The `batch_<user>_<epoch>`
    /// prefix stays for readability (logs, manual SQL, existing fixtures), and
    /// an 8-char UUID fragment makes concurrent or same-second runs distinct.
    ///
    /// `nonce` is injectable so a test can pin determinism; production callers
    /// use the random default.
    ///
    /// The username length is embedded (`batch_<len>_<user>_<epoch>_<nonce>`) so
    /// an underscore inside a username cannot make the layout ambiguous. That
    /// keeps the format crash-free for any value WeChat stores, rather than
    /// requiring a precondition on data the app does not control.
    static func makeBatchID(
        vipUsername: String,
        now: Date = Date(),
        nonce: String = String(UUID().uuidString.prefix(8))
    ) -> String {
        "batch_\(vipUsername.count)_\(vipUsername)_\(Int(now.timeIntervalSince1970))_\(nonce)"
    }

    private struct ModelResponse {
        let text: String?
        let error: String?
        let model: String?
    }

    private func callModel(prompt: String, instruction: String) async -> ModelResponse {
        let trackID = "vip:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "VIP 摘要")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "只输出 JSON。" + instruction,
                user: prompt,
                options: CompleteOptions(timeout: 60, temperature: 0.1, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: nil, error: error.localizedDescription, model: nil)
        }
    }

    private func parseResult(_ text: String) -> AggregateResult? {
        AIJSONExtractor.decodeFirstObject(from: text, as: AggregateResult.self)
    }

    private func formatTime(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
