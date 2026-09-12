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
        XCTAssertEqual(await pipeline.sessionSent, 0)
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
        XCTAssertEqual(await pipeline.sessionSent, 0)
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
        XCTAssertEqual(await service.sessionSent, 50)
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
        let payload: [String: Any] = [
            "action": "send",
            "reply": reply,
            "confidence": confidence,
            "risk": "low",
            "reasoning": "ok"
        ]
        let content = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: content,
            urlString: "http://127.0.0.1:9/v1/chat/completions"
        )
        URLRequestRecorder.stubbedResponses = [URLRequestRecorder.stubbedResponse!]
    }
}
