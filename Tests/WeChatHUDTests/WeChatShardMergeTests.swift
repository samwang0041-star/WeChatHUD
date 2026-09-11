import XCTest
@testable import WeChatHUD

/// A chat's history is split across `message_N.db` shards.
///
/// `getMessages` used to stop at the first shard that held the chat's
/// `Msg_<md5>` table and return only that slice. On the reference account 932 of
/// 2572 tables existed in more than one shard and 103 of 115 whitelisted chats
/// were multi-shard, so historical and by-day queries silently returned empty
/// for slices that lived in another file.
final class WeChatShardMergeTests: XCTestCase {
    private let chat = "sharded_peer"

    private func fixture() throws -> SyntheticShardedScanFixture {
        try SyntheticShardedScanFixture(chatUsername: chat, shards: [
            0: [
                .init(localId: 1, createTime: 2_000, senderId: 1, text: "今天的问题"),
                .init(localId: 2, createTime: 3_000, senderId: 1, text: "今天的结论")
            ],
            3: [
                .init(localId: 1, createTime: 1_000, senderId: 1, text: "上周的问题"),
                .init(localId: 2, createTime: 1_500, senderId: 1, text: "上周的结论")
            ]
        ])
    }

    func testGetMessagesMergesEveryShardNewestFirst() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }

        let messages = try fixture.reader.getMessages(chatUsername: chat, limit: 10)

        XCTAssertEqual(messages.map(\.createTime), [3_000, 2_000, 1_500, 1_000])
        XCTAssertEqual(Set(messages.map(\.id)).count, 4, "ids must stay unique across shards")
    }

    /// The old behaviour returned only the first shard's slice, and the page
    /// limit applied per shard — so "newest 2" could come from either file.
    func testLimitAppliesToTheMergedPage() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }

        let newest = try fixture.reader.getMessages(chatUsername: chat, limit: 2)
        XCTAssertEqual(newest.map(\.createTime), [3_000, 2_000])

        let oldest = try fixture.reader.getMessages(
            chatUsername: chat, limit: 2, afterCursor: nil, oldestFirst: true)
        XCTAssertEqual(oldest.map(\.createTime), [1_000, 1_500])
    }

    /// The reported symptom: a day query whose messages sit in the *other* shard
    /// came back empty.
    func testDayQueryFindsMessagesInANonDefaultShard() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }

        let olderDay = try fixture.reader.getMessages(
            chatUsername: chat, limit: 100,
            afterCursor: nil,
            startTime: 900, endTime: 1_600
        )

        XCTAssertEqual(olderDay.map(\.createTime), [1_500, 1_000])
    }

    func testCursorPagingWalksAcrossShards() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }

        // First page ends at (1_500, localId 2) in shard 3; the next page must
        // continue *below* the anchor rather than repeating it.
        let firstPage = try fixture.reader.getMessages(chatUsername: chat, limit: 3)
        XCTAssertEqual(firstPage.map(\.createTime), [3_000, 2_000, 1_500])
        let anchor = try XCTUnwrap(firstPage.last)

        let nextPage = try fixture.reader.getMessages(
            chatUsername: chat, limit: 3,
            afterCursor: nil,
            beforeCursor: (anchor.createTime, max(0, anchor.localId - 1))
        )
        XCTAssertEqual(nextPage.map(\.createTime), [1_000])
    }

    func testEmptyResultIsCachedAsNegative() throws {
        let fixture = try SyntheticShardedScanFixture(chatUsername: "nobody_here", shards: [
            0: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "unrelated")]
        ])
        defer { fixture.cleanup() }

        XCTAssertTrue(try fixture.reader.getMessages(chatUsername: "missing_chat", limit: 10).isEmpty)
        XCTAssertTrue(
            try fixture.reader.getMessages(chatUsername: "missing_chat", limit: 10).isEmpty,
            "the negative result must be reused, not re-probed"
        )
    }
}
