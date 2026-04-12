import Foundation
import AppKit
import UserNotifications

/// Central orchestrator for the autopilot auto-reply system.
///
/// Responsibilities:
/// - Decides whether to handle an incoming message
/// - Routes VIP contacts to "busy" notification + pushes macOS alert
/// - Builds context + style profile for non-VIP private chats
/// - Calls AutoReplyGenerator for AI decision
/// - Queues sends through a serial pipeline (never concurrent UI automation)
/// - Batches rapid messages from the same chat into one reply
/// - Verifies each send by checking for new outgoing message in DB
/// - Logs every action to the autopilot_log table
/// - Pauses automatically when user is actively using WeChat
///
/// Runs as an actor so AI calls don't block the main thread.
/// ChatMonitor triggers `handleNewMessages` after each scan.
actor AutopilotService {
    private let store: HUDStore
    private let reader: WeChatReader
    private let generator: AutoReplyGenerator
    private let styleProfiler: StyleProfiler

    /// Messages already processed (by msgUID), avoids double-handling.
    private var processedMsgUIDs: Set<String> = []

    /// Per-chat rate limit tracker: chatUsername → [sentTimestamps].
    private var sendTimestamps: [String: [Date]] = [:]
    /// Global send timestamps for overall rate limiting.
    private var globalSendTimestamps: [Date] = []

    /// VIP contacts already notified this session — no duplicate "busy" messages.
    private var vipNotifiedThisSession: Set<String> = []

    /// Pending messages awaiting batch window expiry. chatUsername → [messages].
    private var batchBuffer: [String: [InboundMessage]] = [:]
    /// Batch timer fires: chatUsername → scheduled fire time.
    private var batchTimers: [String: Date] = [:]
    /// How long to wait for more messages before processing a batch.
    /// Read from config at runtime; fallback to 10s.
    private var batchWindowSeconds: TimeInterval = 10

    /// Active session ID (nil if autopilot is off).
    private var sessionId: Int64?

    /// Running counters for the active session.
    private var sessionHandled = 0
    private var sessionPending = 0
    private var sessionSent = 0

    /// Paused because user is actively using WeChat.
    private var pausedForUserActivity = false

    /// True while a send is in progress — prevents concurrent UI automation.
    private var isSending = false

    /// All msgUIDs of messages sent by autopilot — used for style isolation.
    private var sentMsgUIDs: Set<String> = []

    init(store: HUDStore, reader: WeChatReader, config: AIClassifierConfig) {
        self.store = store
        self.reader = reader
        self.generator = AutoReplyGenerator(store: store, config: config)
        self.styleProfiler = StyleProfiler(reader: reader, store: store)
    }

    // MARK: - Public interface

    struct HandleResult {
        let totalProcessed: Int
        let totalSent: Int
        let totalPending: Int
        let totalSkipped: Int
        let logEntries: [AutopilotLogEntry]
    }

    /// Whether autopilot has an active session.
    var isActive: Bool { sessionId != nil }

    /// Whether autopilot is paused due to user activity.
    var isPaused: Bool { pausedForUserActivity }

    /// True if there are buffered batches waiting to be flushed.
    /// ChatMonitor uses this to schedule a follow-up scan.
    var hasPendingBatches: Bool { !batchBuffer.isEmpty }

    /// Start autopilot mode. Creates a new session in the DB.
    func start() throws {
        guard sessionId == nil else { return }
        let id = try store.startAutopilotSession()
        sessionId = id
        sessionHandled = 0
        sessionPending = 0
        sessionSent = 0
        processedMsgUIDs.removeAll()
        vipNotifiedThisSession.removeAll()
        batchBuffer.removeAll()
        batchTimers.removeAll()
        sentMsgUIDs.removeAll()
        pausedForUserActivity = false
        print("[WCHUD] Autopilot started — session #\(id)")
    }

    /// Stop autopilot mode. Ends the current session.
    func stop() throws {
        guard let id = sessionId else { return }
        // Flush any remaining batches as skipped
        batchBuffer.removeAll()
        batchTimers.removeAll()
        try store.endAutopilotSession(id: id)
        try store.updateAutopilotSessionCounts(
            id: id, handled: sessionHandled, pending: sessionPending, sent: sessionSent
        )
        print("[WCHUD] Autopilot stopped — session #\(id): handled=\(sessionHandled), sent=\(sessionSent), pending=\(sessionPending)")
        sessionId = nil
    }

    /// Called by ChatMonitor when WeChat becomes the frontmost app.
    func onUserBecameActive() {
        guard !pausedForUserActivity else { return }
        pausedForUserActivity = true
        print("[WCHUD] Autopilot: PAUSED — user is using WeChat")
    }

    /// Called by ChatMonitor when WeChat leaves the foreground.
    func onUserBecameInactive() {
        guard pausedForUserActivity else { return }
        pausedForUserActivity = false
        print("[WCHUD] Autopilot: RESUMED — user left WeChat")
    }

    /// Process a batch of new messages detected by ChatMonitor.
    func handleNewMessages(
        _ messages: [InboundMessage],
        config: AutopilotConfig,
        myUsername: String
    ) async -> HandleResult {
        guard let sid = sessionId else {
            return HandleResult(totalProcessed: 0, totalSent: 0, totalPending: 0, totalSkipped: 0, logEntries: [])
        }

        // Apply config-driven batch window
        batchWindowSeconds = TimeInterval(config.batchWindowSeconds)

        // M4 fix: prune processedMsgUIDs to prevent unbounded growth
        if processedMsgUIDs.count > 5000 {
            let toRemove = processedMsgUIDs.count - 2500
            processedMsgUIDs = Set(processedMsgUIDs.dropFirst(toRemove))
        }

        // Excluded contacts set for fast lookup
        let excludedSet = Set(config.excludedContacts)

        // If user is actively using WeChat, log but don't send
        if pausedForUserActivity {
            var entries: [AutopilotLogEntry] = []
            for msg in messages {
                guard !processedMsgUIDs.contains(msg.msgUID) else { continue }
                processedMsgUIDs.insert(msg.msgUID)
                let entry = makeLogEntry(
                    sessionId: sid, msg: msg, action: .skipped,
                    reply: nil, confidence: 0, risk: .low,
                    reasoning: "用户正在使用微信，暂停托管"
                )
                do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                entries.append(entry)
            }
            sessionHandled += entries.count
            return HandleResult(totalProcessed: entries.count, totalSent: 0, totalPending: 0, totalSkipped: entries.count, logEntries: entries)
        }

        // Phase 1: Buffer messages for batching
        var immediateEntries: [AutopilotLogEntry] = []
        var chatsToBatch: Set<String> = []

        for msg in messages {
            guard !processedMsgUIDs.contains(msg.msgUID) else { continue }
            processedMsgUIDs.insert(msg.msgUID)

            // Excluded contacts — skip silently
            if excludedSet.contains(msg.chatUsername) || excludedSet.contains(msg.senderUsername) {
                let entry = makeLogEntry(
                    sessionId: sid, msg: msg, action: .skipped,
                    reply: nil, confidence: 0, risk: .low, reasoning: "排除联系人，跳过"
                )
                do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                immediateEntries.append(entry)
                continue
            }

            // Group messages and non-text messages are handled immediately (no batching needed)
            if msg.isGroup {
                let entry = makeLogEntry(
                    sessionId: sid, msg: msg, action: .groupLogged,
                    reply: nil, confidence: 0, risk: .low, reasoning: "群消息仅记录"
                )
                do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                immediateEntries.append(entry)
                continue
            }

            if isMediaMessage(msg.text) {
                let entry = makeLogEntry(
                    sessionId: sid, msg: msg, action: .skipped,
                    reply: nil, confidence: 0, risk: .low, reasoning: "非文本消息，跳过"
                )
                do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                immediateEntries.append(entry)
                continue
            }

            // Buffer this message for batching
            batchBuffer[msg.chatUsername, default: []].append(msg)
            if batchTimers[msg.chatUsername] == nil {
                // First message from this chat — set batch timer
                batchTimers[msg.chatUsername] = Date().addingTimeInterval(batchWindowSeconds)
            }
            chatsToBatch.insert(msg.chatUsername)
        }

        // Phase 2: Process ALL batches whose window has expired (both new and old).
        var batchEntries: [AutopilotLogEntry] = []
        let now = Date()
        var sent = 0, pending = 0, skipped = immediateEntries.count

        let allExpired = batchTimers.filter { now >= $0.value }.map(\.key)
        for chatUsername in allExpired {
            guard let batch = batchBuffer.removeValue(forKey: chatUsername) else { continue }
            batchTimers.removeValue(forKey: chatUsername)

            let entry = await processBatch(batch, sessionId: sid, config: config, myUsername: myUsername)
            do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
            batchEntries.append(entry)

            switch entry.action {
            case .sent, .vipNotified: sent += 1
            case .pending: pending += 1
            case .skipped, .groupLogged, .failed: skipped += 1
            }
        }

        let allEntries = immediateEntries + batchEntries
        sessionHandled += allEntries.count
        sessionSent += sent
        sessionPending += pending

        if let sid = sessionId {
            try? store.updateAutopilotSessionCounts(
                id: sid, handled: sessionHandled, pending: sessionPending, sent: sessionSent
            )
        }

        return HandleResult(
            totalProcessed: allEntries.count,
            totalSent: sent,
            totalPending: pending,
            totalSkipped: skipped,
            logEntries: allEntries
        )
    }

    /// Approve a pending item and send it (through the serial send queue).
    func approvePending(logId: Int64, reply: String, chatName: String, chatUsername: String) async -> Bool {
        let success = await serialSend(chatName: chatName, chatUsername: chatUsername, text: reply)
        if success {
            try? store.markAutopilotLogSent(id: logId)
            // I3 fix: update actor's internal counters to stay in sync
            sessionSent += 1
            sessionPending = max(0, sessionPending - 1)
            if let sid = sessionId {
                try? store.updateAutopilotSessionCounts(
                    id: sid, handled: sessionHandled, pending: sessionPending, sent: sessionSent
                )
            }
        }
        return success
    }

    /// Reject a pending item (mark as skipped).
    func rejectPending(logId: Int64) {
        try? store.updateAutopilotLogAction(id: logId, action: .skipped)
    }

    func updateConfig(_ config: AIClassifierConfig) async {
        await generator.updateConfig(config)
    }

    /// Set of all msgUIDs sent by autopilot — for style isolation.
    func autopilotSentMsgUIDs() -> Set<String> {
        sentMsgUIDs
    }

    // MARK: - Message descriptor

    /// Lightweight inbound message descriptor passed from ChatMonitor.
    struct InboundMessage {
        let msgUID: String
        let chatUsername: String
        let chatName: String
        let senderUsername: String
        let senderName: String
        let text: String
        let isGroup: Bool
        let isAtMention: Bool
        let attentionLevel: AttentionLevel
        let contactRole: ContactRole
        let timestamp: Int
    }

    // MARK: - Batch processing

    /// Process a batch of messages from the same chat as a single reply.
    private func processBatch(
        _ batch: [InboundMessage],
        sessionId: Int64,
        config: AutopilotConfig,
        myUsername: String
    ) async -> AutopilotLogEntry {
        guard let latest = batch.last else {
            // Empty batch — should not happen, but don't crash (C3 fix)
            let placeholder = InboundMessage(
                msgUID: "empty", chatUsername: "", chatName: "",
                senderUsername: "", senderName: "",
                text: "", isGroup: false, isAtMention: false,
                attentionLevel: .stranger, contactRole: .acquaintance, timestamp: 0
            )
            return makeLogEntry(
                sessionId: sessionId, msg: placeholder, action: .skipped,
                reply: nil, confidence: 0, risk: .low, reasoning: "空批次"
            )
        }

        // Use the latest message as the "representative" for logging
        let representative = latest

        // --- VIP contacts: send busy notification (once per session per contact) ---
        if representative.attentionLevel == .vip && config.vipAutoNotify {
            if vipNotifiedThisSession.contains(representative.chatUsername) {
                return makeLogEntry(
                    sessionId: sessionId, msg: representative, action: .skipped,
                    reply: nil, confidence: 1.0, risk: .low,
                    reasoning: "VIP已通知过，不重复发送"
                )
            }

            let busyText = config.vipBusyTemplate
            let success = await serialSendWithRateLimit(
                chatName: representative.chatName, chatUsername: representative.chatUsername,
                text: busyText, config: config
            )
            if success {
                vipNotifiedThisSession.insert(representative.chatUsername)
                // Push macOS notification to the user
                pushVIPNotification(senderName: representative.senderName, preview: representative.text)
            }
            return makeLogEntry(
                sessionId: sessionId, msg: representative,
                action: success ? .vipNotified : .failed,
                reply: busyText, confidence: 1.0, risk: .low,
                reasoning: "VIP联系人，发送忙碌通知"
            )
        }

        // --- Combine batch texts for context ---
        let combinedText: String
        if batch.count == 1 {
            combinedText = batch[0].text
        } else {
            combinedText = batch.map { $0.text }.joined(separator: "\n")
        }

        // --- Build context window ---
        let allMessages: [MessageInfo]
        do {
            allMessages = try reader.getMessages(chatUsername: representative.chatUsername, limit: 60)
        } catch {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .failed,
                reply: nil, confidence: 0, risk: .low, reasoning: "读取消息历史失败"
            )
        }

        let targetMsg = allMessages.first { $0.id == latest.msgUID }
            ?? allMessages.first { $0.text == latest.text && $0.senderUsername == latest.senderUsername }

        let contextText: String
        if let target = targetMsg {
            let contactLookup: ContextWindowBuilder.ContactLookup = { [store] username in
                guard let contact = store.getContact(username: username) else { return nil }
                return (contact.attentionLevel, contact.role)
            }
            let chatType: ChatType = representative.isGroup ? .group : .privateChat
            let window = ContextWindowBuilder.build(
                target: target, role: .autopilot, allMessages: allMessages,
                chatType: chatType, contactLookup: contactLookup
            )
            contextText = window.serialize()
        } else {
            contextText = allMessages.prefix(10).map {
                "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \($0.text)"
            }.joined(separator: "\n")
        }

        // --- Get style profile (with autopilot message isolation) ---
        let style = await styleProfiler.getProfile(
            chatUsername: representative.chatUsername,
            excludeMsgUIDs: sentMsgUIDs
        )

        // --- Generate AI reply ---
        let input = AutoReplyGenerator.Input(
            messageBody: combinedText,
            senderName: representative.senderName,
            chatName: representative.chatName,
            chatUsername: representative.chatUsername,
            contactRole: representative.contactRole,
            attentionLevel: representative.attentionLevel,
            contextWindow: contextText,
            styleDescription: style.toneDescription,
            fewShotExamples: style.fewShotExamples,
            frequentPhrases: style.frequentPhrases,
            replyStyleSuffix: config.replyStyle.promptFragment
        )

        guard let decision = await generator.generate(input) else {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .failed,
                reply: nil, confidence: 0, risk: .medium, reasoning: "AI生成失败"
            )
        }

        let risk = AutopilotRisk(rawValue: decision.risk) ?? .medium

        if decision.skip == true {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: nil, confidence: decision.confidence, risk: risk,
                reasoning: decision.reasoning
            )
        }

        if decision.pending == true {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .pending,
                reply: decision.reply, confidence: decision.confidence, risk: risk,
                reasoning: decision.reasoning
            )
        }

        guard let replyText = decision.reply, !replyText.isEmpty else {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: nil, confidence: decision.confidence, risk: risk,
                reasoning: "AI未生成回复内容"
            )
        }

        if decision.confidence < config.confidenceThreshold {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .pending,
                reply: replyText, confidence: decision.confidence, risk: risk,
                reasoning: "信心不足(\(String(format: "%.0f%%", decision.confidence * 100)))，待人工确认"
            )
        }

        if risk == .high {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .pending,
                reply: replyText, confidence: decision.confidence, risk: risk,
                reasoning: "高风险消息，待人工确认: \(decision.reasoning)"
            )
        }

        // --- Safety guardrail: sensitive keyword detection ---
        if !config.sensitiveKeywords.isEmpty {
            let lower = replyText.lowercased()
            if let keyword = config.sensitiveKeywords.first(where: { lower.contains($0.lowercased()) }) {
                return makeLogEntry(
                    sessionId: sessionId, msg: representative, action: .pending,
                    reply: replyText, confidence: decision.confidence, risk: .high,
                    reasoning: "回复包含敏感词「\(keyword)」，需人工确认"
                )
            }
        }

        // --- Safety guardrail: session send limit ---
        if config.maxSendsPerSession > 0 && sessionSent >= config.maxSendsPerSession {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .pending,
                reply: replyText, confidence: decision.confidence, risk: .medium,
                reasoning: "本次会话已发送 \(sessionSent) 条（上限 \(config.maxSendsPerSession)），需人工确认"
            )
        }

        // --- Send through serial queue with verification ---
        let success = await serialSendWithRateLimit(
            chatName: representative.chatName, chatUsername: representative.chatUsername,
            text: replyText, config: config
        )

        // sentMsgUIDs is now tracked inside serialSend via verifySend

        return makeLogEntry(
            sessionId: sessionId, msg: representative,
            action: success ? .sent : .failed,
            reply: replyText, confidence: decision.confidence, risk: risk,
            reasoning: decision.reasoning
        )
    }

    // MARK: - Serial send queue

    /// Serialize all sends through a single point. Only one send at a time.
    /// Includes clipboard save/restore, frontmost check, and post-send verification.
    private func serialSend(chatName: String, chatUsername: String, text: String) async -> Bool {
        // M5 fix: block concurrent sends through actor suspension points
        guard !isSending else {
            print("[WCHUD] Autopilot: send already in progress, dropped for '\(chatName)' — will retry on next scan")
            return false
        }
        isSending = true
        defer { isSending = false }

        // Save clipboard
        let savedClipboard = ClipboardGuard.save()
        defer { ClipboardGuard.restore(savedClipboard) }

        // Send (blocks until complete — 2s+ per message)
        let uiSuccess = await WeChatLauncher.sendMessage(chatName: chatName, text: text)
        guard uiSuccess else {
            print("[WCHUD] Autopilot: UI send failed for '\(chatName)'")
            return false
        }

        // Verify by checking DB for new outgoing message (I5 fix: use chatUsername)
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms for DB to flush
        let (verified, outgoingMsgUID) = verifySend(chatUsername: chatUsername)
        if !verified {
            print("[WCHUD] Autopilot: send verification FAILED for '\(chatName)' — message may not have been sent")
        }
        // I6 fix: track the actual outgoing message UID, not the trigger UID
        if let uid = outgoingMsgUID {
            sentMsgUIDs.insert(uid)
        }
        return verified
    }

    private func serialSendWithRateLimit(
        chatName: String, chatUsername: String,
        text: String, config: AutopilotConfig
    ) async -> Bool {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        // C2 fix: global rate limit check
        globalSendTimestamps = globalSendTimestamps.filter { $0 > oneHourAgo }
        if globalSendTimestamps.count >= config.maxRepliesPerHour {
            print("[WCHUD] Autopilot: GLOBAL rate limit hit (\(globalSendTimestamps.count)/h)")
            return false
        }

        // Per-chat cleanup
        sendTimestamps[chatUsername] = (sendTimestamps[chatUsername] ?? [])
            .filter { $0 > oneHourAgo }
        if sendTimestamps[chatUsername]?.isEmpty == true {
            sendTimestamps.removeValue(forKey: chatUsername)
        }

        let success = await serialSend(chatName: chatName, chatUsername: chatUsername, text: text)
        if success {
            sendTimestamps[chatUsername, default: []].append(now)
            globalSendTimestamps.append(now)
        }
        return success
    }

    // MARK: - Send verification

    /// Check if a new outgoing message appeared in the chat after sending.
    /// Returns (verified, outgoingMsgUID).
    private func verifySend(chatUsername: String) -> (Bool, String?) {
        let myUname = reader.myUsername()

        guard let msgs = try? reader.getMessages(chatUsername: chatUsername, limit: 3) else {
            return (true, nil) // fail open — can't read DB
        }

        for msg in msgs {
            // Check if message is from self
            let fromSelf = (!myUname.isEmpty && msg.senderUsername == myUname)
                || (!chatUsername.contains("@chatroom") && !msg.senderUsername.isEmpty
                    && msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername)

            if fromSelf {
                let age = Int(Date().timeIntervalSince1970) - msg.createTime
                if age < 30 {
                    return (true, msg.id)
                }
            }
        }

        return (false, nil)
    }

    // MARK: - VIP push notification

    private func pushVIPNotification(senderName: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ VIP消息: \(senderName)"
        content.body = String(preview.prefix(100))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "autopilot-vip-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[WCHUD] Autopilot: failed to push VIP notification: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func isMediaMessage(_ text: String) -> Bool {
        let prefixes = ["[图片]", "[语音]", "[视频]", "[文件]", "[动画表情]", "[贴纸]", "[位置]", "[名片]"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private func makeLogEntry(
        sessionId: Int64,
        msg: InboundMessage,
        action: AutopilotAction,
        reply: String?,
        confidence: Double,
        risk: AutopilotRisk,
        reasoning: String
    ) -> AutopilotLogEntry {
        AutopilotLogEntry(
            id: 0,
            sessionId: sessionId,
            chatUsername: msg.chatUsername,
            chatName: msg.chatName,
            senderUsername: msg.senderUsername,
            senderName: msg.senderName,
            triggerMsgUID: msg.msgUID,
            triggerText: msg.text,
            generatedReply: reply,
            confidence: confidence,
            riskLevel: risk,
            action: action,
            aiReasoning: reasoning,
            sentAt: action == .sent || action == .vipNotified ? Date() : nil,
            createdAt: Date()
        )
    }
}

// MARK: - Clipboard Guard

/// Saves and restores the system clipboard around autopilot sends.
enum ClipboardGuard {
    struct SavedState {
        let items: [NSPasteboardItem]?
        let changeCount: Int
    }

    static func save() -> SavedState {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount

        // Deep-copy pasteboard items so they survive clearContents()
        var saved: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }

        return SavedState(items: saved.isEmpty ? nil : saved, changeCount: changeCount)
    }

    static func restore(_ state: SavedState) {
        let pb = NSPasteboard.general
        // Only restore if the clipboard was changed (by our send)
        guard pb.changeCount != state.changeCount else { return }
        guard let items = state.items, !items.isEmpty else { return }

        pb.clearContents()
        pb.writeObjects(items)
    }
}
