import Foundation

protocol ReplyDebtLLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

extension AIService: ReplyDebtLLMClient {}

struct ReplyDebtJudge {
    enum Confidence: String {
        case high
        case medium
        case low
    }

    enum PriorityOverride: String {
        case keep
        case p0
        case p1
        case p2

        var priority: ReplyDebtPriority? {
            switch self {
            case .keep: return nil
            case .p0: return .p0
            case .p1: return .p1
            case .p2: return .p2
            }
        }
    }

    struct Judgment {
        let chatUsername: String
        let needsReply: Bool
        let priorityOverride: PriorityOverride
        let confidence: Confidence
        let aiReason: String
    }

    private struct RequestPayload: Encodable {
        let nowTs: Int
        let candidates: [Candidate]
    }

    private struct Candidate: Encodable {
        let chatUsername: String
        let chatName: String
        let isGroup: Bool
        let isWhitelisted: Bool
        let unreadCount: Int
        let ruleScore: Int
        let priority: String
        let ageMinutes: Int
        let latestInbound: String
        let latestOutbound: String?
        let inboundCountSinceLastOutbound: Int
        let reasonCodes: [String]
    }

    private let now: Date
    private let logger: @Sendable (String) -> Void

    init(
        now: Date = Date(),
        logger: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.now = now
        self.logger = logger
    }

    func apply(
        to items: [ReplyDebtItem],
        config: ReplyDebtAIConfig,
        client: any ReplyDebtLLMClient,
        model: String = "",
        store: HUDStore? = nil,
        promptVersion: String = "reply_debt_judge_v1"
    ) async -> [ReplyDebtItem] {
        let started = Date()
        let candidates = candidateItems(from: items, config: config)
        guard !candidates.isEmpty else { return items }

        let payload: String
        do {
            payload = try makePayload(candidates: candidates)
        } catch {
            logger("[ReplyDebtAI] payload encode failed: \(error)")
            return items
        }

        let rawResponse: String
        do {
            rawResponse = try await withTimeout(seconds: config.requestTimeoutSeconds) {
                try await client.complete(
                    system: Self.systemPrompt,
                    user: payload
                )
            }
        } catch {
            writeAudit(
                store: store,
                model: model,
                promptVersion: promptVersion,
                inputText: payload,
                outputText: "",
                latencyMs: ms(since: started),
                status: status(for: error),
                errorMessage: String(describing: error)
            )
            logger("[ReplyDebtAI] request failed: \(error)")
            return items
        }

        let judgments: [String: Judgment]
        do {
            judgments = try parseJudgments(
                rawResponse,
                allowedChatUsernames: Set(candidates.map(\.chatUsername))
            )
        } catch {
            writeAudit(
                store: store,
                model: model,
                promptVersion: promptVersion,
                inputText: payload,
                outputText: rawResponse,
                latencyMs: ms(since: started),
                status: .parseError,
                errorMessage: String(describing: error)
            )
            logger("[ReplyDebtAI] response parse failed: \(error)")
            return items
        }

        if config.shadowMode {
            let summary = shadowDiffSummary(items: candidates, judgments: judgments)
            writeAudit(
                store: store,
                model: model,
                promptVersion: promptVersion,
                inputText: payload,
                outputText: rawResponse,
                latencyMs: ms(since: started),
                status: .ok,
                errorMessage: summary
            )
            logShadowDiffs(items: candidates, judgments: judgments)
            return items
        }

        let result = applyActiveJudgments(items: items, judgments: judgments)
        let summary = activeDiffSummary(originalItems: items, finalItems: result, judgments: judgments)
        writeAudit(
            store: store,
            model: model,
            promptVersion: promptVersion,
            inputText: payload,
            outputText: rawResponse,
            latencyMs: ms(since: started),
            status: .ok,
            errorMessage: summary
        )
        return result
    }

    private func candidateItems(
        from items: [ReplyDebtItem],
        config: ReplyDebtAIConfig
    ) -> [ReplyDebtItem] {
        items
            .filter { $0.score >= config.minRuleScore }
            .prefix(max(1, config.maxCandidates))
            .map { $0 }
    }

    private func makePayload(candidates: [ReplyDebtItem]) throws -> String {
        let payload = RequestPayload(
            nowTs: Int(now.timeIntervalSince1970),
            candidates: candidates.map { item in
                Candidate(
                    chatUsername: item.chatUsername,
                    chatName: item.chatName,
                    isGroup: item.isGroup,
                    isWhitelisted: item.isWhitelisted,
                    unreadCount: item.unreadCount,
                    ruleScore: item.score,
                    priority: item.priority.rawValue,
                    ageMinutes: max(0, Int(now.timeIntervalSince(item.timestamp) / 60)),
                    latestInbound: item.preview,
                    latestOutbound: item.latestOutboundPreview,
                    inboundCountSinceLastOutbound: item.inboundCountSinceLastOutbound,
                    reasonCodes: item.reasons.map(\.code.rawValue)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReplyDebtJudgeError.invalidPayloadEncoding
        }
        return json
    }

    private func parseJudgments(
        _ raw: String,
        allowedChatUsernames: Set<String>
    ) throws -> [String: Judgment] {
        let jsonText = try extractJSONObject(from: raw)
        guard let data = jsonText.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["judgments"] as? [[String: Any]] else {
            throw ReplyDebtJudgeError.invalidResponseShape
        }

        var judgments: [String: Judgment] = [:]
        for row in rows {
            guard let judgment = parseJudgmentRow(row),
                  allowedChatUsernames.contains(judgment.chatUsername),
                  judgments[judgment.chatUsername] == nil else { continue }
            judgments[judgment.chatUsername] = judgment
        }
        return judgments
    }

    private func parseJudgmentRow(_ row: [String: Any]) -> Judgment? {
        guard let chatUsername = row["chat_username"] as? String,
              let needsReply = row["needs_reply"] as? Bool,
              let priorityRaw = (row["priority_override"] as? String)?.lowercased(),
              let priorityOverride = PriorityOverride(rawValue: priorityRaw),
              let confidenceRaw = (row["confidence"] as? String)?.lowercased(),
              let confidence = Confidence(rawValue: confidenceRaw),
              let aiReasonRaw = row["ai_reason"] as? String else {
            return nil
        }

        let aiReason = String(
            aiReasonRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60)
        )
        guard !chatUsername.isEmpty, !aiReason.isEmpty else { return nil }

        return Judgment(
            chatUsername: chatUsername,
            needsReply: needsReply,
            priorityOverride: priorityOverride,
            confidence: confidence,
            aiReason: aiReason
        )
    }

    private func extractJSONObject(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let unfenced = lines
                .dropFirst()
                .dropLast()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !unfenced.isEmpty {
                return unfenced
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            throw ReplyDebtJudgeError.invalidResponseShape
        }
        return String(trimmed[start...end])
    }

    private func logShadowDiffs(
        items: [ReplyDebtItem],
        judgments: [String: Judgment]
    ) {
        for item in items {
            guard let judgment = judgments[item.chatUsername] else { continue }

            if !judgment.needsReply {
                logger(
                    "[ReplyDebtAI][shadow] would suppress \(item.chatName) "
                        + "(\(judgment.confidence.rawValue)): \(judgment.aiReason)"
                )
                continue
            }

            let adjusted = adjustedPriority(
                original: item.priority,
                override: judgment.priorityOverride
            )
            guard adjusted != item.priority else { continue }
            logger(
                "[ReplyDebtAI][shadow] would change \(item.chatName) "
                    + "\(item.priority.rawValue)->\(adjusted.rawValue): \(judgment.aiReason)"
            )
        }
    }

    private func shadowDiffSummary(
        items: [ReplyDebtItem],
        judgments: [String: Judgment]
    ) -> String {
        let diffs = items.compactMap { item -> String? in
            guard let judgment = judgments[item.chatUsername] else { return nil }
            if !judgment.needsReply {
                return "shadow suppress \(item.chatName) [\(judgment.confidence.rawValue)]"
            }
            let adjusted = adjustedPriority(original: item.priority, override: judgment.priorityOverride)
            guard adjusted != item.priority else { return nil }
            return "shadow \(item.chatName) \(item.priority.rawValue)->\(adjusted.rawValue)"
        }
        return diffs.isEmpty ? "shadow keep" : diffs.prefix(5).joined(separator: " | ")
    }

    private func activeDiffSummary(
        originalItems: [ReplyDebtItem],
        finalItems: [ReplyDebtItem],
        judgments: [String: Judgment]
    ) -> String {
        let originalByChat = Dictionary(uniqueKeysWithValues: originalItems.map { ($0.chatUsername, $0) })
        let finalChats = Set(finalItems.map(\.chatUsername))
        var diffs: [String] = []

        for item in originalItems {
            guard let judgment = judgments[item.chatUsername] else { continue }
            if !judgment.needsReply, !finalChats.contains(item.chatUsername) {
                diffs.append("suppress \(item.chatName)")
                continue
            }
            guard let final = finalItems.first(where: { $0.chatUsername == item.chatUsername }) else { continue }
            if final.priority != item.priority {
                diffs.append("\(item.chatName) \(item.priority.rawValue)->\(final.priority.rawValue)")
            }
        }

        for item in finalItems where originalByChat[item.chatUsername] == nil {
            diffs.append("new \(item.chatName)")
        }

        return diffs.isEmpty ? "active keep" : diffs.prefix(5).joined(separator: " | ")
    }

    private func applyActiveJudgments(
        items: [ReplyDebtItem],
        judgments: [String: Judgment]
    ) -> [ReplyDebtItem] {
        let adjustedItems = items.compactMap { item -> ReplyDebtItem? in
            guard let judgment = judgments[item.chatUsername] else { return item }

            if !judgment.needsReply {
                if judgment.confidence == .high {
                    logger("[ReplyDebtAI] suppressing \(item.chatName): \(judgment.aiReason)")
                    return nil
                }
                return item
            }

            let adjustedPriority = adjustedPriority(
                original: item.priority,
                override: judgment.priorityOverride
            )
            return item.with(priority: adjustedPriority)
        }

        return adjustedItems.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func adjustedPriority(
        original: ReplyDebtPriority,
        override: PriorityOverride
    ) -> ReplyDebtPriority {
        guard let target = override.priority else { return original }
        let delta = target.rank - original.rank
        if delta == 0 { return original }
        if abs(delta) <= 1 { return target }
        return delta > 0 ? nextLowerPriority(after: original) : nextHigherPriority(before: original)
    }

    private func nextHigherPriority(before priority: ReplyDebtPriority) -> ReplyDebtPriority {
        switch priority {
        case .p0: return .p0
        case .p1: return .p0
        case .p2: return .p1
        }
    }

    private func nextLowerPriority(after priority: ReplyDebtPriority) -> ReplyDebtPriority {
        switch priority {
        case .p0: return .p1
        case .p1: return .p2
        case .p2: return .p2
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                throw ReplyDebtJudgeError.timeout
            }

            guard let result = try await group.next() else {
                throw ReplyDebtJudgeError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func status(for error: Error) -> AIAuditStatus {
        switch error {
        case ReplyDebtJudgeError.timeout:
            return .timeout
        case AIError.requestFailed:
            return .httpError
        case AIError.parseFailed:
            return .parseError
        default:
            return .httpError
        }
    }

    private func writeAudit(
        store: HUDStore?,
        model: String,
        promptVersion: String,
        inputText: String,
        outputText: String,
        latencyMs: Int,
        status: AIAuditStatus,
        errorMessage: String?
    ) {
        guard let store else { return }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .ranker,
            model: model,
            promptVersion: promptVersion,
            inputText: inputText,
            outputText: outputText,
            latencyMs: latencyMs,
            status: status,
            errorMessage: errorMessage
        )
        do {
            try store.writeAIAudit(entry)
        } catch {
            logger("[ReplyDebtAI] audit write failed: \(error)")
        }
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static let systemPrompt = """
    你在做微信待回判断。只能使用用户给出的事实，不能补造上下文。
    目标是判断“这个聊天现在是否真的需要我回复”，以及是否需要上调/下调一个优先级档位。
    只返回 JSON，不要解释，不要 Markdown。
    输出格式必须是:
    {"judgments":[{"chat_username":"...","needs_reply":true,"priority_override":"keep|p0|p1|p2","confidence":"high|medium|low","ai_reason":"不超过60字"}]}
    """
}

enum ReplyDebtJudgeError: Error {
    case invalidPayloadEncoding
    case invalidResponseShape
    case timeout
}

private extension ReplyDebtItem {
    func with(priority: ReplyDebtPriority) -> ReplyDebtItem {
        ReplyDebtItem(
            id: id,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: preview,
            latestOutboundPreview: latestOutboundPreview,
            timestamp: timestamp,
            priority: priority,
            score: score,
            unreadCount: unreadCount,
            isGroup: isGroup,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            isAtMention: isAtMention,
            inboundCountSinceLastOutbound: inboundCountSinceLastOutbound,
            reasons: reasons,
            suggestedReplyMinutes: suggestedReplyMinutes
        )
    }
}
