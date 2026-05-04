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
    private let aiService: AIService

    /// Messages already processed (by msgUID), avoids double-handling.
    private var processedMsgUIDs: Set<String> = []
    /// Insertion-ordered list for FIFO eviction of processedMsgUIDs.
    private var processedMsgOrder: [String] = []

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
    /// First message arrival time per chat batch — used for max window cap.
    private var batchStartTimes: [String: Date] = [:]
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
    /// Manually paused by user via UI button.
    private(set) var manuallyPaused = false

    /// True while a send is in progress — prevents concurrent UI automation.
    private var isSending = false

    /// All msgUIDs of messages sent by autopilot — used for style isolation.
    private var sentMsgUIDs: Set<String> = []

    /// Pending send queue — visible to UI. Messages wait here before being sent.
    private(set) var pendingSendQueue: [PendingSend] = []

    /// Session statistics for UI dashboard.
    private(set) var sessionStats = SessionStats()

    struct SessionStats {
        var totalSent = 0
        var totalReadNoReply = 0
        var totalPending = 0
        var totalSkipped = 0
        var styleScoreSum = 0
        var styleScoreCount = 0
        var delaySum: Double = 0
        var delayCount = 0
        var startedAt: Date?

        var avgStyleScore: Int { styleScoreCount > 0 ? styleScoreSum / styleScoreCount : 0 }
        var avgDelay: Int { delayCount > 0 ? Int(delaySum / Double(delayCount)) : 0 }
        var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    }

    /// Callback fired on every verified outgoing send. Used by ChatMonitor
    /// to append to the session ledger. Arguments: `(chatUsername, text,
    /// peerLastMessage, topic)`. Nil until injected by the caller.
    typealias LedgerWriteCallback = @MainActor @Sendable (String, String, String?, String?) -> Void
    /// Reads the current ledger for a chat. Used by `processBatch` to
    /// feed `{session_ledger}` into the reply prompt. Nil until injected
    /// by the caller.
    typealias LedgerReadCallback = @MainActor @Sendable (String) -> [LedgerEntry]

    private let ledgerWrite: LedgerWriteCallback?
    private let ledgerRead: LedgerReadCallback?

    init(
        store: HUDStore,
        reader: WeChatReader,
        aiService: AIService,
        ledgerRead: LedgerReadCallback? = nil,
        ledgerWrite: LedgerWriteCallback? = nil
    ) {
        self.store = store
        self.reader = reader
        self.aiService = aiService
        self.generator = AutoReplyGenerator(store: store, aiService: aiService)
        self.styleProfiler = StyleProfiler(reader: reader, store: store)
        self.ledgerRead = ledgerRead
        self.ledgerWrite = ledgerWrite
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
        processedMsgOrder.removeAll()
        vipNotifiedThisSession.removeAll()
        batchBuffer.removeAll()
        batchTimers.removeAll()
        batchStartTimes.removeAll()
        sentMsgUIDs.removeAll()
        proactiveSentCount = 0
        proactiveContactsSent.removeAll()
        pendingSendQueue.removeAll()
        sessionStats = SessionStats(startedAt: Date())
        pausedForUserActivity = false
        print("[WCHUD] Autopilot started — session #\(id)")

        // Refresh memory for all whitelist contacts on session start
        // so autopilot has up-to-date context even if user was chatting manually
        Task { [store] in
            let whitelist = store.getWhitelist()
            for entry in whitelist.prefix(5) {
                // Skip if memory is fresh (< 10 min)
                if let existing = store.loadConversationMemory(chatUsername: entry.id),
                   Date().timeIntervalSince(existing.lastUpdated) < 600 {
                    continue
                }
                await self.refreshMemoryAfterSend(
                    chatUsername: entry.id,
                    chatName: entry.displayName
                )
            }
            print("[WCHUD] Autopilot: startup memory refresh complete")
        }
    }

    /// Stop autopilot mode. Ends the current session.
    func stop() throws {
        guard let id = sessionId else { return }
        // Log discarded batches for audit trail
        let discardedCount = batchBuffer.values.reduce(0) { $0 + $1.count }
        if discardedCount > 0 {
            print("[WCHUD] Autopilot: discarding \(discardedCount) buffered messages on stop")
        }
        // Log discarded pending sends
        for item in pendingSendQueue {
            let logEntry = AutopilotLogEntry(
                id: 0, sessionId: id,
                chatUsername: item.chatUsername, chatName: item.chatName,
                senderUsername: "", senderName: item.senderName,
                triggerMsgUID: "queue-\(item.id)", triggerText: "",
                generatedReply: item.replyText, confidence: item.confidence,
                riskLevel: item.risk, action: .skipped,
                aiReasoning: "托管停止时取消",
                sentAt: nil, createdAt: Date()
            )
            try? store.insertAutopilotLog(logEntry)
        }
        batchBuffer.removeAll()
        batchTimers.removeAll()
        batchStartTimes.removeAll()
        pendingSendQueue.removeAll()
        try store.endAutopilotSession(id: id)
        try store.updateAutopilotSessionCounts(
            id: id, handled: sessionHandled, pending: sessionPending, sent: sessionSent
        )
        print("[WCHUD] Autopilot stopped — session #\(id): handled=\(sessionHandled), sent=\(sessionSent), pending=\(sessionPending)")
        sessionId = nil
    }

    /// Whether autopilot is effectively paused (manual or auto).
    var isPaused: Bool { pausedForUserActivity || manuallyPaused }

    /// Manually pause autopilot (from UI button). Messages continue buffering.
    func manualPause() {
        manuallyPaused = true
        print("[WCHUD] Autopilot: MANUALLY PAUSED by user")
    }

    /// Resume from manual pause.
    func manualResume() {
        manuallyPaused = false
        print("[WCHUD] Autopilot: MANUALLY RESUMED by user")
    }

    /// Called by ChatMonitor when WeChat becomes the frontmost app.
    func onUserBecameActive() {
        guard !isPaused else { return }
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

        // M4 fix: prune processedMsgUIDs to prevent unbounded growth.
        // Keep last 2500 by maintaining insertion-order via processedMsgOrder.
        if processedMsgUIDs.count > 5000 {
            let toRemove = processedMsgOrder.count - 2500
            let evicted = processedMsgOrder.prefix(toRemove)
            for uid in evicted { processedMsgUIDs.remove(uid) }
            processedMsgOrder.removeFirst(toRemove)
        }

        // Excluded contacts set for fast lookup
        let excludedSet = Set(config.excludedContacts)

        // Phase 1: Buffer messages for batching
        var immediateEntries: [AutopilotLogEntry] = []
        var chatsToBatch: Set<String> = []

        for msg in messages {
            guard !processedMsgUIDs.contains(msg.msgUID) else { continue }
            processedMsgUIDs.insert(msg.msgUID)
            processedMsgOrder.append(msg.msgUID)

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

            // Media messages: classify by type code + text prefix
            if let mediaType = classifyMediaByType(messageType: msg.messageType, appType: msg.appType, text: msg.text) {
                if !mediaType.shouldRespond {
                    let entry = makeLogEntry(
                        sessionId: sid, msg: msg, action: .skipped,
                        reply: nil, confidence: 0, risk: .low, reasoning: "表情包/贴纸，跳过"
                    )
                    do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                    immediateEntries.append(entry)
                    continue
                }
                // Force-pending for financial/sensitive types (red packet, transfer, miniprogram)
                if mediaType.forcePending {
                    let entry = makeLogEntry(
                        sessionId: sid, msg: msg, action: .pending,
                        reply: nil, confidence: 0, risk: .high,
                        reasoning: "\(mediaType.rawValue)消息，需本人处理"
                    )
                    do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
                    immediateEntries.append(entry)
                    continue
                }
                // Respondable media — falls through to batching below
            }

            // Buffer this message for batching
            batchBuffer[msg.chatUsername, default: []].append(msg)
            if batchTimers[msg.chatUsername] == nil {
                // First message from this chat — set batch timer
                let dynamicWindow = max(batchWindowSeconds, 15)
                batchTimers[msg.chatUsername] = Date().addingTimeInterval(dynamicWindow)
                batchStartTimes[msg.chatUsername] = Date()
            } else {
                // Extend window by 10s on each new message (sender still typing)
                // Cap at 60s total from actual first message arrival
                let firstArrival = batchStartTimes[msg.chatUsername] ?? Date()
                let maxDeadline = firstArrival.addingTimeInterval(60)
                let extended = Date().addingTimeInterval(10)
                batchTimers[msg.chatUsername] = min(extended, maxDeadline)
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
            batchStartTimes.removeValue(forKey: chatUsername)

            let entry = await processBatch(batch, sessionId: sid, config: config, myUsername: myUsername)
            do { try store.insertAutopilotLog(entry) } catch { print("[WCHUD] Autopilot: log insert failed: \(error)") }
            batchEntries.append(entry)

            switch entry.action {
            case .sent, .vipNotified: sent += 1
            case .pending: pending += 1
            case .skipped, .groupLogged, .failed, .readNoReply, .proactive: skipped += 1
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
        /// WeChat message base type (1=text, 3=image, 34=voice, 43=video, 47=sticker, 49=appmsg).
        var messageType: Int = 1
        /// App message subtype (6=file, 33/36=miniprogram, 42=namecard, 2000=transfer, 2001=redpacket).
        var appType: Int = 0
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

        // --- Guard: don't act while user is actively using WeChat ---
        if isPaused {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: nil, confidence: 0, risk: .low,
                reasoning: isPaused ? "已暂停，暂不处理" : "用户正在使用微信"
            )
        }

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

        // --- Deep night silence check (configurable threshold) ---
        let currentPeriod = StyleProfiler.timePeriod(unixTime: Int(Date().timeIntervalSince1970))
        if currentPeriod == .lateNight {
            let timing = await styleProfiler.getTimingProfile(chatUsername: representative.chatUsername)
            if timing.lateNightReplyRate < config.silentNightThreshold {
                return makeLogEntry(
                    sessionId: sessionId, msg: representative, action: .skipped,
                    reply: nil, confidence: 1.0, risk: .low,
                    reasoning: "深夜静默模式（23:00-7:00），回复率\(String(format: "%.0f%%", timing.lateNightReplyRate * 100)) < 阈值\(String(format: "%.0f%%", config.silentNightThreshold * 100))"
                )
            }
        }

        // --- Combine batch texts for context + detect media ---
        let combinedText: String
        if batch.count == 1 {
            combinedText = batch[0].text
        } else {
            combinedText = batch.map { $0.text }.joined(separator: "\n")
        }

        // Detect media messages in the batch and build context hints
        let mediaContexts = batch.compactMap { msg -> String? in
            guard let mediaType = classifyMediaByType(messageType: msg.messageType, appType: msg.appType, text: msg.text) else { return nil }
            return mediaType.promptContext
        }
        let mediaContext = mediaContexts.isEmpty ? nil : mediaContexts.joined(separator: "\n")
        let hasMedia = !mediaContexts.isEmpty

        // --- Build context window ---
        let allMessages: [MessageInfo]
        do {
            allMessages = try reader.getMessages(chatUsername: representative.chatUsername, limit: 15)
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
                "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \(AIService.sanitizeForAI($0.text))"
            }.joined(separator: "\n")
        }

        // --- Get style profile (with autopilot message isolation) ---
        let style = await styleProfiler.getProfile(
            chatUsername: representative.chatUsername,
            excludeMsgUIDs: sentMsgUIDs
        )

        // --- Load conversation memory ---
        let memory = store.loadConversationMemory(chatUsername: representative.chatUsername)
        let memoryText = memory?.formatForPrompt()

        // --- Pull session ledger (entries this autopilot session has sent
        // to this chat). Hop to MainActor since ChatMonitor owns it. ---
        let ledger: [LedgerEntry]
        if let read = ledgerRead {
            ledger = await MainActor.run { read(representative.chatUsername) }
        } else {
            ledger = []
        }

        // --- Build per-contact style hint ---
        let contactHint = Self.buildContactStyleHint(style: style, contactRole: representative.contactRole)

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
            messagePairs: style.messagePairs,
            punctuationStyle: style.punctuationStyle,
            sentenceStyle: style.sentenceStyle,
            typingRhythm: style.typingRhythm.description,
            lengthP25: style.lengthP25,
            lengthP50: style.lengthP50,
            lengthP75: style.lengthP75,
            contactStyleHint: contactHint,
            mediaContext: mediaContext,
            conversationMemory: memoryText,
            sessionLedger: ledger,
            replyStyleSuffix: config.replyStyle.promptFragment
        )

        guard let decision = await generator.generate(input) else {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .failed,
                reply: nil, confidence: 0, risk: .medium, reasoning: "AI生成失败"
            )
        }

        let risk = AutopilotRisk(rawValue: decision.risk) ?? .medium
        // Media confidence decay: media replies are inherently less certain
        let effectiveConfidence = hasMedia ? decision.confidence * 0.7 : decision.confidence

        if decision.skip == true {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: nil, confidence: decision.confidence, risk: risk,
                reasoning: decision.reasoning
            )
        }

        // Read-no-reply: open chat to trigger read receipt, but don't send anything
        if decision.readNoReply == true {
            // Delay 3-10 seconds before opening (reading happens faster than typing, but not instant)
            let readDelay = Double.random(in: 3...10)
            try? await Task.sleep(nanoseconds: UInt64(readDelay * 1_000_000_000))
            // Re-check pause state after delay
            guard !isPaused, self.sessionId != nil else {
                return makeLogEntry(
                    sessionId: sessionId, msg: representative, action: .skipped,
                    reply: nil, confidence: decision.confidence, risk: risk,
                    reasoning: "已读不回延迟期间状态变更，跳过"
                )
            }
            await MainActor.run {
                WeChatLauncher.openChat(named: representative.chatName)
            }
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .readNoReply,
                reply: nil, confidence: decision.confidence, risk: risk,
                reasoning: "已读不回(\(Int(readDelay))s后): \(decision.reasoning)"
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

        if effectiveConfidence < config.confidenceThreshold {
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

        // --- Safety guardrail: style consistency check ---
        let styleScore = Self.computeStyleScore(reply: replyText, style: style)
        if styleScore < 50 {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .pending,
                reply: replyText, confidence: decision.confidence, risk: .medium,
                reasoning: "风格偏差过大(score=\(styleScore)/100)，需人工确认: \(decision.reasoning)"
            )
        }

        // --- Simulate human reply delay ---
        let timing = await styleProfiler.getTimingProfile(chatUsername: representative.chatUsername)
        let urgency = MessageUrgency.detect(from: combinedText)

        // Conversation temperature: detect "hot chat" mode
        // If 5+ messages exchanged in last 10 minutes → hot chat → very short delay
        let tenMinAgo = Int(Date().timeIntervalSince1970) - 600
        let recentCount = allMessages.filter { $0.createTime > tenMinAgo }.count
        let isHotChat = recentCount >= 5

        let baseDist = currentPeriod == .lateNight ? timing.lateNight
            : currentPeriod == .weekend ? timing.weekend
            : currentPeriod == .evening ? timing.evening
            : timing.workHours

        let rawDelay: Double
        if isHotChat {
            // Hot chat mode: 5-15 seconds, urgency still applies
            rawDelay = Double.random(in: 5...15) * urgency.delayMultiplier
        } else {
            rawDelay = baseDist.randomDelay() * urgency.delayMultiplier
        }
        // Apply global speed multiplier from config
        let scaledDelay = rawDelay * config.replySpeedMultiplier
        // Clamp: min 5s (don't look robotic), max 300s (don't leave them hanging)
        let replyDelay = max(5, min(300, scaledDelay))

        // --- Enqueue for delayed sending (visible to UI) ---
        let sendTime = Date().addingTimeInterval(replyDelay)
        let pendingItem = PendingSend(
            chatUsername: representative.chatUsername,
            chatName: representative.chatName,
            senderName: representative.senderName,
            replyText: replyText,
            confidence: decision.confidence,
            risk: risk,
            reasoning: decision.reasoning,
            styleScore: styleScore,
            scheduledSendTime: sendTime,
            peerLastMessage: combinedText,
            topic: memory?.conversationPhase
        )
        pendingSendQueue.append(pendingItem)

        // Update session stats
        sessionStats.styleScoreSum += styleScore
        sessionStats.styleScoreCount += 1
        sessionStats.delaySum += replyDelay
        sessionStats.delayCount += 1

        print("[WCHUD] Autopilot: queued reply to '\(representative.chatName)' — sends in \(Int(replyDelay))s (period=\(currentPeriod), urgency=\(urgency), hotChat=\(isHotChat), style=\(styleScore))")

        let reasoningWithScore = "\(decision.reasoning) [style:\(styleScore)/100, delay:\(Int(replyDelay))s]"

        return makeLogEntry(
            sessionId: sessionId, msg: representative,
            action: .pending, // queued, not sent yet
            reply: replyText, confidence: decision.confidence, risk: risk,
            reasoning: reasoningWithScore
        )
    }

    // MARK: - Serial send queue

    /// Serialize all sends through a single point. Only one send at a time.
    /// Includes clipboard save/restore, frontmost check, and post-send verification.
    /// On `verified == true`, fires `ledgerWrite` so ChatMonitor can append
    /// this send to the session ledger.
    private func serialSend(
        chatName: String,
        chatUsername: String,
        text: String,
        typingDelay: TimeInterval = 0,
        peerLastMessage: String? = nil,
        topic: String? = nil
    ) async -> Bool {
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

        // Send with optional typing simulation (blocks until complete — 2s+ per message)
        let uiSuccess = await WeChatLauncher.sendMessage(
            chatName: chatName,
            text: text,
            typingDelay: typingDelay,
            sendKey: (store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).sendKey
        )
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
            // Prune to prevent unbounded growth in long sessions
            if sentMsgUIDs.count > 500 {
                sentMsgUIDs = Set(sentMsgUIDs.suffix(250))
            }
        }

        // Write session ledger entry on verified send. Runs on MainActor
        // because the ledger lives on ChatMonitor.
        if verified, let write = ledgerWrite {
            await MainActor.run {
                write(chatUsername, text, peerLastMessage, topic)
            }
        }

        return verified
    }

    private func serialSendWithRateLimit(
        chatName: String, chatUsername: String,
        text: String, config: AutopilotConfig,
        typingDelay: TimeInterval = 0,
        peerLastMessage: String? = nil,
        topic: String? = nil
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

        let success = await serialSend(
            chatName: chatName,
            chatUsername: chatUsername,
            text: text,
            typingDelay: typingDelay,
            peerLastMessage: peerLastMessage,
            topic: topic
        )
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
            return (false, nil) // fail closed — can't verify, treat as failed
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

    // MARK: - Post-send memory refresh

    /// Incrementally update conversation memory after autopilot sends a reply.
    /// Runs within actor isolation — safe access to store and reader.
    /// Rate-limited: skips if memory was updated < 5 min ago.
    private func refreshMemoryAfterSend(
        chatUsername: String, chatName: String
    ) async {
        // Fix 3: single load, reused for rate-limit check and as old memory
        let oldMemory = store.loadConversationMemory(chatUsername: chatUsername)

        // Rate limit: skip if updated < 5 min ago
        if let existing = oldMemory,
           Date().timeIntervalSince(existing.lastUpdated) < 300 {
            return
        }

        let messages = (try? reader.getMessages(chatUsername: chatUsername, limit: 30)) ?? []
        guard !messages.isEmpty else { return }

        let oldSummary = oldMemory?.summary ?? ""
        let oldShared = oldMemory?.sharedContext ?? []
        let oldComm = oldMemory?.communicationNotes ?? []

        let msgText = messages.prefix(20).map {
            "\($0.senderName): \(AIService.sanitizeForAI($0.text))"
        }.joined(separator: "\n")

        let prompt = """
        你是对话摘要助手。根据最近消息增量更新对话记忆。保留旧记忆中仍然相关的内容，合并新内容。

        对话: \(chatName)
        旧摘要: \(oldSummary.isEmpty ? "（首次生成）" : oldSummary)
        旧共同背景: \(oldShared.isEmpty ? "（无）" : oldShared.joined(separator: "、"))
        旧沟通习惯: \(oldComm.isEmpty ? "（无）" : oldComm.joined(separator: "、"))

        最近消息:
        \(msgText)

        请用 JSON 格式输出（每个数组最多5项）:
        {"summary":"一句话摘要(50字内)","key_topics":["最近话题1","话题2"],"pending_items":["待办1"],"shared_context":["共同经历/关系背景"],"communication_notes":["沟通习惯"],"mood_trend":"情绪描述","conversation_phase":"闲聊/讨论/决策/争论/告别/无","stance":"用户当前立场(如有)"}
        """

        let content: String
        do {
            content = try await aiService.complete(
                system: "你是对话摘要助手。只输出JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 30, temperature: 0.2, maxTokens: 256, responseFormatJSON: true)
            )
        } catch {
            return
        }

        guard let cleaned = AIJSONExtractor.firstObjectString(from: content) else { return }

        guard let jsonData = cleaned.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        let memory = ConversationMemory(
            chatUsername: chatUsername,
            summary: result["summary"] as? String ?? oldSummary,
            keyTopics: Array((result["key_topics"] as? [String] ?? oldMemory?.keyTopics ?? []).prefix(10)),
            pendingItems: Array((result["pending_items"] as? [String] ?? oldMemory?.pendingItems ?? []).prefix(5)),
            sharedContext: Array((result["shared_context"] as? [String] ?? oldShared).prefix(5)),
            communicationNotes: Array((result["communication_notes"] as? [String] ?? oldComm).prefix(5)),
            moodTrend: result["mood_trend"] as? String ?? oldMemory?.moodTrend ?? "",
            conversationPhase: result["conversation_phase"] as? String ?? oldMemory?.conversationPhase ?? "",
            stance: result["stance"] as? String ?? oldMemory?.stance ?? "",
            messageCount7d: messages.count,
            lastUpdated: Date()
        )
        try? store.upsertConversationMemory(memory)
        print("[WCHUD] Autopilot: memory updated for '\(chatName)'")
    }

    // MARK: - Pending send queue operations

    /// Cancel a pending send by ID. Logs as skipped for audit trail.
    func cancelPendingSend(id: UUID) {
        guard let item = pendingSendQueue.first(where: { $0.id == id }) else { return }
        pendingSendQueue.removeAll { $0.id == id }
        // Fix 2: record cancellation in audit log
        let logEntry = AutopilotLogEntry(
            id: 0, sessionId: sessionId ?? 0,
            chatUsername: item.chatUsername, chatName: item.chatName,
            senderUsername: "", senderName: item.senderName,
            triggerMsgUID: "queue-\(item.id)", triggerText: "",
            generatedReply: item.replyText, confidence: item.confidence,
            riskLevel: item.risk, action: .skipped,
            aiReasoning: "用户手动取消",
            sentAt: nil, createdAt: Date()
        )
        try? store.insertAutopilotLog(logEntry)
    }

    /// Send a pending message immediately (skip remaining delay).
    func sendNow(id: UUID, config: AutopilotConfig) async {
        // Fix 3: don't remove from queue if paused — keep it safe
        guard !isPaused else {
            print("[WCHUD] Autopilot: sendNow blocked — user is active, message stays in queue")
            return
        }
        guard let idx = pendingSendQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = pendingSendQueue.remove(at: idx)
        await executeSend(item: item, config: config)
    }

    /// Edit and send a pending message.
    func editAndSend(id: UUID, newText: String, config: AutopilotConfig) async {
        // Fix 1: sensitive keyword check on edited text
        if !config.sensitiveKeywords.isEmpty {
            let lower = newText.lowercased()
            if let keyword = config.sensitiveKeywords.first(where: { lower.contains($0.lowercased()) }) {
                print("[WCHUD] Autopilot: editAndSend blocked — contains sensitive keyword '\(keyword)'")
                return  // keep in queue, UI should show warning
            }
        }
        guard !isPaused else {
            print("[WCHUD] Autopilot: editAndSend blocked — user is active")
            return
        }
        guard let idx = pendingSendQueue.firstIndex(where: { $0.id == id }) else { return }
        var item = pendingSendQueue.remove(at: idx)
        item.replyText = newText
        await executeSend(item: item, config: config)
    }

    /// Process pending queue — send items whose timer has expired.
    /// Called from ChatMonitor's 60s safety timer.
    func processPendingQueue(config: AutopilotConfig) async {
        guard !isPaused, sessionId != nil else { return }
        let now = Date()
        let expired = pendingSendQueue.filter { $0.scheduledSendTime <= now }
        for item in expired {
            pendingSendQueue.removeAll { $0.id == item.id }
            await executeSend(item: item, config: config)
        }
    }

    /// Execute a send from the queue.
    private func executeSend(item: PendingSend, config: AutopilotConfig) async {
        guard !isPaused, sessionId != nil else { return }
        let typingDelay = Self.estimateTypingDelay(for: item.replyText)
        let success = await serialSendWithRateLimit(
            chatName: item.chatName, chatUsername: item.chatUsername,
            text: item.replyText, config: config, typingDelay: typingDelay,
            peerLastMessage: item.peerLastMessage, topic: item.topic
        )
        if success {
            sessionStats.totalSent += 1
            sessionSent += 1
            // Refresh memory after send
            await refreshMemoryAfterSend(chatUsername: item.chatUsername, chatName: item.chatName)
        }
    }

    // MARK: - Proactive messaging

    /// Counter for proactive messages sent this session.
    private var proactiveSentCount = 0
    /// Fix 2: per-contact dedup — contacts already proactively contacted this session.
    private var proactiveContactsSent: Set<String> = []

    /// Evaluate whitelist contacts and proactively message those who meet criteria.
    /// Called periodically by ChatMonitor (e.g., every 10 minutes during autopilot).
    func evaluateProactiveOutreach(config: AutopilotConfig) async {
        guard config.proactiveEnabled, !isPaused, sessionId != nil else { return }
        guard proactiveSentCount < config.maxProactivePerSession else { return }

        // Don't initiate during late night
        let currentPeriod = StyleProfiler.timePeriod(unixTime: Int(Date().timeIntervalSince1970))
        guard currentPeriod != .lateNight else { return }

        let whitelist = store.getWhitelist()
        for entry in whitelist.prefix(10) {
            guard proactiveSentCount < config.maxProactivePerSession else { break }
            // Fix 2: skip contacts already proactively contacted this session
            guard !proactiveContactsSent.contains(entry.id) else { continue }

            // ContactRole filter: only friend/family for now
            let contact = store.getContact(username: entry.id)
            let role = contact?.role ?? .acquaintance
            guard role == .friend || role == .family else { continue }

            guard let memory = store.loadConversationMemory(chatUsername: entry.id) else { continue }

            // Fix 5: use actual last message time, not memory lastUpdated
            let lastMsgTime: Date
            if let msgs = try? reader.getMessages(chatUsername: entry.id, limit: 1), let last = msgs.first {
                lastMsgTime = Date(timeIntervalSince1970: Double(last.createTime))
            } else {
                lastMsgTime = memory.lastUpdated
            }

            let trigger = evaluateProactiveTrigger(memory: memory, lastMessageTime: lastMsgTime, config: config)
            guard let reason = trigger else { continue }

            // Generate opening message via AI
            let style = await styleProfiler.getProfile(chatUsername: entry.id, excludeMsgUIDs: sentMsgUIDs)
            let contactHint = Self.buildContactStyleHint(style: style, contactRole: role)

            let prompt = """
            你是微信用户的自动助手。需要主动给对方发一条消息。

            对方：\(entry.displayName)
            触发原因：\(reason)
            你和对方的记忆：\(memory.formatForPrompt() ?? "（无）")
            你和对方的聊天风格：\(contactHint.isEmpty ? "（无数据）" : contactHint)

            生成一条自然的开场消息。要求：
            1. 像真人主动找人聊天一样，不要太正式
            2. 紧扣触发原因（如问候近况、追问之前的事）
            3. 长度\(style.lengthP25)-\(style.lengthP75)字
            4. 模仿用户风格

            只输出消息文本，不要 JSON。
            """

            var content: String
            do {
                content = try await aiService.complete(
                    system: "你是微信用户的主动聊天助手。只输出消息文本。",
                    user: prompt,
                    options: CompleteOptions(timeout: 30, temperature: 0.5, maxTokens: 128)
                )
            } catch {
                continue
            }

            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip quotes if AI wrapped the message
            if content.hasPrefix("\"") && content.hasSuffix("\"") {
                content = String(content.dropFirst().dropLast())
            }
            guard !content.isEmpty, content.count <= 100 else { continue }

            // Fix 3: sensitive keyword check (proactive messages are higher risk)
            if !config.sensitiveKeywords.isEmpty {
                let lower = content.lowercased()
                if config.sensitiveKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                    continue // silently skip — don't proactively send sensitive content
                }
            }

            // Default: all proactive messages go to pending for user approval
            proactiveContactsSent.insert(entry.id)
            proactiveSentCount += 1
            let logEntry = AutopilotLogEntry(
                id: 0, sessionId: sessionId ?? 0,
                chatUsername: entry.id, chatName: entry.displayName,
                senderUsername: "", senderName: "系统",
                triggerMsgUID: "proactive", triggerText: reason,
                generatedReply: content, confidence: 0.7,
                riskLevel: .medium, action: .pending,  // Fix 4: medium risk + default pending
                aiReasoning: "主动发起(待确认): \(reason)",
                sentAt: nil, createdAt: Date()
            )
            try? store.insertAutopilotLog(logEntry)
            print("[WCHUD] Autopilot: proactive draft queued for '\(entry.displayName)': \(content)")
        }
    }

    /// Evaluate if a contact warrants proactive outreach. Returns trigger reason or nil.
    /// Fix 5: uses actual last message time instead of memory.lastUpdated.
    private func evaluateProactiveTrigger(memory: ConversationMemory, lastMessageTime: Date, config: AutopilotConfig) -> String? {
        let daysSinceLastMsg = Int(Date().timeIntervalSince(lastMessageTime) / 86400)

        // Trigger 1: Overdue pending items (> N days without follow-up)
        if !memory.pendingItems.isEmpty && daysSinceLastMsg >= config.proactiveSilenceDays {
            return "待办事项未跟进(\(daysSinceLastMsg)天): \(memory.pendingItems.first ?? "")"
        }

        // Trigger 2: Long silence with close contacts (> silenceDays)
        if daysSinceLastMsg >= config.proactiveSilenceDays && !memory.sharedContext.isEmpty {
            return "好友\(daysSinceLastMsg)天未联系，有共同背景"
        }

        // Trigger 3: Conversation left mid-discussion
        if memory.conversationPhase == "讨论" && daysSinceLastMsg >= 1 {
            return "讨论中断\(daysSinceLastMsg)天，话题: \(memory.keyTopics.first ?? "未知")"
        }

        return nil
    }

    // MARK: - Style consistency score

    /// Quick heuristic: does the reply match the user's style profile?
    /// Returns 0-100. Checks length range, punctuation pattern, and phrase usage.
    private nonisolated static func computeStyleScore(
        reply: String, style: StyleProfiler.StyleProfile
    ) -> Int {
        var score = 100

        // Length check: is reply within P25-P75 range? (±50% tolerance)
        let len = reply.count
        let minLen = max(1, style.lengthP25 / 2)
        let maxLen = style.lengthP75 * 3 / 2
        if len < minLen || len > maxLen { score -= 30 }
        else if len < style.lengthP25 || len > style.lengthP75 { score -= 10 }

        // Punctuation: if user mostly doesn't use period, reply shouldn't end with one
        if style.punctuationStyle.contains("不加标点") {
            if reply.hasSuffix("。") || reply.hasSuffix(".") { score -= 15 }
        }

        // Emoji: if user uses emoji, not having any in reply is slightly off
        if style.usesEmoji {
            let hasEmoji = reply.unicodeScalars.contains { $0.properties.isEmoji && $0.properties.isEmojiPresentation }
            if !hasEmoji { score -= 5 }
        }

        // Frequent phrases: bonus if reply contains user's common phrases
        if style.frequentPhrases.contains(where: { reply.contains($0) }) {
            score = min(100, score + 10)
        }

        return max(0, score)
    }

    // MARK: - Per-contact style hint

    /// Build a natural-language hint about the user's style with this specific contact.
    private nonisolated static func buildContactStyleHint(
        style: StyleProfiler.StyleProfile,
        contactRole: ContactRole
    ) -> String {
        var parts: [String] = []
        // Length style
        if style.avgLength < 10 { parts.append("和他聊天很简短") }
        else if style.avgLength > 30 { parts.append("和他聊天比较详细") }
        // Emoji
        if style.usesEmoji { parts.append("经常用 emoji") }
        // Typing rhythm
        switch style.typingRhythm {
        case .multiMessage: parts.append("习惯分多条发消息")
        case .mixed: parts.append("有时分多条发")
        case .singleMessage: break
        }
        // Role-based hints
        switch contactRole {
        case .boss, .keyClient: parts.append("语气偏正式")
        case .friend, .family: parts.append("语气随意自然")
        default: break
        }
        return parts.isEmpty ? "" : parts.joined(separator: "，")
    }

    // MARK: - Typing delay estimation

    /// Estimate how long it would take a human to type the reply.
    /// ~3-5 chars/second for Chinese input, with a minimum of 1.5s.
    private static func estimateTypingDelay(for text: String) -> TimeInterval {
        let charCount = Double(text.count)
        // Chinese input: ~3-5 chars/sec, we use 4 chars/sec average
        let typingTime = charCount / 4.0
        // Add small random jitter (±20%)
        let jitter = typingTime * Double.random(in: -0.2...0.2)
        return max(1.5, min(8.0, typingTime + jitter))  // clamp 1.5s - 8s
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

    /// Classify a media message by type. Returns nil for text messages.
    enum MediaType: String {
        case image = "图片"
        case voice = "语音"
        case video = "视频"
        case file = "文件"
        case sticker = "动画表情"
        case customSticker = "贴纸"
        case location = "位置"
        case nameCard = "名片"
        case miniProgram = "小程序"
        case transfer = "转账"
        case redPacket = "红包"

        /// Whether autopilot should attempt a response (vs skip silently).
        var shouldRespond: Bool {
            switch self {
            case .sticker, .customSticker: return false
            case .image, .voice, .video, .file, .location, .nameCard, .miniProgram: return true
            case .transfer, .redPacket: return true  // will be force-pending
            }
        }

        /// Whether this type must be routed to pending (financial/sensitive).
        var forcePending: Bool {
            switch self {
            case .transfer, .redPacket, .miniProgram: return true
            default: return false
            }
        }

        /// Context description for the AI prompt.
        var promptContext: String {
            switch self {
            case .image: return "对方发了一张图片。你看不到图片内容，但可以自然地回应（如'看到了'、'这个不错'、问对方图片是什么）。不要假装看到了具体内容。"
            case .voice: return "对方发了一条语音消息。你听不到内容，可以让对方打字说或简单回应。"
            case .video: return "对方发了一个视频。你现在看不了，自然地回应（如'我一会儿看'、'视频先存着'）。"
            case .file: return "对方发了一个文件。自然回应（如'收到'、'我看看'、'一会儿打开'）。"
            case .location: return "对方分享了一个位置。可以回应（如'知道了'、'我看看怎么走'）。"
            case .nameCard: return "对方发了一张名片。可以回应（如'收到'、'我加一下'）。"
            case .miniProgram: return "对方发了一个小程序。"
            case .transfer: return "对方发起了一笔转账。这需要本人处理。"
            case .redPacket: return "对方发了一个红包。这需要本人处理。"
            case .sticker, .customSticker: return "表情包"
            }
        }
    }

    /// Classify media by message type codes (primary) and text prefix (fallback).
    private func classifyMediaByType(messageType: Int, appType: Int, text: String) -> MediaType? {
        // Primary: numeric type codes from WeChatParser
        switch messageType {
        case 3: return .image
        case 34: return .voice
        case 43: return .video
        case 47: return .sticker
        case 48: return .location
        case 49: // appmsg — further classify by appType
            switch appType {
            case 6: return .file
            case 42: return .nameCard
            case 33, 36: return .miniProgram
            case 2000: return .transfer
            case 2001: return .redPacket
            default: return nil // regular link/article — treat as text
            }
        default: break
        }
        // Fallback: text prefix matching
        let prefixMapping: [(String, MediaType)] = [
            ("[图片]", .image), ("[语音]", .voice), ("[视频]", .video),
            ("[文件]", .file), ("[表情]", .sticker), ("[动画表情]", .sticker),
            ("[贴纸]", .customSticker), ("[位置]", .location), ("[名片]", .nameCard)
        ]
        for (prefix, type) in prefixMapping {
            if text.hasPrefix(prefix) { return type }
        }
        return nil
    }

    /// Legacy text-only check for backward compat.
    private func classifyMedia(_ text: String) -> MediaType? {
        classifyMediaByType(messageType: 1, appType: 0, text: text)
    }

    /// Check if message is non-text media.
    private func isMediaMessage(_ text: String) -> Bool {
        classifyMedia(text) != nil
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
