import XCTest
@testable import WeChatHUD

/// A followed room contributes what WeChat says is unread — not what happens
/// to sit inside the fetched page.
///
/// The unread page is deliberately wider than the unread set (a room's page
/// mixes in self messages and bystander traffic, and the @-mentions the user
/// already read on the phone are still in it). Group rooms counted every
/// admitted message in that page, so a room reporting 1 unread pushed 31 into
/// 日报's 「未读 N 条」 and into the @ badge — the same "the fetch window reads
/// as a count" defect the private-chat branch had.
final class GroupUnreadCapTests: XCTestCase {
    private let room = "room_a@chatroom"

    private func makeFixture(rows: [SyntheticShardedScanFixture.MessageRow], unreadCount: Int) throws -> (SyntheticShardedScanFixture, HUDStore) {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: room, shards: [0: rows], unreadCount: unreadCount
        )
        let store = try fixture.makeStore()
        try store.addToWhitelist(
            username: room, displayName: "项目组", isGroup: true,
            category: .work, attentionLevel: .watch
        )
        return (fixture, store)
    }

    /// senderId 1 = the peer, 2 = this account (`synthetic_account`).
    private func mention(_ id: Int) -> SyntheticShardedScanFixture.MessageRow {
        .init(localId: id, createTime: 1_000 + id, senderId: 1, text: "@synthetic_account 第 \(id) 条看下")
    }

    private func scan(_ fixture: SyntheticShardedScanFixture, _ store: HUDStore) async throws -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: fixture.reader,
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

    func testSixMentionsInThePageReportTheOneUnread() async throws {
        let (fixture, store) = try makeFixture(rows: (1...6).map(mention), unreadCount: 1)
        defer { fixture.cleanup(); store.close() }

        let scanned = try await scan(fixture, store)
        let outcome = try XCTUnwrap(scanned)

        XCTAssertEqual(outcome.stats.atMentionCount, 1, "the @ badge must not read the page size")
        XCTAssertEqual(outcome.stats.unreadCount, 1)
        // What survives is the newest one, so the row still shows the message
        // the user actually has not seen.
        let rows = outcome.unreadItems.filter { $0.chatUsername == room }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.preview, "@synthetic_account 第 6 条看下")
    }

    func testUnreadCountAboveThePageStillClosesTheGap() async throws {
        let (fixture, store) = try makeFixture(rows: (1...6).map(mention), unreadCount: 6)
        defer { fixture.cleanup(); store.close() }

        let scanned = try await scan(fixture, store)
        let outcome = try XCTUnwrap(scanned)
        XCTAssertEqual(outcome.stats.atMentionCount, 6, "the cap must not shave real unread")
    }
}
