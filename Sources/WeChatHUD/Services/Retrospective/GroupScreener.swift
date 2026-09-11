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
            // A nil result means the screen produced no usable decisions at all
            // (prompt missing, AI error, unparseable reply). Cache nothing in
            // that case: a transient outage used to be persisted as
            // `ask_each_time` with source `.ai`, which silently excluded the
            // group from every later run with no way to recover.
            let aiDecisions = await runAIScreen(needAI, samples: samples) ?? []
            var decided = Set<String>()
            for (c, decision, confidence) in aiDecisions {
                decided.insert(c.chatUsername)
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
            // Candidates the model did not answer: ask about them this run,
            // cache nothing, retry the screen next run.
            for c in needAI where !decided.contains(c.chatUsername) {
                ask.append(c)
            }
        }

        return ScreenResult(included: included, excluded: excluded, askEachTime: ask)
    }

    /// Nil when no decision could be obtained (prompt load failure, AI error,
    /// or a reply with no parseable items).
    private func runAIScreen(_ candidates: [ScopeCandidate], samples: [String: [String]]) async -> [(ScopeCandidate, ScopeDecision, Double)]? {
        let groupsArr: [[String: Any]] = candidates.map { c in
            [
                // Stable key: the model echoes it back and `parse` matches on it,
                // so two groups that happen to share a display name cannot be
                // given the same decision.
                "chat_username": c.chatUsername,
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
            return nil
        }
        let userPrompt = template.replacingOccurrences(of: "{groups_json}", with: groupsStr)

        let response: AICompletionResult
        do {
            response = try await aiService.completeWithMetadata(
                system: "你严格输出 JSON 对象。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 2048, responseFormatJSON: true)
            )
        } catch {
            print("[Retrospective] GroupScreener AI call failed: \(error)")
            return nil
        }

        // Ledger entry — note this happens regardless of parse outcome
        // (we sent bytes either way).
        await dataLedger.recordBatch([AILedgerEntry(
            id: 0, ts: Date(),
            provider: response.providerID,
            model: response.model,
            purpose: .groupScreen,
            chatCount: candidates.count, msgCount: nil,
            byteCount: userPrompt.utf8.count,
            tokenIn: nil, tokenOut: nil,
            redacted: false  // group screen sees plain chat names + sample text
        )])

        return GroupScreener.parse(response.text, candidates: candidates)
    }

    /// Decisions the model actually made, in candidate order.
    ///
    /// Matching prefers the stable `chat_username`; `chat_name` remains as a
    /// fallback for replies that predate that key, but each reply item is
    /// consumed at most once so two same-named groups cannot share one
    /// decision. Candidates the model skipped are simply absent — the caller
    /// asks about them without caching anything.
    static func parse(_ raw: String, candidates: [ScopeCandidate]) -> [(ScopeCandidate, ScopeDecision, Double)] {
        guard var remaining = extractItems(raw) else { return [] }
        var out: [(ScopeCandidate, ScopeDecision, Double)] = []
        for c in candidates {
            let index = remaining.firstIndex { entry in
                if let key = entry["chat_username"] as? String, !key.isEmpty {
                    return key == c.chatUsername
                }
                return (entry["chat_name"] as? String) == c.chatName
            }
            guard let index else { continue }
            let item = remaining.remove(at: index)
            let decisionRaw = (item["decision"] as? String) ?? "exclude"
            let conf = (item["confidence"] as? Double) ?? 0.5
            let decision = ScopeDecision(rawValue: decisionRaw) ?? .askEachTime
            out.append((c, decision, conf))
        }
        return out
    }

    static func extractJSON(_ s: String) -> Data? {
        AIJSONExtractor.firstArrayString(from: s)?.data(using: .utf8)
    }

    private static func extractItems(_ s: String) -> [[String: Any]]? {
        if let objectText = AIJSONExtractor.firstObjectString(from: s),
           let data = objectText.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = root["items"] as? [[String: Any]] {
            return items
        }
        guard let data = extractJSON(s),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr
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
