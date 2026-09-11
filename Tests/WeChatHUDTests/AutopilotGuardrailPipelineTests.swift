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
}
