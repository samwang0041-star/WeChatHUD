import Foundation

/// Extract bidirectional work items, decisions, information points,
/// and open questions from a conversation window. The CommitmentTracker
/// sibling only looks at *your outgoing* messages to catch promises you
/// made — this actor looks at *both sides* so the user doesn't lose
/// things they discussed.
///
/// Primary user-facing output: the "工作台" tab (discussion items list)
/// and the weekly report that slices items by relationship hierarchy
/// (上级派给我 / 我派给下级).
actor DiscussionTracker {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let promptVersion = "discussion_v3"
    private var extractingChats: Set<String> = []
    private let retryBaseDelay: TimeInterval
    private let maxBatchesPerRun = 3
    private var retryAfterByChat: [String: TimeInterval] = [:]

    struct SourceCursor: Codable, Equatable {
        let timestamp: Int
        let localID: Int
        let messageID: String

        init(_ message: MessageInfo) {
            timestamp = message.createTime
            localID = message.localId
            messageID = message.id
        }

        func precedes(_ other: SourceCursor) -> Bool {
            if timestamp != other.timestamp { return timestamp < other.timestamp }
            if localID != other.localID { return localID < other.localID }
            return messageID < other.messageID
        }
    }

    static func cursorKey(_ chatUsername: String) -> String {
        "discussion_processed_cursor_v1:\(chatUsername)"
    }

    init(store: HUDStore, aiService: any AIServiceProtocol, promptLoader: PromptLoader = PromptLoader(), retryBaseDelay: TimeInterval = 30) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.retryBaseDelay = max(0, retryBaseDelay)
    }

    struct ExtractedItem {
        let kind: DiscussionItemKind
        let owner: DiscussionItemOwner
        let content: String
        let detail: String?
        let dueAt: Date?
        let confidence: Double
        /// The message that produced this item — used for the "消息原文"
        /// jump and per-item dedupe, instead of anchoring everything to
        /// the newest line in the batch.
        let anchorMsgUID: String
        let sourceTimestamp: Int
    }

    /// Run extraction for one chat over the given messages (chronological
    /// or reverse — we normalize). Persists new items via the store.
    /// Returns the number of freshly-inserted items.
    @discardableResult
    func extract(
        chatUsername: String,
        chatName: String,
        messages: [MessageInfo],
        myUsername: String,
        myDisplayName: String,
        mySelfNames: Set<String>
    ) async -> Int {
        guard store.getWhitelistEntry(username: chatUsername) != nil else {
            try? store.clearDiscussionMessages(chatUsername: chatUsername)
            return 0
        }
        // Persist before the first await. Overlapping scans append to the
        // same durable queue while the active caller is awaiting a model.
        do { try store.enqueueDiscussionMessages(messages) }
        catch { return 0 }
        return await drainChat(chatUsername: chatUsername, chatName: chatName,
                               myUsername: myUsername, myDisplayName: myDisplayName,
                               mySelfNames: mySelfNames, enforceScope: true)
    }

    /// Called even with no new source messages. Scope is checked both before
    /// sending and again after the provider returns; revoked chats are purged.
    func resetRetryBackoff() { retryAfterByChat.removeAll() }

    @discardableResult
    func resumePending(myUsername: String, myDisplayName: String, mySelfNames: Set<String>) async -> Int {
        guard let chats = try? store.discussionQueueChats() else { return 0 }
        var inserted = 0
        var serviced = 0
        for chat in chats {
            guard !Task.isCancelled else { break }
            guard (retryAfterByChat[chat] ?? 0) <= Date().timeIntervalSince1970 else { continue }
            guard let entry = store.getWhitelistEntry(username: chat) else {
                try? store.clearDiscussionMessages(chatUsername: chat)
                continue
            }
            guard let head = try? store.pendingDiscussionMessages(chatUsername: chat, limit: 1).first,
                  head.retryAfter <= Date().timeIntervalSince1970 else { continue }
            guard serviced < 4 else { break }
            serviced += 1
            inserted += await drainChat(chatUsername: chat, chatName: entry.displayName,
                myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames, enforceScope: true)
        }
        return inserted
    }

    private func drainChat(chatUsername: String, chatName: String, myUsername: String,
                           myDisplayName: String, mySelfNames: Set<String>, enforceScope: Bool) async -> Int {
        guard !extractingChats.contains(chatUsername),
              (retryAfterByChat[chatUsername] ?? 0) <= Date().timeIntervalSince1970 else { return 0 }
        extractingChats.insert(chatUsername)
        defer { extractingChats.remove(chatUsername) }
        var inserted = 0
        for _ in 0..<maxBatchesPerRun {
            guard !Task.isCancelled else { break }
            if enforceScope, store.getWhitelistEntry(username: chatUsername) == nil {
                try? store.clearDiscussionMessages(chatUsername: chatUsername)
                break
            }
            guard let batch = try? store.pendingDiscussionMessages(chatUsername: chatUsername), !batch.isEmpty else { break }
            guard batch.allSatisfy({ $0.retryAfter <= Date().timeIntervalSince1970 }) else { break }
            let result = await extractWindow(chatUsername: chatUsername, chatName: chatName,
                messages: batch.map(\.message), myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: mySelfNames, enforceScope: enforceScope)
            inserted += result.inserted
            if result.acknowledged {
                retryAfterByChat.removeValue(forKey: chatUsername)
                do { try store.completeDiscussionMessages(batch.map { $0.message.id }) }
                catch { break }
            } else {
                let attempts = batch.map(\.attempts).max() ?? 0
                let delay = min(1800, retryBaseDelay * pow(2, Double(min(attempts, 6))))
                let retryAfter = Date().timeIntervalSince1970 + delay
                retryAfterByChat[chatUsername] = retryAfter
                try? store.deferDiscussionMessages(batch.map { $0.message.id }, until: retryAfter)
                // A failed oldest batch is a barrier. Never advance into newer
                // source rows, and never hot-loop even if persisting backoff fails.
                break
            }
        }
        return inserted
    }

    private func extractWindow(
        chatUsername: String, chatName: String, messages: [MessageInfo],
        myUsername: String, myDisplayName: String, mySelfNames: Set<String>, enforceScope: Bool
    ) async -> (inserted: Int, acknowledged: Bool) {
        let slot = await aiService.currentConfig().provider
        guard !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              slot.providerID == "openai-codex" || !slot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (0, false) }

        let ordered = messages.sorted { SourceCursor($0).precedes(SourceCursor($1)) }
        let cursor = store.getSettingJSON(Self.cursorKey(chatUsername), as: SourceCursor.self)
        let unfiltered = ordered.filter { message in
            cursor.map { $0.precedes(SourceCursor(message)) } ?? true
        }
        let admissionRules = AdmissionRules.load(store: store)
        let isGroup = chatUsername.contains("@chatroom")
        let fresh = unfiltered.filter { msg in
            if MessageHelpers.isFromSelf(
                msg, chatUsername: chatUsername,
                myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: mySelfNames
            ) {
                // Self messages carry the other half of ownership: "我派给
                // 对方" items can only be extracted (and only attributed to
                // 等对方) if the model can see them. The chat is already
                // inside the followed scope, so admit them unconditionally.
                return true
            }
            return admissionRules.decide(
                chatUsername: chatUsername,
                isGroup: isGroup,
                senderUsername: msg.senderUsername,
                senderName: msg.senderName,
                isAtMention: MessageHelpers.isAtMe(
                    msg.text, myUsername: myUsername,
                    myDisplayName: myDisplayName, mySelfNames: mySelfNames
                )
            ).isAdmitted
        }
        guard let newest = fresh.last else { return (0, true) }
        let watermark = cursor?.timestamp ?? 0

        // Load existing items so the AI can dedupe against known
        // content (prompt-level dedupe in addition to the SQL UNIQUE).
        let existing = store.loadDiscussionItems(
            chatUsername: chatUsername,
            status: nil,
            sinceTimestamp: max(0, watermark - 7 * 86400), // last week
            limit: 20
        )

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] DiscussionTracker: prompt load failed: \(error)")
            return (0, false)
        }

        // Build a compact conversation transcript for the prompt. Each
        // line carries a sequence number, a speaker tag ("我" or the
        // actual sender) and a timestamp — the model echoes `msg` back
        // per item so ownership and the "原文" anchor land on the line
        // that actually produced the item, not the batch's newest one.
        let lines = fresh.enumerated().map { idx, msg -> String in
            let isSelf = MessageHelpers.isFromSelf(
                msg, chatUsername: chatUsername,
                myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: mySelfNames
            )
            let speaker = isSelf ? "我" : (msg.senderName.isEmpty ? "对方" : msg.senderName)
            let ts = MessageInfo.formatRelative(msg.createTime)
            return "[\(idx + 1)] [\(ts)] \(speaker): \(AIService.sanitizeForAI(msg.text))"
        }.joined(separator: "\n")

        let knownList = existing.map { "- \($0.kind.label): \($0.content)" }.joined(separator: "\n")
        let correctionHint = DiscussionCorrection.hint(
            entries: store.loadAIFeedback(limit: 100, msgUIDPrefix: "discussion_item:"),
            chatUsername: chatUsername
        )
        let prompt = template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{messages}", with: lines)
            .replacingOccurrences(of: "{known_items}", with: knownList.isEmpty ? "（暂无）" : knownList)
            .replacingOccurrences(of: "{recent_corrections}", with: correctionHint)

        let started = Date()
        let response = await callModel(prompt: prompt)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let model: String
        if let actualModel = response.model {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        var auditModel = model
        guard let body = response.text else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: model, promptVersion: promptVersion,
                inputText: "chat=\(chatName), msgs=\(messages.count)",
                outputText: "", latencyMs: latency,
                status: .httpError, errorMessage: response.error ?? "no response"
            ))
            return (0, false)
        }

        var items = parseItems(body, messages: fresh)
        var outputBody = body
        // One strict-retry, same pattern as CommitmentTracker / Classifier
        if items == nil {
            let strictPrompt = prompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要 markdown 代码块，不要任何解释性文字。"
            let retry = await callModel(prompt: strictPrompt)
            if let retryModel = retry.model {
                auditModel = retryModel
            }
            if let retryBody = retry.text {
                outputBody = retryBody
                items = parseItems(retryBody, messages: fresh)
            }
        }
        guard let parsed = items else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: auditModel, promptVersion: promptVersion,
                inputText: "chat=\(chatName)", outputText: outputBody,
                latencyMs: latency, status: .parseError,
                errorMessage: "JSON parse failed after strict retry"
            ))
            return (0, false)
        }

        // A user may revoke this conversation while the network call is in
        // flight. Do not insert results after that scope change.
        guard !Task.isCancelled else { return (0, false) }
        if enforceScope, store.getWhitelistEntry(username: chatUsername) == nil {
            try? store.clearDiscussionMessages(chatUsername: chatUsername)
            return (0, false)
        }

        // Persist. Each item is keyed by (chat, anchor_msg_uid, content)
        // so re-runs don't produce duplicates; the UNIQUE constraint
        // short-circuits silently in that case. The anchor is the item's
        // own source message (echoed back as `msg`), falling back to the
        // batch's newest line when the model omits it.
        var inserted = 0
        for item in parsed {
            let did: Bool
            do {
                did = try store.insertDiscussionItem(
                    chatUsername: chatUsername,
                    chatName: chatName,
                    kind: item.kind,
                    owner: item.owner,
                    content: item.content,
                    detail: item.detail,
                    anchorMsgUID: item.anchorMsgUID,
                    sourceTimestamp: item.sourceTimestamp,
                    dueAt: item.dueAt,
                    confidence: item.confidence,
                    promptVersion: promptVersion
                )
            } catch {
                // Keep the checkpoint unchanged so a later scan can retry persistence.
                return (inserted, false)
            }
            if did { inserted += 1 }
        }
        // A successful empty result is processed too. Item timestamps are not checkpoints.
        do {
            try store.setSettingJSON(Self.cursorKey(chatUsername), value: SourceCursor(newest))
        } catch {
            return (inserted, false)
        }

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .commitmentTracker,
            model: auditModel, promptVersion: promptVersion,
            inputText: "chat=\(chatName), msgs=\(fresh.count)",
            outputText: "inserted=\(inserted)",
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        return (inserted, true)
    }

    // MARK: - Parsing

    private func parseItems(_ raw: String, messages: [MessageInfo]) -> [ExtractedItem]? {
        let cleaned = Self.cleanJSON(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let arr = root["items"] as? [[String: Any]] else {
            return nil
        }
        let fallback = messages.last
        var out: [ExtractedItem] = []
        var dropped = 0
        for row in arr {
            guard let kindStr = row["kind"] as? String,
                  let kind = DiscussionItemKind(rawValue: kindStr),
                  let content = row["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  // v3 emits `executor` (who acts) + `msg` (source line
                  // number); `owner` from older outputs is a fallback. One
                  // malformed row must not sink the whole batch — drop it
                  // and keep the rest; only an all-garbage payload fails.
                  // info/timePlace carry no responsibility — a missing
                  // owner field defaults to shared instead of dropping.
                  let owner = Self.owner(for: row) ?? (kind == .info || kind == .timePlace ? .shared : nil)
                  else { dropped += 1; continue }

            let msgIndex = Self.sourceIndex(row["msg"], count: messages.count)
            let source = msgIndex.map { messages[$0] } ?? fallback
            let sourceDate = Date(timeIntervalSince1970: Double(source?.createTime ?? 0))
            let detail = row["detail"] as? String
            let deadline = (row["due"] as? String).flatMap { MessageHelpers.resolveDeadline($0, relativeTo: sourceDate) }
            let confidence = (row["confidence"] as? Double) ?? 0.6
            out.append(ExtractedItem(
                kind: kind, owner: owner,
                content: content, detail: detail?.isEmpty == true ? nil : detail,
                dueAt: deadline, confidence: confidence,
                anchorMsgUID: source?.id ?? "",
                sourceTimestamp: source?.createTime ?? 0
            ))
        }
        return out.isEmpty && dropped > 0 ? nil : out
    }

    /// Models emit `msg` as an Int, a Double (`"msg": 3.0`) or a string —
    /// accept all three, then bounds-check against the transcript length.
    private static func sourceIndex(_ value: Any?, count: Int) -> Int? {
        let raw: Int?
        switch value {
        case let i as Int: raw = i
        case let d as Double: raw = d.rounded() == d ? Int(d) : nil
        case let s as String: raw = Int(s.trimmingCharacters(in: .whitespaces))
        default: raw = nil
        }
        guard let raw, raw >= 1, raw <= count else { return nil }
        return raw - 1
    }

    /// `executor` (who performs the action) is authoritative in v3 —
    /// "我指派对方" reads `peer` and lands in 等对方 instead of 我要做.
    /// `owner` survives as a fallback for models that ignore the new field.
    private static func owner(for row: [String: Any]) -> DiscussionItemOwner? {
        if let executor = row["executor"] as? String {
            switch executor {
            case "me": return .mine
            case "peer": return .theirs
            case "both", "unknown": return .shared
            default: break
            }
        }
        return (row["owner"] as? String).flatMap { DiscussionItemOwner(rawValue: $0) }
    }

    private static func cleanJSON(_ text: String) -> String {
        AIJSONExtractor.firstObjectString(from: text)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AI call

    private struct ModelResponse {
        let text: String?
        let error: String?
        let model: String?
    }

    private func callModel(prompt: String) async -> ModelResponse {
        let trackID = "discussion:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "事项提取")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是对话事项提取助手。只输出 JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 45, temperature: 0.1, maxTokens: 800, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: nil, error: error.localizedDescription, model: nil)
        }
    }
}
