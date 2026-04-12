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
    private var aiConfig: AIClassifierConfig

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

    /// True while a send is in progress — prevents concurrent UI automation.
    private var isSending = false

    /// All msgUIDs of messages sent by autopilot — used for style isolation.
    private var sentMsgUIDs: Set<String> = []

    init(store: HUDStore, reader: WeChatReader, config: AIClassifierConfig) {
        self.store = store
        self.reader = reader
        self.aiConfig = config
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
        batchStartTimes.removeAll()
        sentMsgUIDs.removeAll()
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
        // Flush any remaining batches as skipped
        batchBuffer.removeAll()
        batchTimers.removeAll()
        batchStartTimes.removeAll()
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
            case .skipped, .groupLogged, .failed, .readNoReply: skipped += 1
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
        self.aiConfig = config
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
        if pausedForUserActivity {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: nil, confidence: 0, risk: .low,
                reasoning: "用户正在使用微信，暂停处理"
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
                "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \($0.text)"
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
            guard !pausedForUserActivity, self.sessionId != nil else {
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
        let delayNanos = UInt64(replyDelay * 1_000_000_000)

        let capturedSessionId = sessionId
        print("[WCHUD] Autopilot: delaying reply to '\(representative.chatName)' by \(Int(replyDelay))s (period=\(currentPeriod), urgency=\(urgency), hotChat=\(isHotChat))")
        try? await Task.sleep(nanoseconds: delayNanos)

        // Check if same autopilot session is still active after delay
        // (guards against stop→restart producing stale sends from old session)
        guard self.sessionId == capturedSessionId else {
            return makeLogEntry(
                sessionId: sessionId, msg: representative, action: .skipped,
                reply: replyText, confidence: decision.confidence, risk: risk,
                reasoning: "延迟期间托管 session 已变更"
            )
        }

        // --- Estimate typing time based on reply length ---
        let typingDelay = Self.estimateTypingDelay(for: replyText)

        // --- Send through serial queue with verification ---
        let success = await serialSendWithRateLimit(
            chatName: representative.chatName, chatUsername: representative.chatUsername,
            text: replyText, config: config, typingDelay: typingDelay
        )

        // sentMsgUIDs is now tracked inside serialSend via verifySend

        // Trigger memory update after successful send (runs within actor isolation)
        if success {
            await refreshMemoryAfterSend(
                chatUsername: representative.chatUsername,
                chatName: representative.chatName
            )
        }

        let reasoningWithScore = "\(decision.reasoning) [style:\(styleScore)/100]"

        return makeLogEntry(
            sessionId: sessionId, msg: representative,
            action: success ? .sent : .failed,
            reply: replyText, confidence: decision.confidence, risk: risk,
            reasoning: reasoningWithScore
        )
    }

    // MARK: - Serial send queue

    /// Serialize all sends through a single point. Only one send at a time.
    /// Includes clipboard save/restore, frontmost check, and post-send verification.
    private func serialSend(chatName: String, chatUsername: String, text: String, typingDelay: TimeInterval = 0) async -> Bool {
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
        let uiSuccess = await WeChatLauncher.sendMessage(chatName: chatName, text: text, typingDelay: typingDelay)
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
        text: String, config: AutopilotConfig,
        typingDelay: TimeInterval = 0
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

        let success = await serialSend(chatName: chatName, chatUsername: chatUsername, text: text, typingDelay: typingDelay)
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
            "\($0.senderName): \($0.text)"
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

        // Use aiConfig for lightweight AI call
        var baseURL = aiConfig.baseURL
        if !baseURL.contains("://") { baseURL = "http://\(baseURL)" }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        if !baseURL.hasSuffix("/v1") { baseURL += "/v1" }

        guard let url = URL(string: "\(baseURL)/chat/completions") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !aiConfig.apiKey.isEmpty {
            req.setValue("Bearer \(aiConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": aiConfig.model,
            "messages": [
                ["role": "system", "content": "你是对话摘要助手。只输出JSON。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 256
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        req.httpBody = httpBody

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return }

        // Strip thinking tags and parse JSON
        let cleaned: String
        if let lo = content.firstIndex(of: "{"), let hi = content.lastIndex(of: "}") {
            cleaned = String(content[lo...hi])
        } else { return }

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
