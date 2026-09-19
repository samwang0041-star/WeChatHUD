import XCTest
@testable import WeChatHUD

/// A delivered reply must never stay offerable as unsent. The queue row and
/// its `autopilot_log` twin used to be retired by two independent `try?`
/// statements outside any transaction, so a failure between them left
/// 'pending' on the approval board for a text the peer had already received.
final class VerifiedSendResolveAtomicityTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "resolve-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root! + "/hud.sqlite3")
        try store.open()
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func seed() throws -> PendingSend {
        let item = PendingSend(
            chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "好的，我今晚发你", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date()
        )
        try store.upsertPendingSend(item, sessionId: 7)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: 7, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "m1", triggerText: "合同什么时候发",
            generatedReply: item.replyText, confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        ))
        return item
    }

    func testResolveRetiresBothTheQueueRowAndTheLogTwin() throws {
        let item = try seed()
        let flipped = try store.resolveVerifiedSend(
            queueId: item.id, chatUsername: "wxid_peer", replyText: item.replyText
        )
        XCTAssertEqual(flipped, 1)
        XCTAssertTrue(store.loadPendingSends(sessionId: 7).isEmpty)
        XCTAssertEqual(store.loadAutopilotLog(sessionId: 7).first?.action, .sent)
    }

    func testFailedFlipRollsBackTheQueueDelete() throws {
        let item = try seed()
        try store.exec("""
            CREATE TRIGGER break_log BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        XCTAssertThrowsError(try store.resolveVerifiedSend(
            queueId: item.id, chatUsername: "wxid_peer", replyText: item.replyText
        ))
        XCTAssertEqual(
            store.loadPendingSends(sessionId: 7).count, 1,
            "a half-applied resolve must not delete the row that keeps the reply tracked"
        )
        XCTAssertEqual(store.loadAutopilotLog(sessionId: 7).first?.action, .pending)
    }
}
