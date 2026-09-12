import XCTest
import SQLite3
@testable import WeChatHUD

/// The autopilot pass in `ScanEngine.performScan` used to call
/// `reader.getSessions()` a second time and `store.getContact` once per
/// candidate message. It now reuses the session snapshot read at the top of the
/// scan and the scan-start contact snapshot.
///
/// Evidence here: the scan reads session.db once, the pass issues zero
/// per-message contact queries, and the queue + cursor results are identical to
/// a verbatim copy of the previous implementation run against identically
/// seeded state.
final class ScanEngineContactReusePerfTests: XCTestCase {
    private let myUsername = "synthetic_account"
    private let messageDB = "message/message_0.db"

    private enum Chats {
        static let vip = "wxid_vip"
        static let follow = "wxid_follow"
        static let greylist = "wxid_greylist"
        static let stranger = "wxid_stranger"
        static let seedMe = "wxid_seedme"
        static let whitelisted = "wxid_whitelisted"
        static let group = "room_team@chatroom"
    }

    // MARK: Cost + equivalence

    func testAutopilotPassCostDoesNotScaleWithMessageCount() async throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        let readers = try makeCostFixture(fixture)
        let reader = readers.reader
        let store = try fixture.makeStore()
        defer { store.close() }
        try seed(store)

        let recorder = SQLStatementRecorder()
        recorder.attach(to: store.rawDB)
        defer { recorder.detach(from: store.rawDB) }

        let scanned = try await scan(reader, store: store, autopilotActive: true)
        let outcome = try XCTUnwrap(scanned)

        // (a) One session read for the whole scan. The previous shape read the
        // table a second time from the autopilot pass.
        XCTAssertEqual(reader.sessionQueryCount, 1, "the scan must read session.db exactly once")

        // (b) Contacts are loaded in one batch; the pass adds no per-message
        // query. (The whitelist reply-debt path is the only other contact
        // reader in a scan; this fixture keeps whitelist chats message-free so
        // the count below is entirely the autopilot pass's doing.)
        XCTAssertEqual(recorder.count(containing: "FROM contacts"), 1, "expected one batch contact load")
        XCTAssertEqual(
            recorder.count(containingAll: ["FROM contacts", "WHERE username=?"]), 0,
            "the autopilot pass queried contacts once per message"
        )

        // The queue holds exactly the eligible new messages: VIP + whitelisted
        // contacts, self-authored and rejected levels dropped, and the chat
        // without a baseline only seeded.
        let queued = store.loadPendingAutopilotInbound()
        XCTAssertEqual(queued.map(\.text), ["新消息一", "新消息二", "关注消息"])
        XCTAssertEqual(Set(outcome.newInboundMessages.map(\.msgUID)), Set(queued.map(\.msgUID)))
        XCTAssertEqual(store.getAutopilotCursor(username: Chats.vip)?.lastCreateTime, 5_200)
        XCTAssertEqual(store.getAutopilotCursor(username: Chats.seedMe)?.lastCreateTime, 7_000)
        XCTAssertNil(store.getAutopilotCursor(username: Chats.whitelisted))

        // Reference run: previous implementation, same seed, separate store.
        let legacyStore = try fixture.makeStore(name: "hud-legacy")
        defer { legacyStore.close() }
        try seed(legacyStore)
        let legacyRecorder = SQLStatementRecorder()
        legacyRecorder.attach(to: legacyStore.rawDB)
        defer { legacyRecorder.detach(from: legacyStore.rawDB) }

        let sessionsBefore = reader.sessionQueryCount
        let legacy = legacyAutopilotPass(reader: reader, store: legacyStore)
        XCTAssertEqual(reader.sessionQueryCount, sessionsBefore + 1, "the old shape read session.db again")

        // Five candidate messages reach the per-message lookup: 2 in the VIP
        // chat (the third new row is self-authored), 1 关注, 1 仅记录-级别,
        // 1 stranger with no contact row. Three of them clear the attention
        // filter; all five used to cost a SQL round trip.
        XCTAssertEqual(recorder.count(containingAll: ["FROM contacts", "WHERE username=?"]), 0)
        XCTAssertEqual(
            legacyRecorder.count(containingAll: ["FROM contacts", "WHERE username=?"]), 5,
            "the reference pass must show the per-message query cost it replaces"
        )

        // Equivalence: same inbound set, same queue, same cursors.
        XCTAssertEqual(Set(legacy.inbound.map(\.msgUID)), Set(outcome.newInboundMessages.map(\.msgUID)))
        let legacyQueued = legacyStore.loadPendingAutopilotInbound()
        XCTAssertEqual(legacyQueued.map(\.text), queued.map(\.text))
        for username in [Chats.vip, Chats.follow, Chats.greylist, Chats.stranger, Chats.seedMe, Chats.whitelisted] {
            XCTAssertEqual(
                store.getAutopilotCursor(username: username)?.lastCreateTime,
                legacyStore.getAutopilotCursor(username: username)?.lastCreateTime,
                "cursor diverged for \(username)"
            )
            XCTAssertEqual(
                store.getAutopilotCursor(username: username)?.lastLocalId,
                legacyStore.getAutopilotCursor(username: username)?.lastLocalId,
                "cursor local id diverged for \(username)"
            )
        }
    }

    func testSecondScanRequeueNothingAndKeepsCursorsStable() async throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        let reader = try makeCostFixture(fixture).reader
        let store = try fixture.makeStore()
        defer { store.close() }
        try seed(store)

        let firstScan = try await scan(reader, store: store, autopilotActive: true)
        let first = try XCTUnwrap(firstScan)
        XCTAssertFalse(first.newInboundMessages.isEmpty)
        let queuedAfterFirst = store.loadPendingAutopilotInbound()

        let secondScan = try await scan(reader, store: store, autopilotActive: true)
        let second = try XCTUnwrap(secondScan)
        XCTAssertTrue(second.newInboundMessages.isEmpty, "an unchanged corpus must not re-queue anything")
        XCTAssertEqual(store.loadPendingAutopilotInbound().map(\.msgUID), queuedAfterFirst.map(\.msgUID))
        XCTAssertEqual(reader.sessionQueryCount, 2, "one session read per scan, not two")
    }

    // MARK: Guards preserved by the reused snapshot

    func testWhitelistAndGroupChatsStayOutOfTheAutopilotPass() async throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        try fixture.createMessageDB(
            relPath: messageDB,
            chats: [
                Chats.whitelisted: [.init(localId: 1, createTime: 4_000, senderId: 1, text: "白名单消息")],
                Chats.group: [
                    .init(localId: 1, createTime: 4_100, senderId: 2, text: "@synthetic_account 请确认"),
                    .init(localId: 2, createTime: 4_200, senderId: 2, text: "今晚聚餐随便吃"),
                ],
                Chats.vip: [.init(localId: 1, createTime: 5_000, senderId: 3, text: "VIP 消息")],
            ],
            name2id: [Chats.whitelisted, "room_sender", Chats.vip]
        )
        try fixture.createSessionDB(rows: [
            .init(username: Chats.whitelisted, unreadCount: 2, lastTimestamp: 4_000),
            .init(username: Chats.group, unreadCount: 2, lastTimestamp: 4_200),
            .init(username: Chats.vip, unreadCount: 1, lastTimestamp: 5_000),
        ])
        let reader = try fixture.makeReader(cacheStrategy: .memory)
        let store = try fixture.makeStore()
        defer { store.close() }
        try store.addToWhitelist(username: Chats.whitelisted, displayName: "白名单同事",
                                isGroup: false, category: .work, attentionLevel: .watch)
        try store.upsertContact(username: Chats.vip, displayName: "重要客户",
                                attentionLevel: .vip, role: .client)
        try store.setAutopilotCursor(username: Chats.vip, lastCreateTime: 100, lastLocalId: 0)

        let scanned = try await scan(reader, store: store, autopilotActive: true)
        let outcome = try XCTUnwrap(scanned)

        XCTAssertEqual(store.loadPendingAutopilotInbound().map(\.text), ["VIP 消息"])
        XCTAssertNil(store.getAutopilotCursor(username: Chats.whitelisted),
                     "the whitelist chat must not be baselined by the autopilot pass")
        XCTAssertNil(store.getAutopilotCursor(username: Chats.group),
                     "group chats must not be baselined by the autopilot pass")
        XCTAssertFalse(outcome.newInboundMessages.contains { $0.chatUsername == Chats.whitelisted || $0.chatUsername == Chats.group })
    }

    // MARK: Fixture

    private struct Prepared {
        let reader: WeChatReader
    }

    /// Private, non-whitelisted chats only: the whitelist path stays
    /// message-free so SQL counts below are attributable to the autopilot pass.
    private func makeCostFixture(_ fixture: WeChatReaderPerfFixture) throws -> Prepared {
        let senders = [Chats.vip, Chats.follow, Chats.greylist, Chats.stranger, Chats.seedMe, myUsername]
        try fixture.createMessageDB(
            relPath: messageDB,
            chats: [
                Chats.vip: [
                    .init(localId: 1, createTime: 900, senderId: 1, text: "旧消息"),
                    .init(localId: 2, createTime: 5_000, senderId: 1, text: "新消息一"),
                    .init(localId: 3, createTime: 5_100, senderId: 6, text: "我自己发的"),
                    .init(localId: 4, createTime: 5_200, senderId: 1, text: "新消息二"),
                ],
                Chats.follow: [.init(localId: 1, createTime: 6_000, senderId: 2, text: "关注消息")],
                Chats.greylist: [.init(localId: 1, createTime: 6_100, senderId: 3, text: "仅记录消息")],
                Chats.stranger: [.init(localId: 1, createTime: 6_200, senderId: 4, text: "陌生人消息")],
                Chats.seedMe: [.init(localId: 1, createTime: 7_000, senderId: 5, text: "种子消息")],
            ],
            name2id: senders
        )
        try fixture.createSessionDB(rows: [
            .init(username: Chats.vip, unreadCount: 3, lastTimestamp: 5_200),
            .init(username: Chats.follow, unreadCount: 1, lastTimestamp: 6_000),
            .init(username: Chats.greylist, unreadCount: 1, lastTimestamp: 6_100),
            .init(username: Chats.stranger, unreadCount: 1, lastTimestamp: 6_200),
            .init(username: Chats.seedMe, unreadCount: 1, lastTimestamp: 7_000),
            .init(username: Chats.whitelisted, unreadCount: 0, lastTimestamp: 0),
        ])
        return Prepared(reader: try fixture.makeReader(cacheStrategy: .memory))
    }

    private func seed(_ store: HUDStore) throws {
        try store.addToWhitelist(username: Chats.whitelisted, displayName: "白名单同事",
                                 isGroup: false, category: .work, attentionLevel: .watch)
        try store.upsertContact(username: Chats.vip, displayName: "重要客户",
                                attentionLevel: .vip, role: .client)
        try store.upsertContact(username: Chats.follow, displayName: "关注的人",
                                attentionLevel: .whitelist, role: .colleague)
        try store.upsertContact(username: Chats.greylist, displayName: "仅保留资料",
                                attentionLevel: .greylist, role: .acquaintance)
        // `Chats.stranger` deliberately has no contact row.
        try store.setAutopilotCursor(username: Chats.vip, lastCreateTime: 900, lastLocalId: 1)
        for username in [Chats.follow, Chats.greylist, Chats.stranger] {
            try store.setAutopilotCursor(username: username, lastCreateTime: 100, lastLocalId: 0)
        }
        // `Chats.seedMe` intentionally has no baseline: the pass must seed and
        // move on without queueing.
    }

    private func scan(_ reader: WeChatReader, store: HUDStore,
                      autopilotActive: Bool) async throws -> ScanEngine.ScanOutcome? {
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

    // MARK: Reference implementation (previous autopilot pass, verbatim)

    private struct LegacyPassResult {
        var inbound: [AutopilotService.InboundMessage] = []
    }

    private func legacyAutopilotPass(reader: WeChatReader, store: HUDStore) -> LegacyPassResult {
        var result = LegacyPassResult()
        let whitelistUsernames = Set(store.getWhitelist().map(\.id))
        let myUname = reader.myUsername()
        let myDisplayName = reader.displayName(for: myUname)
        let selfNames = reader.mySelfNames
        if let allSessions = try? reader.getSessions() {
            for session in allSessions {
                guard !session.username.contains("@chatroom"),
                      !whitelistUsernames.contains(session.username),
                      session.unreadCount > 0 else { continue }

                let messages: [MessageInfo]
                do {
                    messages = try reader.getMessages(chatUsername: session.username, limit: 20, sinceLocalId: nil)
                } catch { continue }

                guard let baseline = store.getAutopilotCursor(username: session.username) else {
                    let seed = messages.first.map { ($0.createTime, $0.localId) }
                        ?? (Int(Date().timeIntervalSince1970), 0)
                    try? store.setAutopilotCursor(username: session.username,
                                                  lastCreateTime: seed.0, lastLocalId: seed.1)
                    continue
                }

                let newMessages = messages.filter {
                    $0.createTime > baseline.lastCreateTime
                        || ($0.createTime == baseline.lastCreateTime && $0.localId > baseline.lastLocalId)
                }
                var queued: [AutopilotService.InboundMessage] = []
                for msg in newMessages {
                    if MessageHelpers.isFromSelf(msg, chatUsername: session.username, myUsername: myUname,
                                                 myDisplayName: myDisplayName, mySelfNames: selfNames) { continue }
                    guard let contact = store.getContact(username: msg.senderUsername) else { continue }
                    guard contact.attentionLevel == .vip || contact.attentionLevel == .whitelist else { continue }
                    let inbound = AutopilotService.InboundMessage(
                        msgUID: msg.id,
                        chatUsername: msg.chatUsername,
                        chatName: msg.chatName,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        text: msg.text,
                        isGroup: false,
                        isAtMention: false,
                        attentionLevel: contact.attentionLevel,
                        contactRole: contact.role,
                        timestamp: msg.createTime,
                        messageType: msg.baseType,
                        appType: msg.appType
                    )
                    queued.append(inbound)
                    result.inbound.append(inbound)
                }

                if let newest = newMessages.first,
                   newest.createTime > baseline.lastCreateTime
                   || (newest.createTime == baseline.lastCreateTime && newest.localId > baseline.lastLocalId) {
                    try? store.withTransaction {
                        for inbound in queued { try store.enqueueAutopilotInbound(inbound) }
                        try store.setAutopilotCursor(username: session.username,
                                                     lastCreateTime: newest.createTime,
                                                     lastLocalId: newest.localId)
                    }
                }
            }
        }
        return result
    }
}

/// Counts SQL statements executed on a `HUDStore` connection.
///
/// `HUDStore` is a concrete type, so tests cannot substitute a counting store.
/// Attaching SQLite's statement trace to the store's own connection measures the
/// real SQL traffic instead, with no change to `HUDStore` or `ScanEngine`.
private final class SQLStatementRecorder {
    private let lock = NSLock()
    private var statements: [String] = []
    private var context: UnsafeMutableRawPointer?

    func attach(to db: OpaquePointer?) {
        let pointer = Unmanaged.passRetained(self).toOpaque()
        context = pointer
        _ = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, statement, expanded in
            guard let context else { return 0 }
            let recorder = Unmanaged<SQLStatementRecorder>.fromOpaque(context).takeUnretainedValue()
            if let expanded {
                recorder.record(String(cString: expanded.assumingMemoryBound(to: CChar.self)))
            } else if let statement, let sql = sqlite3_sql(OpaquePointer(statement)) {
                recorder.record(String(cString: sql))
            }
            return 0
        }, pointer)
    }

    func detach(from db: OpaquePointer?) {
        _ = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), nil, nil)
        if let context {
            Unmanaged<SQLStatementRecorder>.fromOpaque(context).release()
            self.context = nil
        }
    }

    func count(containing needle: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return statements.filter { $0.contains(needle) }.count
    }

    func count(containingAll needles: [String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return statements.filter { statement in needles.allSatisfy { statement.contains($0) } }.count
    }

    private func record(_ sql: String) {
        lock.lock()
        statements.append(sql)
        lock.unlock()
    }
}
