import XCTest
import SQLite3
import CryptoKit
import CommonCrypto
@testable import WeChatHUD

final class ScanClassificationDeliveryTests: XCTestCase {
    private let chatUsername = "synthetic_peer"

    func testScanEnqueuesInboundBeforeCursorAndRepeatScanIsIdempotent() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)

        let first = try await scan(fixture.reader, store: store)
        XCTAssertEqual(first?.newInboundForClassifier.count, 1)
        XCTAssertTrue(first?.newInboundForClassifier.first?.msg.id.hasSuffix("/1") == true)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(try store.discussionQueueCount(), 1)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastCreateTime, 1_000)

        let second = try await scan(fixture.reader, store: store)
        XCTAssertTrue(second?.newInboundForClassifier.isEmpty == true)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(try store.discussionQueueCount(), 1)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastLocalId, 1)
    }

    func testQueueWriteFailureLeavesCursorUnchangedAndRetryPersistsIt() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)
        try exec(store, """
            CREATE TRIGGER block_classification_insert
            BEFORE INSERT ON classification_queue
            BEGIN SELECT RAISE(ABORT, 'classification queue blocked'); END;
        """)

        _ = try await scan(fixture.reader, store: store)
        XCTAssertEqual(store.classificationQueueCount(), 0)
        XCTAssertEqual(try store.discussionQueueCount(), 0)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastCreateTime, 100)
        // HUDStore normalizes a zero local-id baseline to Int.max so all
        // messages at the baseline timestamp are treated as already seen.
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastLocalId, Int.max)

        try exec(store, "DROP TRIGGER block_classification_insert")
        _ = try await scan(fixture.reader, store: store)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(try store.discussionQueueCount(), 1)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastCreateTime, 1_000)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastLocalId, 1)
    }

    func testAutopilotQueueFailureLeavesWhitelistAndPrivateCursorsUnchanged() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)
        try store.upsertContact(
            username: fixture.autopilotChatUsername,
            displayName: "自动驾驶同事",
            attentionLevel: .whitelist,
            role: .colleague
        )
        try store.setAutopilotCursor(
            username: fixture.autopilotChatUsername,
            lastCreateTime: 100,
            lastLocalId: 7
        )
        try exec(store, """
            CREATE TRIGGER block_autopilot_insert
            BEFORE INSERT ON autopilot_inbound_queue
            BEGIN SELECT RAISE(ABORT, 'autopilot queue blocked'); END;
        """)

        _ = try await scan(fixture.reader, store: store, autopilotActive: true)
        XCTAssertEqual(store.loadPendingAutopilotInbound().count, 0)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastCreateTime, 100)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastLocalId, Int.max)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastCreateTime, 100)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastLocalId, 7)
        XCTAssertEqual(store.classificationQueueCount(), 0)
        XCTAssertEqual(try store.discussionQueueCount(), 0)

        try exec(store, "DROP TRIGGER block_autopilot_insert")
        _ = try await scan(fixture.reader, store: store, autopilotActive: true)
        XCTAssertEqual(store.loadPendingAutopilotInbound().count, 2)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastCreateTime, 1_000)
        XCTAssertEqual(store.getWhitelistCursor(username: chatUsername)?.lastLocalId, 1)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastCreateTime, 1_000)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastLocalId, 1)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(try store.discussionQueueCount(), 1)
    }

    func testLatestPreviewKeepsOlderAllowedGroupMentionWhenNewerPrivateInfoIsDisabled() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.addToWhitelist(
            username: fixture.groupChatUsername,
            displayName: "项目群",
            isGroup: true,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)
        try store.setWhitelistCursor(username: fixture.groupChatUsername, lastCreateTime: 100, lastLocalId: 0)

        let outcome = try await scan(fixture.reader, store: store)
        XCTAssertEqual(outcome?.latestPreview?.chatUsername, fixture.groupChatUsername)
        XCTAssertEqual(outcome?.latestPreview?.kind, .groupAt)
        XCTAssertTrue(outcome?.latestPreview?.isAtMention == true)
        // The "@me" prefix is redundant next to the banner headline that
        // already says "@ 了你" — the snippet starts at the real content.
        XCTAssertEqual(outcome?.latestPreview?.snippet, "请确认")
    }

    func testFollowedGroupQueuesMentionsButNotOrdinaryChatter() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: fixture.groupChatUsername,
            displayName: "项目群",
            isGroup: true,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: fixture.groupChatUsername, lastCreateTime: 100, lastLocalId: 0)

        let outcome = try await scan(fixture.reader, store: store)
        XCTAssertEqual(outcome?.newInboundForClassifier.count, 1)
        XCTAssertTrue(outcome?.newInboundForClassifier.first?.msg.text.contains("@") == true)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(try store.discussionQueueCount(), 1)
        XCTAssertEqual(outcome?.latestPreview?.kind, .groupAt)
    }

    func testLatestPreviewUsesOrdinaryPrivateMessageWhenEnabled() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        var config = NotificationConfig()
        config.allWhitelist = true
        try store.setSettingJSON("notification", value: config)
        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)

        let outcome = try await scan(fixture.reader, store: store)
        XCTAssertEqual(outcome?.latestPreview?.chatUsername, chatUsername)
        XCTAssertEqual(outcome?.latestPreview?.kind, .privateChat)
    }

    func testEmptyWhitelistStillQueuesKnownAutopilotPrivateChat() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.upsertContact(
            username: fixture.autopilotChatUsername,
            displayName: "自动驾驶同事",
            attentionLevel: .whitelist,
            role: .colleague
        )
        try store.setAutopilotCursor(
            username: fixture.autopilotChatUsername,
            lastCreateTime: 100,
            lastLocalId: 7
        )

        let outcome = try await scan(fixture.reader, store: store, autopilotActive: true)
        XCTAssertEqual(outcome?.newInboundMessages.count, 1)
        XCTAssertEqual(store.loadPendingAutopilotInbound().count, 1)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastCreateTime, 1_000)
        XCTAssertEqual(store.getAutopilotCursor(username: fixture.autopilotChatUsername)?.lastLocalId, 1)
    }

    func testGreylistPrivateChatIsNotQueuedForAutopilot() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.upsertContact(
            username: fixture.autopilotChatUsername,
            displayName: "仅保留资料同事",
            attentionLevel: .greylist,
            role: .acquaintance
        )
        try store.setAutopilotCursor(
            username: fixture.autopilotChatUsername,
            lastCreateTime: 100,
            lastLocalId: 7
        )

        let outcome = try await scan(fixture.reader, store: store, autopilotActive: true)
        XCTAssertEqual(outcome?.newInboundMessages.count ?? 0, 0)
        XCTAssertEqual(store.loadPendingAutopilotInbound().count, 0)
    }

    /// You replied after the inbound arrived → the banner must not pop;
    /// the message still lands in the recent-notifications feed.
    func testInboundNewerThanYourReplyDoesNotPopBanner() async throws {
        let fixture = try SyntheticScanFixture(chatUsername: chatUsername, selfReplyAt: 1_050)
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        var config = NotificationConfig()
        config.allWhitelist = true
        try store.setSettingJSON("notification", value: config)
        try store.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chatUsername, lastCreateTime: 100, lastLocalId: 0)

        let outcome = try await scan(fixture.reader, store: store)
        XCTAssertNil(outcome?.latestPreview, "already-answered inbound must not pop the banner")
        XCTAssertEqual(
            outcome?.recentNotifications.first(where: { $0.chatUsername == chatUsername })?.kind,
            .privateChat,
            "the message should still be recorded in the inbox feed"
        )
    }

    /// You sent a message seconds ago and the other side answers right
    /// back — that is a live exchange, not a new ask. Suppress the popup;
    /// a stale exchange (reply older than the window) still pops.
    func testLiveExchangeSuppressesBannerButStaleExchangeDoesNot() async throws {
        let now = Int(Date().timeIntervalSince1970)

        let live = try SyntheticScanFixture(
            chatUsername: chatUsername,
            selfReplyAt: now - 30,
            inboundAt: now - 5
        )
        defer { live.cleanup() }
        let liveStore = try live.makeStore()
        defer { liveStore.close() }
        var config = NotificationConfig()
        config.allWhitelist = true
        try liveStore.setSettingJSON("notification", value: config)
        try liveStore.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try liveStore.setWhitelistCursor(username: chatUsername, lastCreateTime: now - 600, lastLocalId: 0)

        let liveOutcome = try await scan(live.reader, store: liveStore)
        XCTAssertNil(liveOutcome?.latestPreview, "replies inside a live exchange must not re-pop")
        XCTAssertNotNil(
            liveOutcome?.recentNotifications.first(where: { $0.chatUsername == chatUsername }),
            "live-exchange replies still belong in the feed"
        )

        let stale = try SyntheticScanFixture(
            chatUsername: chatUsername,
            selfReplyAt: now - ScanEngine.activeConversationWindow - 60,
            inboundAt: now - 5
        )
        defer { stale.cleanup() }
        let staleStore = try stale.makeStore()
        defer { staleStore.close() }
        try staleStore.setSettingJSON("notification", value: config)
        try staleStore.addToWhitelist(
            username: chatUsername,
            displayName: "合成同事",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try staleStore.setWhitelistCursor(username: chatUsername, lastCreateTime: now - 600, lastLocalId: 0)

        let staleOutcome = try await scan(stale.reader, store: staleStore)
        XCTAssertEqual(
            staleOutcome?.latestPreview?.chatUsername, chatUsername,
            "a reply older than the conversation window must not suppress the banner"
        )
    }

    private func scan(
        _ reader: WeChatReader,
        store: HUDStore,
        autopilotActive: Bool = false
    ) async throws -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: [],
            recentLimit: 10,
            autopilotActive: autopilotActive
        )
    }

    private func exec(_ store: HUDStore, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(store.rawDB, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard result == SQLITE_OK else {
            throw NSError(domain: "ScanClassificationDeliveryTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "sqlite error"
            ])
        }
    }
}

private final class SyntheticScanFixture {
    let root: URL
    let dbDir: URL
    let keysURL: URL
    let reader: WeChatReader
    let autopilotChatUsername = "autopilot_peer"
    let groupChatUsername = "team@chatroom"
    private let key = Data(repeating: 0x44, count: 32)

    /// `selfReplyAt`: when set, appends a self-authored message (sender =
    /// `synthetic_account`, the fixture's `myUsername()`) to the private
    /// chat at that createTime — used to exercise banner suppression when
    /// the user already replied or is mid-conversation.
    /// `inboundAt`: overrides the private-chat inbound's createTime so
    /// "live exchange" tests can use wall-clock-relative timestamps.
    init(chatUsername: String, selfReplyAt: Int? = nil, inboundAt: Int = 1_000) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-classification-\(UUID().uuidString)")
        dbDir = root.appendingPathComponent("synthetic_account/db_storage", isDirectory: true)
        keysURL = root.appendingPathComponent("keys.json")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let plain = root.appendingPathComponent("message.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(plain.path, &db) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var reserve: Int32 = 80
        guard sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 2)
        }
        let table = "Msg_" + Self.md5Hex(chatUsername)
        let schema = """
            PRAGMA page_size=4096;
            VACUUM;
            CREATE TABLE Name2Id(user_name TEXT);
            CREATE TABLE [\(table)] (
                local_id INTEGER PRIMARY KEY,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                message_content TEXT,
                WCDB_CT_message_content INTEGER
            );
            CREATE TABLE [\(Self.messageTable(for: autopilotChatUsername))] (
                local_id INTEGER PRIMARY KEY,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                message_content TEXT,
                WCDB_CT_message_content INTEGER
            );
            CREATE TABLE [\(Self.messageTable(for: groupChatUsername))] (
                local_id INTEGER PRIMARY KEY,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                message_content TEXT,
                WCDB_CT_message_content INTEGER
            );
            INSERT INTO Name2Id(user_name) VALUES ('\(chatUsername)');
            INSERT INTO Name2Id(user_name) VALUES ('\(autopilotChatUsername)');
            INSERT INTO Name2Id(user_name) VALUES ('group_sender');
            INSERT INTO Name2Id(user_name) VALUES ('synthetic_account');
            INSERT INTO [\(table)] VALUES (1, 1, \(inboundAt), 1, '请确认方案', 0);
            INSERT INTO [\(Self.messageTable(for: autopilotChatUsername))] VALUES (1, 1, 1000, 2, '自动驾驶请跟进', 0);
            INSERT INTO [\(Self.messageTable(for: groupChatUsername))] VALUES (1, 1, 900, 3, '@synthetic_account 请确认', 0);
            INSERT INTO [\(Self.messageTable(for: groupChatUsername))] VALUES (2, 1, 910, 3, '今晚聚餐随便吃', 0);
            \(selfReplyAt.map { "INSERT INTO [\(table)] VALUES (2, 1, \($0), 4, '收到', 0);" } ?? "")
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 3)
        }

        let encrypted = dbDir.appendingPathComponent("message/message_0.db")
        try FileManager.default.createDirectory(at: encrypted.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sessionPlain = root.appendingPathComponent("session.sqlite")
        var sessionDB: OpaquePointer?
        guard sqlite3_open(sessionPlain.path, &sessionDB) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 4)
        }
        defer { sqlite3_close(sessionDB) }
        var sessionReserve: Int32 = 80
        guard sqlite3_file_control(sessionDB, nil, SQLITE_FCNTL_RESERVE_BYTES, &sessionReserve) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 5)
        }
        let sessionSchema = """
            PRAGMA page_size=4096;
            VACUUM;
            CREATE TABLE SessionTable (
                username TEXT,
                unread_count INTEGER,
                last_timestamp INTEGER
            );
            INSERT INTO SessionTable VALUES ('\(autopilotChatUsername)', 1, 1000);
            INSERT INTO SessionTable VALUES ('\(groupChatUsername)', 2, 910);
            """
        guard sqlite3_exec(sessionDB, sessionSchema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticScanFixture", code: 6)
        }

        let sessionEncrypted = dbDir.appendingPathComponent("session/session.db")
        try FileManager.default.createDirectory(at: sessionEncrypted.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encodedKey = key.map { String(format: "%02x", $0) }.joined()
        let keyJSON = [
            "message/message_0.db": ["enc_key": encodedKey],
            "session/session.db": ["enc_key": encodedKey]
        ]
        try JSONSerialization.data(withJSONObject: keyJSON).write(to: keysURL)
        try Self.encrypt(plain, to: encrypted, key: key)
        try Self.encrypt(sessionPlain, to: sessionEncrypted, key: key)
        reader = WeChatReader(keysPath: keysURL.path, dbDir: dbDir.path, cacheStrategy: .memory)
    }

    func makeStore() throws -> HUDStore {
        let store = HUDStore(dbPath: root.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func messageTable(for username: String) -> String {
        "Msg_" + md5Hex(username)
    }

    private static func encrypt(_ plain: URL, to encrypted: URL, key: Data) throws {
        let data = try Data(contentsOf: plain)
        var output = Data()
        let iv = Data(repeating: 0x22, count: 16)
        for start in stride(from: 0, to: data.count, by: 4096) {
            let first = start == 0
            let bytes = data.subdata(in: start + (first ? 16 : 0)..<start + 4016)
            var cipher = Data(count: bytes.count)
            var written = 0
            let status = cipher.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    key.withUnsafeBytes { keyBytes in
                        iv.withUnsafeBytes { vector in
                            CCCrypt(
                                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, 32, vector.baseAddress,
                                source.baseAddress, bytes.count,
                                destination.baseAddress, bytes.count, &written
                            )
                        }
                    }
                }
            }
            XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
            if first { output += Data(repeating: 0x11, count: 16) }
            output += cipher + iv + Data(count: 64)
        }
        try output.write(to: encrypted, options: .atomic)
    }
}
