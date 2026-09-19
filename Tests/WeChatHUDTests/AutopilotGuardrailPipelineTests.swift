import XCTest
@testable import WeChatHUD

/// Behaviour tests for the guardrails that only exist on the real
/// `handleNewMessages` path.
///
/// The audit found these branches had no test coverage at all: the financial
/// force-pending rule is consumed in Phase 1 of `handleNewMessages`, and no
/// test in the repo ever called that function — the financial guardrail was
/// documented, implemented, and unverified.
final class AutopilotGuardrailPipelineTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUp() async throws {
        tmpPath = NSTemporaryDirectory() + "hud_autopilot_guardrails_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await service.start()
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    private func inbound(
        uid: String,
        text: String,
        isGroup: Bool = false,
        isAtMention: Bool = false,
        messageType: Int = 1,
        appType: Int = 0
    ) -> AutopilotService.InboundMessage {
        AutopilotService.InboundMessage(
            msgUID: uid,
            chatUsername: isGroup ? "room@chatroom" : "wxid_peer",
            chatName: isGroup ? "项目群" : "同事",
            senderUsername: "wxid_peer",
            senderName: "同事",
            text: text,
            isGroup: isGroup,
            isAtMention: isAtMention,
            attentionLevel: .whitelist,
            contactRole: .colleague,
            timestamp: Int(Date().timeIntervalSince1970),
            messageType: messageType,
            appType: appType
        )
    }

    private func autoSendConfig() -> AutopilotConfig {
        var config = AutopilotConfig()
        config.autoSendEnabled = true
        config.confidenceThreshold = 0.8
        return config
    }

    private func assertForcedPending(_ message: AutopilotService.InboundMessage) async {
        let result = await service.handleNewMessages([message], config: autoSendConfig(), myUsername: "me")
        XCTAssertEqual(result.logEntries.count, 1, "\(message.msgUID) should produce exactly one log entry")
        let entry = result.logEntries.first
        XCTAssertEqual(entry?.action, .pending, "\(message.msgUID) must never auto-send")
        XCTAssertEqual(entry?.riskLevel, .high)
        XCTAssertEqual(entry?.generatedReply, nil)
        XCTAssertTrue(result.ackedMsgUIDs.contains(message.msgUID))
        let queue = await service.pendingSendQueue
        XCTAssertTrue(queue.isEmpty, "financial media must not enter the send queue")
    }

    func testTransferMessageIsForcedPending() async {
        await assertForcedPending(inbound(uid: "transfer-1", text: "[转账]", messageType: 49, appType: 2000))
    }

    func testRedPacketMessageIsForcedPending() async {
        await assertForcedPending(inbound(uid: "redpacket-1", text: "[微信红包]", messageType: 49, appType: 2001))
    }

    func testMiniProgramMessageIsForcedPending() async {
        await assertForcedPending(inbound(uid: "miniprogram-1", text: "[小程序]", messageType: 49, appType: 33))
    }

    func testStickerIsSkippedWithoutQueueing() async {
        let result = await service.handleNewMessages(
            [inbound(uid: "sticker-1", text: "[动画表情]", messageType: 47)],
            config: autoSendConfig(),
            myUsername: "me"
        )
        XCTAssertEqual(result.logEntries.first?.action, .skipped)
        let queue = await service.pendingSendQueue
        XCTAssertTrue(queue.isEmpty)
    }

    /// With @-mention handling off (the default), group traffic is logged only.
    func testGroupMessageIsLoggedOnlyWhenGroupHandlingIsOff() async {
        let result = await service.handleNewMessages(
            [inbound(uid: "group-1", text: "@我 看一下", isGroup: true, isAtMention: true)],
            config: autoSendConfig(),
            myUsername: "me"
        )
        XCTAssertEqual(result.logEntries.first?.action, .groupLogged)
        let queue = await service.pendingSendQueue
        XCTAssertTrue(queue.isEmpty)
    }

    /// A text message is buffered for the batch window, never sent inline.
    func testTextMessageIsBufferedRatherThanSentInline() async {
        let result = await service.handleNewMessages(
            [inbound(uid: "text-1", text: "帮我看下这个需求")],
            config: autoSendConfig(),
            myUsername: "me"
        )
        XCTAssertTrue(result.logEntries.isEmpty)
        let sent = await service.sessionSent
        XCTAssertEqual(sent, 0)
    }

    /// `handleGroupAt` only lets a group @ enter the batch; the send queue
    /// still carries the product hold so timers cannot auto-send it.
    func testGroupAtWithHandlingOnStillRequiresManualConfirm() async throws {
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        stubDecision(reply: "好的，我看一下", confidence: 0.95)

        let pipeline = makePipelineService()
        try await pipeline.start()

        var config = pipelineConfig()
        config.handleGroupAt = true
        let result = await pipeline.handleNewMessages(
            [inbound(uid: "group-at-1", text: "@我 看一下排期", isGroup: true, isAtMention: true)],
            config: config,
            myUsername: "me"
        )

        XCTAssertFalse(result.logEntries.isEmpty, "expired batch must produce a log row")
        XCTAssertNotEqual(result.logEntries.first?.action, .sent)
        let queue = await pipeline.pendingSendQueue
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.manualOnlyReason, "群聊消息，请人工确认后发送")
        let sent = await pipeline.sessionSent
        XCTAssertEqual(sent, 0)
        try? await pipeline.stop()
    }

    /// Image (type 3) replies go through `processBatch`, so media decay is
    /// applied before the 0.8 threshold — 0.9 becomes 0.63 and cannot auto-send.
    func testImageMessageDecaysConfidenceOnRealBatchPath() async throws {
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        stubDecision(reply: "好的，我看一下", confidence: 0.9)

        let pipeline = makePipelineService()
        try await pipeline.start()

        let result = await pipeline.handleNewMessages(
            [inbound(uid: "img-1", text: "[图片]", messageType: 3)],
            config: pipelineConfig(),
            myUsername: "me"
        )

        XCTAssertEqual(
            AutopilotService.effectiveConfidence(base: 0.9, hasMedia: true),
            0.63,
            accuracy: 0.0001
        )
        XCTAssertLessThan(0.63, AutopilotConfig().confidenceThreshold)
        let queue = await pipeline.pendingSendQueue
        XCTAssertEqual(queue.count, 1, "decayed media must still queue for a human, got \(result.logEntries)")
        XCTAssertEqual(queue.first?.manualOnlyReason, "安全策略要求人工确认后再发送")
        XCTAssertEqual(queue.first?.confidence ?? 0, 0.63, accuracy: 0.0001)
        XCTAssertNotEqual(result.logEntries.first?.action, .sent)
        try? await pipeline.stop()
    }

    /// A high-confidence send whose reply contains a default keyword is
    /// held on the real `handleNewMessages` → `processBatch` → enqueue path.
    func testSensitiveKeywordInGeneratedReplyHoldsTheSend() async throws {
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        stubDecision(reply: "我帮你转账", confidence: 0.95)

        let pipeline = makePipelineService()
        try await pipeline.start()

        _ = await pipeline.handleNewMessages(
            [inbound(uid: "kw-1", text: "今晚吃饭吗")],
            config: pipelineConfig(),
            myUsername: "me"
        )

        let queue = await pipeline.pendingSendQueue
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.manualOnlyReason, "安全检查：命中敏感词「转账」")
        let sent = await pipeline.sessionSent
        XCTAssertEqual(sent, 0)
        try? await pipeline.stop()
    }

    /// Session cap 50 is enforced in `executeSend` before WeChat/AX work.
    func testSessionCapBlocksExecuteSendAndKeepsManualHold() async {
        await service.testingSetSessionSent(50)
        let item = PendingSend(
            chatUsername: "wxid_peer",
            chatName: "同事",
            senderName: "同事",
            replyText: "好的",
            confidence: 0.95,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date()
        )
        let outcome = await service.testingExecuteSend(item: item, config: autoSendConfig())
        XCTAssertEqual(outcome, .blocked("已达到本次会话发送上限"))
        let queue = await service.pendingSendQueue
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.manualOnlyReason, "已达到本次会话发送上限，请人工确认")
        let sent = await service.sessionSent
        XCTAssertEqual(sent, 50)
    }

    /// Turning 自动发送 on used to release the entire backlog at once:
    /// `handleNewMessages` never consults the master switch, so drafts queued
    /// while it was off stayed eligible indefinitely, and the staleness check
    /// only looks for *newer* messages — a peer who simply went quiet fails it
    /// open. They must become human-required, not fire into conversations that
    /// have moved on.
    func testBacklogDraftIsRetiredInsteadOfReleased() async throws {
        let pipeline = makePipelineService()
        try await pipeline.start()
        let stale = PendingSend(
            chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "好的，我看一下", confidence: 0.95, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-7_200)
        )
        await pipeline.testingEnqueue(stale)
        await pipeline.processPendingQueue(config: pipelineConfig())

        let queue = await pipeline.pendingSendQueue
        XCTAssertEqual(queue.count, 1, "the retired draft stays for the user")
        XCTAssertEqual(queue.first?.manualOnlyReason, AutopilotService.staleBacklogHoldReason)
        let sent = await pipeline.sessionSent
        XCTAssertEqual(sent, 0, "a two-hour-old draft must not go out unattended")
        try? await pipeline.stop()
    }

    /// The same rule must not catch a draft that is merely waiting out its own
    /// human-like delay (capped at 300s).
    func testFreshDraftStillPassesTheStalenessWindow() {
        let now = Date()
        let fresh = PendingSend(
            chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "好的", confidence: 0.95, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: now.addingTimeInterval(-300)
        )
        XCTAssertFalse(AutopilotService.isStaleForAutomaticSend(fresh, now: now))
        XCTAssertTrue(AutopilotService.isEligibleForAutomaticSend(fresh, now: now))

        var held = fresh
        held.manualOnlyReason = "群聊消息，请人工确认后发送"
        XCTAssertFalse(
            AutopilotService.isStaleForAutomaticSend(held, now: now.addingTimeInterval(86_400)),
            "an already manual-only item has nothing left to retire"
        )
    }

    // MARK: - Pipeline helpers

    private func pipelineConfig() -> AutopilotConfig {
        var config = AutopilotConfig()
        config.autoSendEnabled = true
        config.confidenceThreshold = 0.8
        config.maxSendsPerSession = 50
        config.batchWindowSeconds = 0
        config.silentNightThreshold = 0
        return config
    }

    private func makePipelineService() -> AutopilotService {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            model: "test-model",
            apiKey: "test"
        )
        return AutopilotService(store: store, reader: reader, aiService: AIService(config: cfg))
    }

    private func stubDecision(reply: String, confidence: Double) {
        stubDecision(action: "send", reply: reply, confidence: confidence)
    }

    private func stubDecision(action: String, reply: String?, confidence: Double) {
        var payload: [String: Any] = [
            "action": action,
            "confidence": confidence,
            "risk": "low",
            "reasoning": "ok"
        ]
        if let reply { payload["reply"] = reply }
        let content = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: content,
            urlString: "http://127.0.0.1:9/v1/chat/completions"
        )
        URLRequestRecorder.stubbedResponses = [URLRequestRecorder.stubbedResponse!]
    }

    /// The prompt's vocabulary is `send|stall|read_no_reply|skip`. Anything else
    /// ("hold", "confirm", a value truncated mid-word — ordinary model drift)
    /// was folded by the decoder into `pending=true`, which the stall branch
    /// then treated as permission to send: an unreadable reply from the model
    /// put its text straight into a real chat with no human in the loop.
    func testUnrecognizedActionCannotQueueAnAutoSend() async throws {
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        stubDecision(action: "hold", reply: "周末安排还不确定，周五再定", confidence: 0.99)

        let pipeline = makePipelineService()
        try await pipeline.start()

        let result = await pipeline.handleNewMessages(
            [inbound(uid: "unknown-action-1", text: "周末一起爬山吗")],
            config: pipelineConfig(),
            myUsername: "me"
        )

        let queue = await pipeline.pendingSendQueue
        XCTAssertTrue(queue.isEmpty, "an unparsed action must not queue a send: \(queue)")
        XCTAssertFalse(result.logEntries.isEmpty, "the decision must still be auditable")
        XCTAssertNotEqual(result.logEntries.first?.action, .sent)
        XCTAssertNotEqual(result.logEntries.first?.action, .stall)
        try? await pipeline.stop()
    }

    /// An unrecognized action with no reply text used to fall into the
    /// read-no-reply branch, which opens the chat in WeChat — an outward side
    /// effect granted to a response the app could not even parse.
    func testUnrecognizedActionWithoutReplyDoesNotOpenTheChat() async throws {
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        stubDecision(action: "confirm", reply: nil, confidence: 0.99)

        let pipeline = makePipelineService()
        try await pipeline.start()

        let result = await pipeline.handleNewMessages(
            [inbound(uid: "unknown-action-2", text: "在吗")],
            config: pipelineConfig(),
            myUsername: "me"
        )

        XCTAssertFalse(result.logEntries.isEmpty, "the decision must still be auditable")
        XCTAssertEqual(result.logEntries.first?.action, .skipped)
        XCTAssertNotEqual(result.logEntries.first?.action, .readNoReply)
        let queue = await pipeline.pendingSendQueue
        XCTAssertTrue(queue.isEmpty)
        try? await pipeline.stop()
    }
}
