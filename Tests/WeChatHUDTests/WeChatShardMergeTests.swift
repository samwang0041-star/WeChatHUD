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

    /// The same split silently halved every insight number for a multi-shard
    /// chat: `bulkMessageStats` assigned per DB instead of folding, so the
    /// overview described whichever shard happened to be read last. On the
    /// reference account that is 103 of 115 whitelisted chats.
    func testBulkMessageStatsFoldsEveryShard() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }

        let stats = try XCTUnwrap(fixture.reader.bulkMessageStats(
            chatUsernames: [chat],
            selfNames: [],
            recentSinceTs: 2_500
        ), "两个分片都读得动，不许报「这一轮没读全」")

        XCTAssertEqual(stats[chat]?.totalCount, 4, "two shards of two messages each")
        XCTAssertEqual(stats[chat]?.earliestTs, 1_000)
        XCTAssertEqual(stats[chat]?.latestTs, 3_000)
        XCTAssertEqual(
            stats[chat]?.recentCount, 1,
            "only createTime 3_000 is at or after the cutoff — 近期 must be a span, not a shard"
        )
    }

    /// The other half of 「分片读不全」: a shard whose table cannot be queried used
    /// to be walked past, and what came back was a smaller number presented as the
    /// whole story — 洞察 printed 「这个对话 0 条消息」 and the neglect insight blamed
    /// the user for messages that were never counted.
    func testUnqueryableShardRefusesTheWholeRound() throws {
        let broken = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [
                0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "今天的问题")],
                3: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "上周的问题")]
            ],
            malformedShards: [3])
        defer { broken.cleanup() }

        XCTAssertNil(broken.reader.bulkMessageStats(chatUsernames: [chat], selfNames: []),
                     "读不全的一轮要交回「不知道」，而不是一个更小的可信数字")
    }

    /// And the page has to route that answer to a sentence, not to an empty board.
    func testInsightLoaderReportsAnIncompleteRoundInsteadOfPartialNumbers() async throws {
        func outcome(malformed: Bool) async throws -> InsightDataLoader.LoadOutcome {
            let fixture = try SyntheticShardedScanFixture(
                chatUsername: chat,
                shards: [
                    0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "今天的问题")],
                    3: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "上周的问题")]
                ],
                malformedShards: malformed ? [3] : [])
            let store = try fixture.makeStore()
            defer { fixture.cleanup(); store.close() }
            return await InsightDataLoader().load(
                store: store,
                readerActor: WeChatReaderActor(fixture.reader),
                replyDebtItems: [],
                window: .all,
                scope: .all
            )
        }

        if case .unreadable(let notice) = try await outcome(malformed: false) {
            XCTFail("正对照：两个分片都读得动的一轮必须交出数字，否则这条门只是「永远说读不到」— \(notice)")
        }
        if case .unreadable(let notice) = try await outcome(malformed: true) {
            XCTAssertFalse(notice.isEmpty, "拒了就得说为什么拒")
        } else {
            XCTFail("分片读不全时不许交出数字，也不许当「这个对话没聊过」")
        }
    }

    func testGetMessagesMergesEveryShardNewestFirst() throws {        let fixture = try fixture()
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

    /// WeChat creates a `Msg_` table lazily inside an already-keyed shard. A
    /// positive shard mapping probed while the table was absent must not hide
    /// the messages that appear there later.
    func testTableCreatedLaterInExistingShardJoinsTheMerge() throws {
        let fixture = try SyntheticShardedScanFixture(chatUsername: chat, optionalShards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "旧消息")],
            1: nil   // keyed shard exists but carries no Msg_ table yet
        ])
        defer { fixture.cleanup() }

        XCTAssertEqual(
            try fixture.reader.getMessages(chatUsername: chat, limit: 10).map(\.text),
            ["旧消息"],
            "first query caches the positive mapping [message_0]"
        )

        // WeChat lazily creates the chat's table inside the keyed shard 1.
        try fixture.rewriteShard(1, rows: [
            .init(localId: 1, createTime: 3_000, senderId: 1, text: "新消息")
        ])
        _ = try fixture.reader.refreshIfChanged(relPath: "message/message_1.db")

        XCTAssertEqual(
            try fixture.reader.getMessages(chatUsername: chat, limit: 10).map(\.createTime),
            [3_000, 2_000],
            "a table appearing in a previously-probed shard must be discovered"
        )
    }

    /// A shard listed in the key manifest whose file is absent used to throw
    /// out of the probe loop, failing the query for every chat — including
    /// ones fully readable in healthy shards.
    func testMissingKeyedShardDoesNotFailOtherShards() throws {
        let fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")]
        ])
        defer { fixture.cleanup() }
        try fixture.addKeyForMissingShard(9)

        XCTAssertEqual(
            try fixture.reader.getMessages(chatUsername: chat, limit: 10).map(\.text),
            ["可读消息"],
            "a keyed-but-missing shard must be skipped, not propagated"
        )
    }

    /// Same for a shard whose bytes do not decrypt to a readable database.
    func testCorruptShardDoesNotFailOtherShards() throws {
        let fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")],
            2: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "会被破坏")]
        ])
        defer { fixture.cleanup() }
        try fixture.corruptShard(2)

        XCTAssertEqual(
            try fixture.reader.getMessages(chatUsername: chat, limit: 10).map(\.text),
            ["可读消息"],
            "an unreadable shard must not hide the healthy shard's rows"
        )
    }
}
