import XCTest
@testable import WeChatHUD

/// Regression tests for the duplicate-key crashes and display-name identity
/// bugs the W5 audit found (the audit's line numbers had drifted):
/// - `WeChatReader.bulkMessageStats` / `InsightDataLoader.load` built
///   `Dictionary(uniqueKeysWithValues:)` maps from data that can legally
///   repeat a key; the resulting trap is uncatchable.
/// - `VIPAggregator` stamped a batch id that only had one-second resolution,
///   so two runs in the same second merged into one batch.
/// - `ProactiveAlertEngine`'s burst rule counted by display name, merging
///   different people who share a nickname into one bucket and one dedup slot.
final class W5CrashAndIdentityHardeningTests: XCTestCase {

    // MARK: - B1: WeChatReader.tableToChatMap

    /// Two chats can resolve to the same `Msg_<md5>` table (and the session
    /// table can return one username twice across accounts). This used to
    /// trap the process; it must resolve first-wins instead.
    func testTableToChatMapResolvesDuplicateTableNameFirstWins() {
        let digest = WeChatReader.md5Hex("chat@chatroom")
        let tableName = "Msg_\(digest)"
        let map = WeChatReader.tableToChatMap([
            (chatUsername: "first@chatroom", tableName: tableName),
            (chatUsername: "second@chatroom", tableName: tableName),
        ])
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[tableName], "first@chatroom")
    }

    /// The same username appearing twice (one row per account) is the other
    /// real-world duplicate; it must not trap either.
    func testTableToChatMapResolvesRepeatedUsernameFirstWins() {
        let digest = WeChatReader.md5Hex("wxid_same")
        let pairs = [
            (chatUsername: "wxid_same", tableName: "Msg_\(digest)"),
            (chatUsername: "wxid_same", tableName: "Msg_\(digest)"),
        ]
        let map = WeChatReader.tableToChatMap(pairs)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.values.first, "wxid_same")
    }

    // MARK: - B2: InsightDataLoader lookups

    /// Re-adding a contact can leave the same whitelist id twice in one
    /// snapshot. First entry must win and nothing may trap.
    func testWhitelistLookupResolvesDuplicateIdFirstWins() {
        let first = Self.whitelistEntry(id: "wxid_dup", displayName: "先加的")
        let second = Self.whitelistEntry(id: "wxid_dup", displayName: "后加的")
        let map = InsightDataLoader.whitelistLookup([first, second])
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["wxid_dup"]?.displayName, "先加的")
    }

    /// `SessionTable` returns one row per account, so a username can repeat.
    /// First entry must win and nothing may trap.
    func testSessionLookupResolvesDuplicateUsernameFirstWins() {
        let first = SessionInfo(username: "wxid_dup", isGroup: false, unreadCount: 1, lastTimestamp: 1_000)
        let second = SessionInfo(username: "wxid_dup", isGroup: true, unreadCount: 9, lastTimestamp: 2_000)
        let map = InsightDataLoader.sessionLookup([first, second])
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["wxid_dup"]?.lastTimestamp, 1_000)
        XCTAssertEqual(map["wxid_dup"]?.isGroup, false)
    }

    // MARK: - B3: VIPAggregator.makeBatchID

    /// Two aggregations for the same VIP in the same second must not share
    /// an id, otherwise `markVIPTracesBatched` merges them into one batch.
    func testBatchIDDiffersForTwoRunsAtTheSameInstant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VIPAggregator.makeBatchID(vipUsername: "boss1", now: now)
        let b = VIPAggregator.makeBatchID(vipUsername: "boss1", now: now)
        XCTAssertNotEqual(a, b)
    }

    /// Injecting the nonce makes the id reproducible for fixtures and logs.
    func testBatchIDReproducibleWithInjectedNonceAndNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VIPAggregator.makeBatchID(vipUsername: "boss1", now: now, nonce: "deadbeef")
        let b = VIPAggregator.makeBatchID(vipUsername: "boss1", now: now, nonce: "deadbeef")
        XCTAssertEqual(a, b)
    }

    /// The readable prefix stays: username and epoch must survive, and an
    /// underscore in the username must not make the layout ambiguous.
    func testBatchIDKeepsUsernameAndEpochAndHandlesUnderscoreUsername() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let id = VIPAggregator.makeBatchID(vipUsername: "boss1", now: now, nonce: "abcd1234")
        XCTAssertTrue(id.hasPrefix("batch_"))
        XCTAssertTrue(id.contains("boss1"))
        XCTAssertTrue(id.contains("1700000000"))
        XCTAssertTrue(id.hasSuffix("_abcd1234"))

        let underscored = VIPAggregator.makeBatchID(vipUsername: "wxid_a_b", now: now, nonce: "abcd1234")
        XCTAssertTrue(underscored.contains("wxid_a_b"))
        XCTAssertTrue(underscored.contains("1700000000"))
    }

    // MARK: - B4: burst bucket key + engine behaviour

    /// The username is the identity; the display name is only a label.
    func testBurstBucketKeyPrefersUsernameOverDisplayName() {
        XCTAssertEqual(
            ProactiveAlertEngine.burstBucketKey(senderUsername: "wxid_a", senderName: "小王"),
            "wxid_a"
        )
    }

    /// Rows without a username must still bucket somewhere.
    func testBurstBucketKeyFallsBackToDisplayNameWithoutUsername() {
        XCTAssertEqual(
            ProactiveAlertEngine.burstBucketKey(senderUsername: "", senderName: "小王"),
            "小王"
        )
    }

    /// Two different people who both display as "小王" is not a burst: the
    /// old display-name keying merged 2 + 1 into 3 and fired an alert.
    @MainActor
    func testBurstDoesNotMergeDifferentSendersSharingDisplayName() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
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
                makeUnread(chatUsername: "chat-a1", senderUsername: "username-a", senderName: "小王"),
                makeUnread(chatUsername: "chat-a2", senderUsername: "username-a", senderName: "小王"),
                makeUnread(chatUsername: "chat-b1", senderUsername: "username-b", senderName: "小王"),
            ],
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()
        XCTAssertTrue(sent.isEmpty, "2 + 1 from two different people is not a burst")
    }

    /// Three real messages from one person still alert, keyed by username
    /// (distinct dedup slot) while the body stays human-readable.
    @MainActor
    func testBurstFromOneUsernameAlertsOnceWithNameInBody() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
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
            unreadItems: (0..<3).map { i in
                makeUnread(chatUsername: "chat-\(i)", senderUsername: "username-a", senderName: "小王")
            },
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.title, "连续消息")
        XCTAssertEqual(received.first?.identifier, "burst-username-a")
        XCTAssertEqual(received.first?.body, "小王 连续发了 3 条消息")
    }

    /// System/unread rows arrive without a username; the display name must
    /// still bucket them and drive the dedup identifier.
    @MainActor
    func testBurstFallsBackToDisplayNameWhenUsernameIsEmpty() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
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
            unreadItems: (0..<3).map { i in
                makeUnread(chatUsername: "sys-\(i)", senderUsername: "", senderName: "系统通知")
            },
            replyDebtItems: [], commitments: [], recentNotifications: []
        )
        await Task.yield()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.identifier, "burst-系统通知")
        XCTAssertEqual(received.first?.body, "系统通知 连续发了 3 条消息")
    }

    // MARK: - Fixtures

    private static func whitelistEntry(id: String, displayName: String) -> WhitelistEntry {
        WhitelistEntry(
            id: id,
            displayName: displayName,
            isGroup: false,
            category: .work,
            attentionLevel: .watch,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoSuggested: false
        )
    }

    private func makeUnread(
        chatUsername: String = "chat1",
        senderUsername: String = "wxid_sender",
        senderName: String = "Alice",
        isVIP: Bool = false,
        minutesAgo: Int = 5
    ) -> UnreadItem {
        UnreadItem(
            chatUsername: chatUsername,
            chatName: chatUsername,
            senderUsername: senderUsername,
            senderName: senderName,
            preview: "hello",
            timestamp: Date(timeIntervalSinceNow: -Double(minutesAgo * 60)),
            kind: .privateChat,
            isWhitelisted: true,
            isVIP: isVIP,
            replied: false,
            status: .pending,
            isIgnored: false
        )
    }

}
