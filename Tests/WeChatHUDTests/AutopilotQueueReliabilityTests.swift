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
}
