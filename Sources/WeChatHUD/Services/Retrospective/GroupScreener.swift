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
    /// Codenames group display names and sample text before the screen prompt
    /// leaves the machine. Owned per-screener by default; a caller may inject a
    /// shared instance so codenames stay stable across a whole run.
    private let redactor: Redactor

    /// Guards an extended outage from re-sending every undecided group's full
    /// sample set on every run. A single failure retries immediately next run
    /// (a transient blip must not wait out a cooldown); the cooldown starts
    /// after two consecutive incomplete screens. In-memory only, never
    /// persisted: a restart retries immediately, so a transient failure can
    /// never lock a group out the way the old persisted `ask_each_time` did.
    private var consecutiveIncompleteScreens = 0
    private var rescreenCoolUntil: Date?
    private static let rescreenCooldown: TimeInterval = 600

    init(
        store: HUDStore,
        aiService: any AIServiceProtocol,
        promptLoader: PromptLoader = PromptLoader(),
        dataLedger: DataLedger,
        redactor: Redactor = Redactor()
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.dataLedger = dataLedger
        self.redactor = redactor
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
            if let coolUntil = rescreenCoolUntil, coolUntil > Date() {
                // Still inside the outage cooldown: ask about them this run
                // and retry the screen once it lapses.
                ask.append(contentsOf: needAI)
            } else {
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
            if decided.count < needAI.count {
                consecutiveIncompleteScreens += 1
                if consecutiveIncompleteScreens >= 2 {
                    rescreenCoolUntil = Date().addingTimeInterval(Self.rescreenCooldown)
                }
            } else {
                consecutiveIncompleteScreens = 0
                rescreenCoolUntil = nil
            }
        }
        }

        return ScreenResult(included: included, excluded: excluded, askEachTime: ask)
    }

    /// Nil when no decision could be obtained (prompt load failure, AI error,
    /// or a reply with no parseable items).
    private func runAIScreen(_ candidates: [ScopeCandidate], samples: [String: [String]]) async -> [(ScopeCandidate, ScopeDecision, Double)]? {
        // The prompt leaves the machine, so the group's display name travels as
        // a codename and sample text is run through the redactor (display names
        // → codenames, phone/email/money masked). `chat_username` stays the
        // real id: `parse` matches each decision on it, and it is the only key
        // that uniquely identifies a group whose display name is a codename.
        // Pass 1: register every group name and @-mention up front, so the
        // redaction below knows all of them. A sample can name a group that is
        // itself screened later, and redacting that name needs the codename to
        // already exist.
        for c in candidates {
            _ = await redactor.codenameFor(username: c.chatUsername, displayName: c.chatName)
            for line in samples[c.chatUsername] ?? [] {
                await redactor.registerMentions(in: line)
            }
        }
        // Pass 2: build the redacted payload.
        var groupsArr: [[String: Any]] = []
        groupsArr.reserveCapacity(candidates.count)
        for c in candidates {
            let sample = samples[c.chatUsername] ?? []
            var redactedSample: [String] = []
            redactedSample.reserveCapacity(sample.count)
            for line in sample {
                redactedSample.append(await redactor.redactText(line))
            }
            let codename = await redactor.codenameFor(
                username: c.chatUsername, displayName: c.chatName
            )
            groupsArr.append([
                "chat_username": c.chatUsername,
                "chat_name": codename,
                "sample_messages": redactedSample
            ])
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
            redacted: true  // chat names are codenames; sample text is masked
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
