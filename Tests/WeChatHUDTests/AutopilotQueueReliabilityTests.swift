import XCTest
@testable import WeChatHUD

final class AutopilotQueueReliabilityTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!
    private var reader: WeChatReader!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_autopilot_queue_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testPausedExecuteSendReappendsAndDoesNotCountSessionSent() async throws {
        let service = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await service.start()
        await service.manualPause()

        let item = PendingSend(
            chatUsername: "wxid_a",
            chatName: "A",
            senderName: "A",
            replyText: "好的",
            confidence: 0.9,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1)
        )
        let outcome = await service.testingExecuteSend(item: item, config: AutopilotConfig())
        XCTAssertEqual(outcome, .blocked("自动驾驶暂停或会话未启动"))
        let queued = await service.pendingSendQueue
        XCTAssertEqual(queued.map(\.id), [item.id])
        let sent = await service.sessionSent
        XCTAssertEqual(sent, 0)
    }

    func testProcessPendingQueueDoesNotCountQueuedItemsAsSent() async throws {
        let service = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await service.start()
        var config = AutopilotConfig()
        config.autoSendEnabled = false
        await service.testingEnqueue(
            PendingSend(
                chatUsername: "wxid_a",
                chatName: "A",
                senderName: "A",
                replyText: "好的",
                confidence: 0.9,
                risk: .low,
                reasoning: "ok",
                styleScore: 80,
                scheduledSendTime: Date().addingTimeInterval(-1)
            )
        )
        await service.processPendingQueue(config: config)
        let sent = await service.sessionSent
        XCTAssertEqual(sent, 0)
        let queued = await service.pendingSendQueue
        XCTAssertEqual(queued.count, 1)
    }

    /// Retiring a stale backlog draft converts it to 「needs a human」. Three other
    /// places do that same conversion and all three counted it; this one did not,
    /// so the 待确认回复 badge and the audit row sat below the real queue for as
    /// long as the peer stayed quiet — which is precisely the state that makes a
    /// draft stale in the first place.
    func testStaleBacklogRetirementCountsTheConversion() async throws {
        let service = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await service.start()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: 0, chatUsername: "wxid_idle", chatName: "老张",
            senderUsername: "wxid_idle", senderName: "老张",
            triggerMsgUID: "shard/Msg_idle/1", triggerText: "在吗",
            generatedReply: "稍等我翻一下", confidence: 0.9, riskLevel: .low,
            action: .sent, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))

        var config = AutopilotConfig()
        config.autoSendEnabled = true
        let stale = Date().addingTimeInterval(-3 * 3600)
        await service.testingEnqueue(PendingSend(
            chatUsername: "wxid_idle", chatName: "老张", senderName: "老张",
            replyText: "稍等我翻一下", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: stale, createdAt: stale
        ))

        let before = store.loadAutopilotSessions(limit: 1).first?.totalPending ?? -1
        await service.processPendingQueue(config: config)

        let queued = await service.pendingSendQueue
        XCTAssertEqual(queued.count, 1, "退役不是丢弃：草稿还要留在人能看见的地方")
        XCTAssertNotNil(queued.first?.manualOnlyReason,
                        "超过新鲜窗口的排队项必须失去自动发送资格")
        let after = store.loadAutopilotSessions(limit: 1).first?.totalPending ?? -1
        XCTAssertEqual(after, before + 1,
                       "转成「等人工」却没计数 = 徽标和真实队列长期不一致")
        let rows = store.loadAutopilotLog(sessionId: 0)
        XCTAssertTrue(rows.contains { $0.action == .pending && $0.generatedReply == "稍等我翻一下" },
                      "log 孪生没跟着翻成 pending，审批台就永远不offer这条")
    }
}
