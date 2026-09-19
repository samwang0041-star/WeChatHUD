import XCTest
@testable import WeChatHUD

/// Un-following a chat is a scope change with collateral: its commitments,
/// todos, mute and snooze state all go with it. It used to run as eight
/// independent statements with seven of them under `try?`, so a failure in the
/// middle left the chat un-followed while its commitments kept firing overdue
/// alerts — and the UI reported success either way.
final class UntrackScopeAtomicityTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "untrack-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root! + "/hud.sqlite3")
        try store.open()
        try store.addToWhitelist(username: "chat-a", displayName: "小美", isGroup: false, category: .work)
        try store.upsertCommitment(msgUID: "c1", chatUsername: "chat-a", chatName: "小美",
                                   content: "周五前把方案发过去", commitTo: "我",
                                   confidence: 1, promptVersion: "test")
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testHalfFailedClearLeavesNothingCleared() throws {
        // Break a statement in the middle of the cascade: the deletes before it
        // would have taken effect on their own.
        try store.exec("DROP TABLE chat_actions")

        XCTAssertThrowsError(try store.removeFromWhitelist(username: "chat-a"))
        XCTAssertTrue(store.isWhitelisted("chat-a"), "the un-follow itself rolled back")
        let commitments = store.loadCommitments()
        XCTAssertEqual(commitments.count, 1)
        XCTAssertEqual(commitments.first?.status, .pending)
    }

    func testSuccessfulClearTakesTheDerivedArtifactsWithIt() throws {
        try store.removeFromWhitelist(username: "chat-a")
        XCTAssertFalse(store.isWhitelisted("chat-a"))
        XCTAssertTrue(store.loadCommitments().filter { $0.status == .pending || $0.status == .overdue }.isEmpty,
                      "an un-followed chat must not keep firing commitment alerts")
    }

    @MainActor
    func testMonitorKeepsTheRowWhenTheClearFails() throws {
        try store.exec("DROP TABLE chat_actions")
        let reader = WeChatReader(keysPath: root! + "/absent-keys.json",
                                  dbDir: root! + "/synthetic/db_storage", cacheStrategy: .memory)
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        let debt = ReplyDebtItem(
            id: "chat-a", chatUsername: "chat-a", chatName: "小美", senderName: "小美",
            preview: "方案准备好了吗", latestOutboundPreview: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), priority: .p1, score: 6,
            unreadCount: 1, isGroup: false, isWhitelisted: true, isVIP: false, isAtMention: false,
            inboundCountSinceLastOutbound: 1, reasons: [], overdueThresholdMinutes: 30
        )
        let item = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: [:])[0]
        monitor.replyDebtItems = [debt]

        monitor.untrackInboxItem(item)

        XCTAssertTrue(store.isWhitelisted("chat-a"))
        XCTAssertEqual(monitor.replyDebtItems.count, 1,
                       "the row must stay visible when the store said no")
    }
}
