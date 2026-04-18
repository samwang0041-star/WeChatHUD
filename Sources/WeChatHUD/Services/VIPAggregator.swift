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
                return "  [\(ts)] \(t.rawText)"
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

        let started = Date()
        let response = await callModel(prompt: prompt)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let model = await aiService.currentConfig().model

        guard let body = response else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .vipAggregator,
                model: model, promptVersion: "vip_aggregator_v1",
                inputText: "vip:\(vipUsername) traces:\(traces.count)",
                outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: "no response"
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
        let batchID = "batch_\(vipUsername)_\(Int(Date().timeIntervalSince1970))"
        try? store.markVIPTracesBatched(ids: traces.map(\.id), batchID: batchID)

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .vipAggregator,
            model: model, promptVersion: "vip_aggregator_v1",
            inputText: "vip:\(vipUsername) traces:\(traces.count)",
            outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        return result
    }

    // MARK: - Private helpers

    private func callModel(prompt: String) async -> String? {
        let trackID = "vip:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "VIP 摘要")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            return try await aiService.complete(
                system: "只输出 JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 60, temperature: 0.1, maxTokens: 512)
            )
        } catch {
            return nil
        }
    }

    private func parseResult(_ text: String) -> AggregateResult? {
        let cleaned = cleanJSON(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AggregateResult.self, from: data)
    }

    private func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip <think>...</think> blocks
        while let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else { break }
        }
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}") {
            s = String(s[lo...hi])
        }
        return s
    }

    private func formatTime(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
