import XCTest
import SQLite3
@testable import WeChatHUD

final class InboxActionPersistenceTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (HUDStore, ChatMonitor, InboxItem, String) {
        let root = NSTemporaryDirectory() + "inbox-action-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(keysPath: root + "/absent-keys.json", dbDir: root + "/synthetic/db_storage", cacheStrategy: .memory)
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        let debt = ReplyDebtItem(id: "synthetic-peer", chatUsername: "synthetic-peer", chatName: "合成同事", senderName: "同事",
            preview: "请确认合成测试事项", latestOutboundPreview: nil, timestamp: Date(timeIntervalSince1970: 1700000000),
            priority: .p1, score: 6, unreadCount: 1, isGroup: false, isWhitelisted: true, isVIP: false,
            isAtMention: false, inboundCountSinceLastOutbound: 1, reasons: [], suggestedReplyMinutes: 30)
        monitor.replyDebtItems = [debt]
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: [:])
        monitor.inboxItems = items
        return (store, monitor, try XCTUnwrap(items.first), root)
    }

    private func cleanup(_ store: HUDStore, _ root: String) {
        store.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func execute(_ sql: String, on store: HUDStore) {
        XCTAssertEqual(sqlite3_exec(store.rawDB, sql, nil, nil, nil), SQLITE_OK)
    }

    @MainActor
    func testClosedStoreCannotDismissSnoozeOrSilenceVisibleMessage() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }
        store.close()
        XCTAssertFalse(monitor.dismissInboxItem(item))
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
        XCTAssertFalse(monitor.snoozeInboxItem(item, until: Date().addingTimeInterval(3600)))
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
        XCTAssertFalse(monitor.silenceInboxItem(item))
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
        XCTAssertNotNil(monitor.inboxActionError)
        try store.open()
        XCTAssertTrue(store.loadChatActions().isEmpty)
    }

    @MainActor
    func testSQLAbortDoesNotMutateUIAndSuccessfulRetryClearsError() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }
        execute("CREATE TRIGGER reject_action AFTER INSERT ON chat_actions BEGIN SELECT RAISE(ABORT, 'PRIVATE_TRIGGER_DETAIL'); END", on: store)
        XCTAssertFalse(monitor.dismissInboxItem(item))
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
        XCTAssertTrue(store.loadChatActions().isEmpty)
        XCTAssertFalse(monitor.inboxActionError?.contains("PRIVATE_TRIGGER_DETAIL") ?? true)
        execute("DROP TRIGGER reject_action", on: store)
        XCTAssertTrue(monitor.dismissInboxItem(item))
        XCTAssertTrue(monitor.inboxItems.isEmpty)
        XCTAssertEqual(monitor.handledItems.map(\.id), [item.id])
        XCTAssertEqual(store.loadChatActions()[item.chatUsername]?.silencedAt, 1700000000)
        XCTAssertNil(monitor.inboxActionError)
    }

    @MainActor
    func testRestoreAndUnsilenceKeepHandledStateWhenDeleteFails() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }
        XCTAssertTrue(monitor.silenceInboxItem(item))
        let storedWatermark = store.loadChatActions()[item.chatUsername]?.silencedAt
        execute("CREATE TRIGGER reject_restore BEFORE DELETE ON chat_actions BEGIN SELECT RAISE(ABORT, 'blocked'); END", on: store)
        XCTAssertFalse(monitor.restoreInboxItem(item))
        XCTAssertFalse(monitor.unsilenceInboxItem(item))
        XCTAssertTrue(monitor.inboxItems.isEmpty)
        XCTAssertEqual(monitor.handledItems.map(\.id), [item.id])
        XCTAssertEqual(monitor.handledItems.first?.status, .silenced)
        XCTAssertEqual(store.loadChatActions()[item.chatUsername]?.silencedAt, storedWatermark)
        execute("DROP TRIGGER reject_restore", on: store)
        XCTAssertTrue(monitor.unsilenceInboxItem(item))
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
        XCTAssertTrue(store.loadChatActions().isEmpty)
        XCTAssertNil(monitor.inboxActionError)
    }

    @MainActor
    func testFailedBlockRuleDoesNotHideMessageAndFailedRestoreKeepsRule() throws {
        let (store, monitor, _, root) = try fixture()
        defer { cleanup(store, root) }
        let unread = UnreadItem(chatUsername: "synthetic-peer", chatName: "测试",
            senderUsername: "peer", senderName: "测试同事", preview: "合成消息", timestamp: Date(),
            kind: .privateChat, isWhitelisted: true, isVIP: false, replied: false, status: .pending, isIgnored: false)
        monitor.unreadItems = [unread]
        store.close()
        monitor.ignoreSender(chatUsername: unread.chatUsername, chatName: unread.chatName,
                             senderUsername: unread.senderUsername, senderName: unread.senderName)
        XCTAssertEqual(monitor.unreadItems.map(\.id), [unread.id])
        XCTAssertTrue(monitor.suppressedItems.isEmpty)
        XCTAssertNotNil(monitor.inboxActionError)
        try store.open()
        try store.ignoreSender(chatUsername: unread.chatUsername, chatName: unread.chatName,
                               senderUsername: unread.senderUsername, senderName: unread.senderName)
        execute("CREATE TRIGGER reject_unignore BEFORE DELETE ON ignored_senders BEGIN SELECT RAISE(ABORT, 'private failure'); END", on: store)
        monitor.unignoreSender(chatUsername: unread.chatUsername, senderUsername: unread.senderUsername, senderName: unread.senderName)
        XCTAssertEqual(store.loadIgnoredSenders().count, 1)
        XCTAssertNotNil(monitor.inboxActionError)
        XCTAssertFalse(monitor.inboxActionError?.contains("private failure") ?? true)
    }

    @MainActor
    func testUnsilenceClearsSnoozeAsWellAsPersistedActionRow() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }
        XCTAssertTrue(monitor.snoozeInboxItem(item, until: Date().addingTimeInterval(3600)))
        XCTAssertTrue(monitor.silenceInboxItem(item))
        XCTAssertTrue(monitor.unsilenceInboxItem(item))
        XCTAssertTrue(store.loadChatActions().isEmpty)
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)
    }

    @MainActor
    func testExpiredSnoozeRefreshesWithoutMessageScan() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }

        let expiry = Date(timeIntervalSince1970: 2_000_000_100)
        XCTAssertTrue(monitor.snoozeInboxItem(item, until: expiry))
        XCTAssertTrue(monitor.inboxItems.isEmpty)

        // An unexpired snooze remains hidden.
        monitor.refreshExpiredSnoozes(now: Date(timeIntervalSince1970: 2_000_000_099))
        XCTAssertTrue(monitor.inboxItems.isEmpty)

        // Expiry is inclusive: at the exact deadline the item is eligible.
        monitor.refreshExpiredSnoozes(now: expiry)
        XCTAssertEqual(monitor.inboxItems.map(\.id), [item.id])
        XCTAssertTrue(monitor.handledItems.isEmpty)

        // Keep the durable action row; its past timestamp naturally stops
        // suppressing the item after a restart as well.
        XCTAssertEqual(store.loadChatActions()[item.chatUsername]?.snoozedUntil,
                       Int(expiry.timeIntervalSince1970))
    }

    @MainActor
    func testExpiredSnoozeDoesNotClearSeparateSilenceState() throws {
        let (store, monitor, item, root) = try fixture()
        defer { cleanup(store, root) }

        let expiry = Date(timeIntervalSince1970: 2_000_000_100)
        XCTAssertTrue(monitor.snoozeInboxItem(item, until: expiry))
        XCTAssertTrue(monitor.silenceInboxItem(item))
        XCTAssertEqual(monitor.handledItems.first?.status, .silenced)

        monitor.refreshExpiredSnoozes(now: expiry)

        XCTAssertTrue(monitor.inboxItems.isEmpty)
        XCTAssertEqual(monitor.handledItems.first?.status, .silenced)
        XCTAssertEqual(store.loadChatActions()[item.chatUsername]?.snoozedUntil, 0)
        XCTAssertGreaterThan(store.loadChatActions()[item.chatUsername]?.silencedAt ?? 0, 0)
    }
}
