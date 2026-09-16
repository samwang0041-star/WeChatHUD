import XCTest
@testable import WeChatHUD

/// Replying inside WeChat must clear the chat's inbox row on the next scan.
///
/// The feed (`recentNotifications`) only updated a chat's entry when a NEW
/// inbound arrived — a reply produces no inbound, so "私聊更新 / @了你" rows
/// lingered until the recent-limit pushed them out. The eviction pass in the
/// whitelist scan now drops any stored notification whose source message is
/// at-or-before your newest self message in that chat.
final class AnsweredFeedEvictionTests: XCTestCase {
    private let chat = "answered_peer"

    private func scan(
        _ reader: WeChatReader,
        store: HUDStore,
        recent: [HUDNotification] = []
    ) async throws -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: recent,
            recentLimit: 10,
            autopilotActive: false
        )
    }

    private func whitelist(_ store: HUDStore) throws {
        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
    }

    /// The reported bug: inbound lands, you answer in the WeChat window, and
    /// the row stays. After the fix the next scan sees your outbound row and
    /// evicts both the feed entry and the reply-debt item.
    func testReplyInWeChatEvictsFeedRowAndDebt() async throws {
        let inbound = SyntheticShardedScanFixture.MessageRow(
            localId: 1, createTime: 1_000, senderId: 1, text: "方案今晚能发我吗"
        )
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: [inbound]], unreadCount: 1
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }
        try whitelist(store)

        let first = try await scan(fixture.reader, store: store)
        let outcome1 = try XCTUnwrap(first)
        XCTAssertTrue(outcome1.recentNotifications.contains { $0.chatUsername == chat })
        XCTAssertTrue(outcome1.replyDebtItems.contains { $0.chatUsername == chat })

        // You reply in WeChat: the shard gains a self row (senderId 2 = the
        // account dir name → self) after the inbound.
        try fixture.rewriteShard(0, rows: [
            inbound,
            .init(localId: 2, createTime: 1_010, senderId: 2, text: "马上发你"),
        ])

        let second = try await scan(
            fixture.reader, store: store, recent: outcome1.recentNotifications
        )
        let outcome2 = try XCTUnwrap(second)
        XCTAssertFalse(
            outcome2.recentNotifications.contains { $0.chatUsername == chat },
            "the answered chat's feed row must disappear"
        )
        XCTAssertFalse(
            outcome2.replyDebtItems.contains { $0.chatUsername == chat },
            "a substantive reply clears the debt too"
        )
    }

    /// A self message that predates the inbound must NOT evict the row —
    /// otherwise any chat you ever wrote in would swallow new asks.
    func testOlderSelfMessageDoesNotEvict() async throws {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: [
                .init(localId: 1, createTime: 900, senderId: 2, text: "上周的记录"),
                .init(localId: 2, createTime: 1_000, senderId: 1, text: "新消息来了"),
            ]],
            unreadCount: 1
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }
        try whitelist(store)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        XCTAssertTrue(outcome.recentNotifications.contains { $0.chatUsername == chat })
    }

    /// Same-second ordering is decided by localId, not the timestamp: a self
    /// row with a smaller localId was written first, so the inbound is still
    /// unanswered even though both share one create_time.
    func testSameSecondReplyOrderingUsesLocalId() async throws {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: [
                .init(localId: 1, createTime: 1_000, senderId: 2, text: "我先说的"),
                .init(localId: 2, createTime: 1_000, senderId: 1, text: "对方同秒追问"),
            ]],
            unreadCount: 1
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }
        try whitelist(store)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        XCTAssertTrue(
            outcome.recentNotifications.contains { $0.chatUsername == chat },
            "self row with smaller localId came first — the inbound is unanswered"
        )
    }

    /// An inbound that lands AFTER your reply is a new ask: the notification
    //  for it must survive the eviction pass.
    func testInboundAfterReplySurvives() async throws {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: [
                .init(localId: 1, createTime: 1_000, senderId: 1, text: "第一条"),
                .init(localId: 2, createTime: 1_010, senderId: 2, text: "我的回复"),
                .init(localId: 3, createTime: 1_020, senderId: 1, text: "对方又追问"),
            ]],
            unreadCount: 2
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }
        try whitelist(store)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        let notif = outcome.recentNotifications.first { $0.chatUsername == chat }
        XCTAssertEqual(notif?.snippet, "对方又追问")
    }
}
