import Foundation

/// Decides which whitelist groups go through deep analysis (Spec §6.2 step 2,
/// §7.1). Three-state policy `include / exclude / askEachTime` is cached
/// per chat in `group_scope_policy`; AI is only invoked for groups not yet
/// in cache. Private chats (no `@chatroom` suffix on chatUsername) are
/// always included regardless of cache.
actor GroupScreener {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let dataLedger: DataLedger

    init(
        store: HUDStore,
        aiService: any AIServiceProtocol,
        promptLoader: PromptLoader = PromptLoader(),
        dataLedger: DataLedger
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.dataLedger = dataLedger
    }

    struct ScreenResult: Sendable {
        let included: [ScopeCandidate]
        let excluded: [ScopeCandidate]
        let askEachTime: [ScopeCandidate]
    }

    /// Resolves each candidate by checking cached policy first; falls back
    /// to AI for new groups. Private chats are always included.
    func screen(candidates: [ScopeCandidate], samples: [String: [String]]) async -> ScreenResult {
        var included: [ScopeCandidate] = []
        var excluded: [ScopeCandidate] = []
        var ask: [ScopeCandidate] = []
        var needAI: [ScopeCandidate] = []

        for c in candidates {
            if !c.isGroup {
                included.append(c)
                continue
            }
            if let policy = store.groupScopePolicy(chatUsername: c.chatUsername) {
                switch policy.decision {
                case .include: included.append(c)
                case .exclude: excluded.append(c)
                case .askEachTime: ask.append(c)
                }
                continue
            }
            needAI.append(c)
        }

        if !needAI.isEmpty {
            let aiDecisions = await runAIScreen(needAI, samples: samples)
            for (c, decision, confidence) in aiDecisions {
                // Spec §7.1: confidence < 0.7 forces askEachTime so user
                // gets to confirm rather than AI making a low-confidence call.
                let finalDecision: ScopeDecision = (confidence < 0.7) ? .askEachTime : decision
                store.upsertGroupScopePolicy(GroupScopePolicy(
                    chatUsername: c.chatUsername,
                    decision: finalDecision,
                    source: .ai,
                    decidedAt: Date(),
                    sampleHash: GroupScreener.hashSamples(samples[c.chatUsername] ?? []),
                    userAuthorized: false
                ))
                switch finalDecision {
                case .include: included.append(c)
                case .exclude: excluded.append(c)
                case .askEachTime: ask.append(c)
                }
            }
        }

        return ScreenResult(included: included, excluded: excluded, askEachTime: ask)
    }

    private func runAIScreen(_ candidates: [ScopeCandidate], samples: [String: [String]]) async -> [(ScopeCandidate, ScopeDecision, Double)] {
        let groupsArr: [[String: Any]] = candidates.map { c in
            [
                "chat_name": c.chatName,
                "sample_messages": samples[c.chatUsername] ?? []
            ]
        }
        let groupsData = (try? JSONSerialization.data(withJSONObject: groupsArr)) ?? Data()
        let groupsStr = String(data: groupsData, encoding: .utf8) ?? "[]"

        let template: String
        do {
            template = try promptLoader.load(version: "retrospective_group_screen_v1")
        } catch {
            print("[Retrospective] GroupScreener prompt load failed: \(error)")
            return candidates.map { ($0, .askEachTime, 0.0) }
        }
        let userPrompt = template.replacingOccurrences(of: "{groups_json}", with: groupsStr)

        let response: String
        do {
            response = try await aiService.complete(
                system: "你严格输出 JSON 数组。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 2048)
            )
        } catch {
            print("[Retrospective] GroupScreener AI call failed: \(error)")
            return candidates.map { ($0, .askEachTime, 0.0) }
        }

        // Ledger entry — note this happens regardless of parse outcome
        // (we sent bytes either way).
        let cfg = await aiService.currentConfig()
        await dataLedger.recordBatch([AILedgerEntry(
            id: 0, ts: Date(),
            provider: cfg.primarySlot.providerID,
            model: cfg.primarySlot.model,
            purpose: .groupScreen,
            chatCount: candidates.count, msgCount: nil,
            byteCount: userPrompt.utf8.count,
            tokenIn: nil, tokenOut: nil,
            redacted: false  // group screen sees plain chat names + sample text
        )])

        return GroupScreener.parse(response, candidates: candidates)
    }

    static func parse(_ raw: String, candidates: [ScopeCandidate]) -> [(ScopeCandidate, ScopeDecision, Double)] {
        guard let data = extractJSON(raw),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return candidates.map { ($0, .askEachTime, 0.0) }
        }
        var out: [(ScopeCandidate, ScopeDecision, Double)] = []
        for c in candidates {
            if let item = arr.first(where: { ($0["chat_name"] as? String) == c.chatName }) {
                let decisionRaw = (item["decision"] as? String) ?? "exclude"
                let conf = (item["confidence"] as? Double) ?? 0.5
                let decision = ScopeDecision(rawValue: decisionRaw) ?? .askEachTime
                out.append((c, decision, conf))
            } else {
                out.append((c, .askEachTime, 0.0))
            }
        }
        return out
    }

    static func extractJSON(_ s: String) -> Data? {
        var cleaned = s
        if let fence = cleaned.range(of: "```") {
            cleaned = String(cleaned[fence.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let end = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("[") {
            if let lo = cleaned.firstIndex(of: "["), let hi = cleaned.lastIndex(of: "]") {
                cleaned = String(cleaned[lo...hi])
            }
        }
        return cleaned.data(using: .utf8)
    }

    static func hashSamples(_ samples: [String]) -> String {
        let joined = samples.joined(separator: "|")
        // Cheap drift detector — not cryptographic. SHA would be overkill;
        // we just need "did the sample set materially change" for cache invalidation.
        var h: UInt64 = 5381
        for byte in joined.utf8 {
            h = (h &* 33) &+ UInt64(byte)
        }
        return String(h)
    }
}
