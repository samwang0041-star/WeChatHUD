import XCTest
@testable import WeChatHUD

/// A backlog larger than one page must not be skipped in silence.
///
/// `whitelistFetchLimit` returned the fixed 100-row default whenever a chat had
/// a cursor, and the scan then advanced that cursor to the newest fetched
/// message. Any chat with more than 100 unread messages therefore lost the
/// middle of its backlog — never classified, never shown, never mentioned.
final class ScanBacklogPagingTests: XCTestCase {
    private let chat = "backlog_peer"

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

    func testIncrementalScanCoversABacklogLargerThanThePageCap() async throws {
        // 501 unread rows: one more than the 500-row hard cap, so covering the
        // backlog requires the backward paging the scan now does.
        let rows = (1...501).map {
            SyntheticShardedScanFixture.MessageRow(
                localId: $0,
                createTime: 1_000 + $0,
                senderId: 1,
                text: "第 \($0) 条待整理消息"
            )
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: rows.count
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        // A cursor from an earlier run: this is the incremental path, not the
        // first scan, and the old code's bug lived in that branch.
        try store.setWhitelistCursor(username: chat, lastCreateTime: 1_000, lastLocalId: 0)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned, "the scan itself failed")

        XCTAssertEqual(outcome.newInboundForClassifier.count, 501)
        XCTAssertEqual(store.classificationQueueCount(), 501)
        XCTAssertEqual(try store.discussionQueueCount(), 501)
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 1_501)
    }

    func testSmallIncrementalBacklogIsUnaffected() async throws {
        let rows = (1...3).map {
            SyntheticShardedScanFixture.MessageRow(
                localId: $0, createTime: 1_000 + $0, senderId: 1, text: "第 \($0) 条"
            )
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: rows.count
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chat, lastCreateTime: 1_000, lastLocalId: 0)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        XCTAssertEqual(outcome.newInboundForClassifier.count, 3)
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 1_003)
    }

    /// `unreadCount` in session.db counts only *inbound* unread rows, but the
    /// fetched page mixes in self-sent rows. Comparing the hint against
    /// `page.count` let self rows pad the page: a chat with 400 unread plus
    /// 200 newer self rows fetched a "full" page that held only 200 inbound —
    /// and the walk stopped, orphaning the other 200 behind the watermark.
    func testBackfillCoversUnreadWhenSelfRowsPadThePage() async throws {
        // Inbound at t=1001...1400 (senderId 1 = the peer), self at
        // t=1401...1600 (senderId 2 = the account dir name → self).
        var rows: [SyntheticShardedScanFixture.MessageRow] = []
        for i in 1...400 {
            rows.append(.init(localId: i, createTime: 1_000 + i, senderId: 1, text: "对方第 \(i) 条"))
        }
        for i in 401...600 {
            rows.append(.init(localId: i, createTime: 1_000 + i, senderId: 2, text: "我说第 \(i) 条"))
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: 400
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chat, lastCreateTime: 1_000, lastLocalId: 0)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)

        // fetchLimit is min(unread, 500)=400 → the first page holds the newest
        // 400 rows: 200 self + only 200 of the 400 unread inbound. The fix must
        // page backwards until all 400 inbound are covered.
        XCTAssertEqual(outcome.newInboundForClassifier.count, 400)
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 1_600)
    }

    /// First-scan seeding indexed `messages[unreadCount - 1]` on the
    /// mixed-direction list. With self rows interleaved in the newest N, the
    /// seed landed too high and the oldest unread messages never classified.
    func testFirstScanSeedAccountsForInterleavedSelfRows() async throws {
        // Newest-first: inbound t=4, self t=3, inbound t=2, inbound t=1.
        // unread=3 → the three inbound rows. The buggy index messages[2]
        // picked the t=2 inbound, seeding above the t=1 one.
        let rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(localId: 1, createTime: 1, senderId: 1, text: "最早的未读"),
            .init(localId: 2, createTime: 2, senderId: 1, text: "中间未读"),
            .init(localId: 3, createTime: 3, senderId: 2, text: "我自己发的"),
            .init(localId: 4, createTime: 4, senderId: 1, text: "最新未读")
        ]
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: 3
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        // No cursor — the first-scan seeding path.

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)

        XCTAssertEqual(outcome.newInboundForClassifier.count, 3)
        XCTAssertEqual(Set(outcome.newInboundForClassifier.map(\.msg.text)),
                       ["最早的未读", "中间未读", "最新未读"])
    }

    /// A backlog deeper than the per-scan page cap used to `continue` before
    /// any persistence — the chat's watermark stayed behind forever, the same
    /// chat ate the shared page budget every scan, and the rows it already
    /// fetched never reached the queues. The scan must now enqueue what it
    /// fetched, hold only the watermark, and resume the walk from a persisted
    /// frontier until the gap closes.
    func testIncompleteBacklogEnqueuesFetchedRowsAndResumesFromFrontier() async throws {
        // Cursor at t=100; 600 rows at t=101...700. Page size is 100 and the
        // per-chat cap is 3 pages, so one scan covers the newest 300 only.
        let rows = (1...600).map {
            SyntheticShardedScanFixture.MessageRow(
                localId: $0, createTime: 100 + $0, senderId: 1, text: "积压 \($0)"
            )
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: 0
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(
            username: chat, lastCreateTime: 100, lastLocalId: 0,
            lastShard: "message/message_0.db"
        )

        // Scan 1: fetches page (t=601..700) + 2 walk pages → cap.
        // Each walk page loses one row to the inclusive anchor echo, so the
        // scan admits 298, not 300. Fetched rows enqueue despite the
        // incomplete walk; the watermark holds at 100 and a frontier parks.
        let firstOutcome = try await scan(fixture.reader, store: store)
        let first = try XCTUnwrap(firstOutcome)
        XCTAssertEqual(store.classificationQueueCount(), 298,
                       "fetched rows must enqueue even while the backlog is incomplete")
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 100,
                       "watermark must not advance past an uncovered gap")
        XCTAssertNotNil(store.getBackfillCursor(username: chat),
                        "an interrupted walk must persist a resume point")
        XCTAssertEqual(first.newInboundForClassifier.count, 298)

        // Keep scanning until the walk converges on the baseline.
        for _ in 0..<8 {
            _ = try await scan(fixture.reader, store: store)
            if store.getWhitelistCursor(username: chat)?.lastCreateTime == 700 { break }
        }

        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 700,
                       "the walk must converge on the baseline, not restart at the page bottom")
        XCTAssertNil(store.getBackfillCursor(username: chat))
        XCTAssertEqual(store.classificationQueueCount(), 600)
    }

    /// A row written to a different `message_N.db` in the same second as the
    /// watermark row is not covered by `localId > lastLocalId` — that
    /// comparison only orders within one shard. The scan must admit it and
    /// let the durable content-key dedup absorb the replay.
    func testSameSecondRowInOtherShardIsAdmitted() async throws {
        let shard0Rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(localId: 1, createTime: 1_990, senderId: 1, text: "shard0 旧消息"),
            .init(localId: 5, createTime: 2_000, senderId: 1, text: "shard0 水印行")
        ]
        let shard1Rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(localId: 2, createTime: 2_000, senderId: 1, text: "shard1 同秒消息"),
            .init(localId: 3, createTime: 2_001, senderId: 1, text: "shard1 更新消息")
        ]
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: shard0Rows, 1: shard1Rows],
            unreadCount: 0
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(
            username: chat, lastCreateTime: 2_000, lastLocalId: 5,
            lastShard: "message/message_0.db"
        )

        let scannedOutcome = try await scan(fixture.reader, store: store)
        let scanned = try XCTUnwrap(scannedOutcome)
        let admitted = Set(store.pendingClassificationMessages(limit: 50).map(\.text))
        XCTAssertTrue(admitted.contains("shard1 同秒消息"),
                      "same-second row in another shard must not be filtered by localId")
        XCTAssertTrue(admitted.contains("shard1 更新消息"))
        XCTAssertFalse(admitted.contains("shard0 水印行"),
                       "the watermark row itself stays filtered")
        XCTAssertFalse(admitted.contains("shard0 旧消息"))
        XCTAssertEqual(scanned.newInboundForClassifier.count, 2)
    }

    /// A revokemsg sysmsg row must feed the recall pipeline — and must not
    /// enter the classification queue as conversation content.
    func testRevokemsgRecordsRecallAndSkipsClassifier() async throws {
        let rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(localId: 1, createTime: 1_000, senderId: 1, text: "明早九点前发我"),
            .init(
                localId: 2, createTime: 1_060, senderId: 1,
                text: "<sysmsg type=\"revokemsg\"><revokemsg><session>\(chat)</session><msgid>9</msgid><replacemsg><![CDATA[\"\(chat)\" 撤回了一条消息]]></replacemsg></revokemsg></sysmsg>",
                localType: 10000
            )
        ]
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: 2
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chat, lastCreateTime: 500, lastLocalId: 0)

        _ = try await scan(fixture.reader, store: store)

        let recalled = store.loadRecalledMessages()
        XCTAssertEqual(recalled.count, 1, "the revokemsg row must be recorded")
        XCTAssertEqual(recalled.first?.originalText, "明早九点前发我",
                       "the original is the recaller's newest prior message")
        XCTAssertEqual(recalled.first?.chatUsername, chat)
        // Only the real message reaches the classifier — never the sysmsg.
        XCTAssertEqual(store.classificationQueueCount(), 1)
    }

    /// Two group members sharing the nickname I learned as my own alias
    /// must NOT be promoted to "self" — the old code promoted on the alias
    /// alone, which would turn their messages into mine.
    func testAmbiguousGroupAliasDoesNotPromoteMember() async throws {
        let group = "audit_group@chatroom"
        // name2id rows 3 and 4 both claim "李雷"; row 5 is the only "小明".
        let rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(localId: 1, createTime: 1_000, senderId: 3, text: "群员的话不能变成我的"),
            .init(localId: 2, createTime: 1_010, senderId: 5, text: "我自己的群昵称消息"),
        ]
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: group,
            optionalShards: [0: rows],
            extraName2Id: ["李雷", "李雷", "小明"]
        )
        defer { fixture.cleanup() }
        // Non-persisting alias store — learned aliases live in memory only.
        let suite = UserDefaults(suiteName: "wchud-test-\(UUID().uuidString)")!
        let reader = WeChatReader(
            keysPath: fixture.keysURL.path, dbDir: fixture.dbDir.path,
            cacheStrategy: .memory, persistLearnedAliases: false,
            userDefaults: suite
        )
        try reader.loadKeys()
        reader.learnSelfAlias("李雷")
        reader.learnSelfAlias("小明")

        let messages = try reader.getMessages(chatUsername: group, limit: 10)
        let contested = try XCTUnwrap(messages.first(where: { $0.localId == 1 }))
        let mine = try XCTUnwrap(messages.first(where: { $0.localId == 2 }))

        XCTAssertEqual(contested.senderUsername, "李雷",
                       "a nickname claimed by another name2id id stays theirs")
        XCTAssertFalse(reader.mySelfNames.contains("李雷"),
                       "a contested alias must be evicted, not promoted")
        XCTAssertFalse(MessageHelpers.isFromSelf(
            contested, chatUsername: group, myUsername: reader.myUsername(),
            mySelfNames: reader.mySelfNames
        ))
        XCTAssertEqual(mine.senderUsername, reader.myUsername(),
                       "an unclaimed learned alias still promotes to self")
    }

    /// A sysmsg row carries realSenderId 0 like a self message — but its
    /// "hint" is parser noise, not a group nickname. Learning it would poison
    /// the alias set permanently.
    func testSysmsgRowDoesNotLearnSelfAlias() async throws {
        let group = "sys_group@chatroom"
        let rows: [SyntheticShardedScanFixture.MessageRow] = [
            .init(
                localId: 1, createTime: 1_000, senderId: 0,
                text: "垃圾前缀:\n<sysmsg type=\"sysmsgtemplate\"><content>加入群聊</content></sysmsg>",
                localType: 10000
            )
        ]
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: group, optionalShards: [0: rows]
        )
        defer { fixture.cleanup() }
        let suite = UserDefaults(suiteName: "wchud-test-\(UUID().uuidString)")!
        let reader = WeChatReader(
            keysPath: fixture.keysURL.path, dbDir: fixture.dbDir.path,
            cacheStrategy: .memory, persistLearnedAliases: false,
            userDefaults: suite
        )
        try reader.loadKeys()

        let messages = try reader.getMessages(chatUsername: group, limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(reader.mySelfNames.contains("垃圾前缀"),
                       "a sysmsg hint must never become a learned self alias")
        XCTAssertNotEqual(messages.first?.senderUsername, reader.myUsername())
    }

    /// Learned aliases expire — a nickname learned months ago can collide
    /// with a member who later took it.
    func testLearnedSelfAliasesExpire() async throws {
        let suite = UserDefaults(suiteName: "wchud-test-\(UUID().uuidString)")!
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, optionalShards: [0: []]
        )
        defer { fixture.cleanup() }
        let key = "wchud.learnedSelfAliases.\(WeChatReader.accountCacheIdentity(fixture.dbDir.path))"
        let now = Date().timeIntervalSince1970
        suite.set([
            "旧昵称": now - WeChatReader.learnedAliasTTL - 3600,
            "新昵称": now - 3600
        ], forKey: key)

        let reader = WeChatReader(
            keysPath: fixture.keysURL.path, dbDir: fixture.dbDir.path,
            cacheStrategy: .memory, persistLearnedAliases: false,
            userDefaults: suite
        )
        XCTAssertFalse(reader.mySelfNames.contains("旧昵称"),
                       "aliases older than the TTL must not hydrate")
        XCTAssertTrue(reader.mySelfNames.contains("新昵称"))
    }

    /// The snippet's mention-stripper must recognize U+2005 — the separator
    /// WeChat emits after a group @-token — and must not strip a bare sender
    /// name with no separator.
    func testSnippetMentionStrippingBoundaries() async throws {
        // "@我 hello" — WeChat terminates the mention with U+2005, which the
        // old separator set missed.
        let stripped = ScanEngine.deduplicateSenderInSnippet(
            "@me\u{2005}hello there", senderName: "peer", myUsername: "me"
        )
        XCTAssertEqual(stripped, "hello there")

        // A body that merely begins with the sender's name is not a
        // "sender:" prefix — the old empty separator ate it.
        let kept = ScanEngine.deduplicateSenderInSnippet(
            "张三来开会了", senderName: "张三"
        )
        XCTAssertEqual(kept, "张三来开会了")

        // Real prefix still strips.
        let prefixed = ScanEngine.deduplicateSenderInSnippet(
            "张三：开会了", senderName: "张三"
        )
        XCTAssertEqual(prefixed, "开会了")
    }
}

// MARK: - Round-2 recall-attribution regressions

extension ScanBacklogPagingTests {

    /// `X 撤回了一条消息` — self-recall: the actor recalled their own
    /// message, so owner must be nil (the actor IS the owner).
    func testRecallerNameSelfRecallHasNoOwner() {
        let r = ScanEngine.recallerName(from: "\"backlog_peer\" 撤回了一条消息")
        XCTAssertEqual(r.actor, "backlog_peer")
        XCTAssertNil(r.owner, "self-recall carries no separate owner")
    }

    /// `X 撤回了"Y"的一条消息` — admin/system recall: the actor removed
    /// someone else's message. The recalled content belongs to Y, not X —
    /// attributing it to X would poison the recall record with the wrong
    /// sender (and, worse, could file an admin's text as a user's message).
    func testRecallerNameAdminRecallExtractsOwner() {
        let r = ScanEngine.recallerName(from: "\"群主\" 撤回了\"小明\"的一条消息")
        XCTAssertEqual(r.actor, "群主")
        XCTAssertEqual(r.owner, "小明")
    }

    /// The 成员 variant of the admin form strips the role prefix too.
    func testRecallerNameAdminRecallMemberPrefix() {
        let r = ScanEngine.recallerName(from: "\"群主\" 撤回了成员\"小红\"的一条消息")
        XCTAssertEqual(r.actor, "群主")
        XCTAssertEqual(r.owner, "小红")
    }

    /// `你撤回了一条消息` — the reader's own self-recall phrasing.
    func testRecallerNameYouSelfRecall() {
        let r = ScanEngine.recallerName(from: "你撤回了一条消息")
        XCTAssertEqual(r.actor, "你")
        XCTAssertNil(r.owner)
    }
}
