import XCTest
import SQLite3
@testable import WeChatHUD

/// §236: every consumer of `chat_actions` treats an empty dictionary as 「没有对话被
/// 静音」, and the read that produces it swallowed errors. Muting is how a user takes
/// back a reply without opening the approval card, so the failure answer had to become
/// 「don't deliver」 rather than 「nothing was withdrawn」.
final class MuteRuleFailClosedTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "mute-failclosed-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
    }

    func testReadSeparatesNoRulesFromCannotRead() throws {
        XCTAssertEqual(store.chatActionsRead()?.count, 0, "表在而行为空 = 确实没人被静音")
        try store.exec("ALTER TABLE chat_actions RENAME TO chat_actions_hidden")
        XCTAssertNil(store.chatActionsRead(), "读失败不能回答成「没有规则」")
    }

    func testUnreadableMuteTableRefusesTheSend() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
        await service.testingEnqueue(item)
        try store.upsertPendingSend(item, sessionId: sid)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-mute",
            triggerText: "在吗", generatedReply: item.replyText, confidence: 0.9,
            riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil,
            createdAt: Date(), queueId: item.id.uuidString
        ))
        let rowId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sid).first { $0.triggerMsgUID == "m-mute" }?.id)

        let permittedNormally = await service.deliveryStillPermitted(
            queueId: item.id, logId: rowId, chatUsername: "wxid_peer")
        XCTAssertTrue(permittedNormally, "正对照：没人静音、一切就绪时必须放行，否则这条判据只是永不发送")

        try store.exec("ALTER TABLE chat_actions RENAME TO chat_actions_hidden")
        let permittedBlind = await service.deliveryStillPermitted(
            queueId: item.id, logId: rowId, chatUsername: "wxid_peer")
        XCTAssertFalse(permittedBlind,
                       "读不到静音规则时放行 = 把用户用静音撤回过的回复敲进微信")
    }

    func testTimingCacheStaysBounded() async throws {
        let profiler = StyleProfiler(reader: reader, store: store)
        for i in 0..<(StyleProfiler.timingCacheCap + 40) {
            _ = await profiler.getTimingProfile(chatUsername: "peer_\(i)")
        }
        let count = await profiler.testingTimingCacheCount()
        XCTAssertLessThanOrEqual(count, StyleProfiler.timingCacheCap,
                                 "隔壁 profileCache 上一轮就补了上限，这一张同形状不能漏")
    }
}

/// The scan facade reads the same table for banner/snooze verdicts; a failed read
/// must cost a round, not consume the watermark.
final class ScanSkipsUnreadableMuteRulesTests: XCTestCase {
    private let chat = "mute_scan_peer"

    private func scan(_ reader: WeChatReader, store: HUDStore) async -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: [],
            recentLimit: 10,
            autopilotActive: false
        )
    }

    func testFailedReadDoesNotConsumeTheWatermark() async throws {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: [
                .init(localId: 1, createTime: 1_001, senderId: 1, text: "在吗"),
                .init(localId: 2, createTime: 1_002, senderId: 1, text: "结论呢")
            ]],
            unreadCount: 2)
        let store = try fixture.makeStore()
        defer { fixture.cleanup(); store.close() }
        try store.addToWhitelist(username: chat, displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .watch)

        try store.exec("ALTER TABLE chat_actions RENAME TO chat_actions_hidden")
        let skipped = await scan(fixture.reader, store: store)
        XCTAssertNil(skipped, "读不到静音规则时不出结论")

        try store.exec("ALTER TABLE chat_actions_hidden RENAME TO chat_actions")
        let healedOptional = await scan(fixture.reader, store: store)
        let healed = try XCTUnwrap(healedOptional)
        XCTAssertTrue(healed.unreadItems.contains { $0.chatUsername == chat },
                      "被跳过的那一轮不能顺手把水位推过去 —— 那两条消息就再也没有第二次机会")
    }
}
