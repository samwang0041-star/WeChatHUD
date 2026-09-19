import XCTest
@testable import WeChatHUD

/// 「多条未回」 must be reachable from one private chat.
///
/// A private chat contributes a single inbox row however long its unanswered
/// tail is — the newest message stands for the rest. The burst rule counted
/// rows, so the case the copy describes (someone firing off messages at you in
/// a DM) produced one, and the rule could only ever fire for group members.
/// The row now carries the tail it stands for, and both the rule and 日报's
/// 「未读 N 条」 count messages with it.
final class PrivateBurstCountTests: XCTestCase {
    private let chat = "burst_peer"

    // MARK: - Scan level: the row must carry its tail

    private func scan(_ reader: WeChatReader, store: HUDStore) async throws -> ScanEngine.ScanOutcome? {
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

    private func makeFixture(
        rows: [SyntheticShardedScanFixture.MessageRow],
        unreadCount: Int
    ) throws -> (SyntheticShardedScanFixture, HUDStore) {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: unreadCount
        )
        let store = try fixture.makeStore()
        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        return (fixture, store)
    }

    /// senderId 1 = the peer, 2 = this account (see SyntheticShardedScanFixture).
    private func inbound(_ id: Int, text: String) -> SyntheticShardedScanFixture.MessageRow {
        .init(localId: id, createTime: 1_000 + id, senderId: 1, text: text)
    }

    private func outbound(_ id: Int, text: String) -> SyntheticShardedScanFixture.MessageRow {
        .init(localId: id, createTime: 1_000 + id, senderId: 2, text: text)
    }

    func testPrivateChatFoldsFiveDMsIntoOneRowHoldingFive() async throws {
        let (fixture, store) = try makeFixture(
            rows: (1...5).map { inbound($0, text: "第 \($0) 条") },
            unreadCount: 5
        )
        defer { fixture.cleanup(); store.close() }

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        let rows = outcome.unreadItems.filter { $0.chatUsername == chat }
        XCTAssertEqual(rows.count, 1, "the inbox stays one row per private chat")
        XCTAssertEqual(rows.first?.unansweredInboundCount, 5)
        // The row shows the newest message, so it can't be read as a count.
        XCTAssertEqual(rows.first?.preview, "第 5 条")
        XCTAssertEqual(outcome.stats.unreadCount, 5, "日报's 未读 counts messages")
    }

    /// Your own messages split the tail: only what arrived after your last
    /// reply is still 未回.
    func testOnlyTheTailAfterTheLastReplyCounts() async throws {
        let (fixture, store) = try makeFixture(
            rows: [
                inbound(1, text: "早就回过的"),
                outbound(2, text: "当时回了"),
                inbound(3, text: "还没回的 A"),
                inbound(4, text: "还没回的 B"),
            ],
            unreadCount: 2
        )
        defer { fixture.cleanup(); store.close() }

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        let row = try XCTUnwrap(outcome.unreadItems.first { $0.chatUsername == chat })
        XCTAssertEqual(row.unansweredInboundCount, 2)
    }

    func testAnsweredPrivateChatWaitsOnNothing() async throws {
        let (fixture, store) = try makeFixture(
            rows: [inbound(1, text: "在吗"), outbound(2, text: "在")],
            unreadCount: 1
        )
        defer { fixture.cleanup(); store.close() }

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        let row = try XCTUnwrap(outcome.unreadItems.first { $0.chatUsername == chat })
        XCTAssertEqual(row.unansweredInboundCount, 0)
        XCTAssertTrue(row.replied)
        // Still on screen, so it stands for the one message it shows.
        XCTAssertEqual(row.inboundMessageCount, 1)
    }

    // MARK: - Rule level: three DMs must alert

    private func makeUnread(
        chatUsername: String,
        senderUsername: String,
        senderName: String,
        kind: HUDNotificationKind = .privateChat,
        waiting: Int = 1,
        replied: Bool = false
    ) -> UnreadItem {
        UnreadItem(
            chatUsername: chatUsername,
            chatName: "同事",
            senderUsername: senderUsername,
            senderName: senderName,
            preview: "方案今晚能发我吗",
            timestamp: Date(timeIntervalSince1970: 1_000),
            kind: kind,
            isWhitelisted: true,
            isVIP: false,
            replied: replied,
            status: .pending,
            isIgnored: false,
            unansweredInboundCount: waiting
        )
    }

    /// The reported unreachable case: one chat, one row, three messages.
    @MainActor
    func testThreeUnansweredMessagesInOnePrivateChatAlert() async {
        let start = Date(timeIntervalSince1970: 5_000_000)
        var received: [(title: String, body: String, identifier: String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { title, body, identifier, completion in
                received.append((title, body, identifier))
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: [makeUnread(
                chatUsername: chat, senderUsername: "wxid_peer", senderName: "小王", waiting: 3
            )],
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.title, "多条未回")
        XCTAssertEqual(received.first?.body, "小王 有 3 条消息还没回")
    }

    @MainActor
    func testTwoUnansweredMessagesInOnePrivateChatStaySilent() async {
        let start = Date(timeIntervalSince1970: 5_100_000)
        var sent: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { _, _, identifier, completion in
                sent.append(identifier)
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: [makeUnread(
                chatUsername: chat, senderUsername: "wxid_peer", senderName: "小王", waiting: 2
            )],
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()
        XCTAssertTrue(sent.isEmpty, "2 条还没到「多条」")
    }

    /// An answered row must not be inflated into a burst by the new field.
    @MainActor
    func testAnsweredRowsAreNeverCountedHoweverLongTheFoldedTailWas() async {
        let start = Date(timeIntervalSince1970: 5_200_000)
        var sent: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { _, _, identifier, completion in
                sent.append(identifier)
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: [
                makeUnread(chatUsername: "c1", senderUsername: "wxid_peer", senderName: "小王",
                           waiting: 9, replied: true),
                makeUnread(chatUsername: "c2", senderUsername: "wxid_peer", senderName: "小王"),
                makeUnread(chatUsername: "c3", senderUsername: "wxid_peer", senderName: "小王"),
            ],
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()
        XCTAssertEqual(sent, [], "answered + 2 waiting is 2, not 11")
    }

    /// Group rows are one per message, so the unit change leaves them alone.
    @MainActor
    func testGroupRowsStillCountOneEach() async {
        let start = Date(timeIntervalSince1970: 5_300_000)
        var received: [(body: String, identifier: String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { _, body, identifier, completion in
                received.append((body, identifier))
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: (0..<3).map { _ in
                makeUnread(chatUsername: "room@chatroom", senderUsername: "wxid_peer",
                           senderName: "小王", kind: .groupMessage)
            },
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.body, "小王 有 3 条消息还没回")
    }

    // MARK: - The two consumers share one definition

    /// Both read the same property, so 日报 and the alert cannot disagree about
    /// what a row stands for.
    func testInboundMessageCountIsAtLeastOneEvenWhenTheTailIsZero() {
        let row = makeUnread(
            chatUsername: chat, senderUsername: "wxid_peer", senderName: "小王", waiting: 0
        )
        XCTAssertEqual(row.unansweredInboundCount, 0)
        XCTAssertEqual(row.inboundMessageCount, 1)
    }
}
