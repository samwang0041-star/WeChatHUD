import XCTest
@testable import WeChatHUD

/// W5 regression cover for the ScanEngine duplicate-key and ordering fixes:
///   A1/A2 — duplicate usernames in the contacts / session snapshots must not
///           trap (uncatchably) the whole scan; the first row wins.
///   A3    — items whose primary sort keys tie must not fall back to input
///           order, which reshuffles SwiftUI rows for no visible reason.
final class ScanEngineLookupOrderTests: XCTestCase {

    // MARK: - Fixtures

    private func contactRow(username: String, displayName: String) -> ContactEntry {
        ContactEntry(
            id: username,
            username: username,
            displayName: displayName,
            attentionLevel: .whitelist,
            role: .colleague,
            roleNote: "",
            replyWindowMinutes: 120,
            levelChangedAt: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func sessionRow(username: String, unreadCount: Int) -> SessionInfo {
        SessionInfo(username: username, isGroup: false, unreadCount: unreadCount, lastTimestamp: 1_700_000_000)
    }

    private func unreadItem(
        chat: String,
        status: UnreadStatus,
        timestamp: Date,
        sender: String = "wxid_peer",
        preview: String = "在吗",
        kind: HUDNotificationKind = .privateChat
    ) -> UnreadItem {
        UnreadItem(
            chatUsername: chat,
            chatName: chat,
            senderUsername: sender,
            senderName: sender,
            preview: preview,
            timestamp: timestamp,
            kind: kind,
            isWhitelisted: true,
            isVIP: false,
            replied: false,
            status: status,
            isIgnored: false
        )
    }

    private func notification(
        chat: String,
        messageID: String,
        timestamp: Date,
        kind: HUDNotificationKind = .privateChat
    ) -> HUDNotification {
        HUDNotification(
            chatUsername: chat,
            chatName: chat,
            senderUsername: "wxid_peer",
            senderName: "同事",
            attentionLevel: .watch,
            messageID: messageID,
            rawText: "在吗",
            snippet: "在吗",
            isAtMention: false,
            timestamp: timestamp,
            kind: kind
        )
    }

    // MARK: - A1: contact snapshot with a repeated username

    func testContactLookupCollapsesDuplicateUsernameToFirstRow() {
        // Why the fixture is realistic: the contacts table has no UNIQUE
        // constraint on username, so multi-account rows or re-import leftovers
        // can repeat one. The old Dictionary(uniqueKeysWithValues:) trapped the
        // process on this input; the lookup now collapses duplicates instead.
        let rows = [
            contactRow(username: "wxid_dup", displayName: "第一行"),
            contactRow(username: "wxid_dup", displayName: "第二行"),
            contactRow(username: "wxid_unique", displayName: "唯一"),
        ]
        let map = ScanEngine.contactLookup(rows)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["wxid_dup"]?.displayName, "第一行", "the first duplicate row must win")
        XCTAssertEqual(map["wxid_unique"]?.displayName, "唯一")
    }

    // MARK: - A2: session snapshot with a repeated username

    func testSessionLookupCollapsesDuplicateUsernameToFirstRow() {
        let rows = [
            sessionRow(username: "wxid_dup", unreadCount: 3),
            sessionRow(username: "wxid_dup", unreadCount: 9),
        ]
        let map = ScanEngine.sessionLookup(rows)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["wxid_dup"]?.unreadCount, 3, "the first duplicate row must win")
    }

    // MARK: - A3: unread ordering

    func testUnreadOrderIsDeterministicWhenStatusAndTimestampTie() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let items = ["chat_c", "chat_a", "chat_b"].map {
            unreadItem(chat: $0, status: .pending, timestamp: stamp)
        }
        let ascending = items.sorted(by: ScanEngine.unreadOrder)
        let permuted = [items[2], items[0], items[1]].sorted(by: ScanEngine.unreadOrder)
        let reversed = items.reversed().sorted(by: ScanEngine.unreadOrder)

        XCTAssertEqual(ascending.map(\.chatUsername), ["chat_a", "chat_b", "chat_c"])
        XCTAssertEqual(permuted.map(\.chatUsername), ascending.map(\.chatUsername))
        XCTAssertEqual(reversed.map(\.chatUsername), ascending.map(\.chatUsername))
    }

    func testUnreadOrderPrimaryKeysStillDominate() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let overdueOlder = unreadItem(chat: "chat_z", status: .overdue, timestamp: stamp)
        let pendingNewer = unreadItem(chat: "chat_a", status: .pending, timestamp: stamp.addingTimeInterval(3600))
        XCTAssertTrue(ScanEngine.unreadOrder(overdueOlder, pendingNewer),
                      "overdue must stay in front of pending even when it is older")
        XCTAssertFalse(ScanEngine.unreadOrder(pendingNewer, overdueOlder))

        let sameRankOld = unreadItem(chat: "chat_a", status: .pending, timestamp: stamp)
        let sameRankNew = unreadItem(chat: "chat_z", status: .pending, timestamp: stamp.addingTimeInterval(60))
        XCTAssertTrue(ScanEngine.unreadOrder(sameRankNew, sameRankOld),
                      "inside one rank the newer timestamp must still win")
        XCTAssertFalse(ScanEngine.unreadOrder(sameRankOld, sameRankNew))
    }

    // MARK: - A3: recent-notification ordering

    func testRecentNotificationOrderIsDeterministicWhenTimestampsTie() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let roomTwo = notification(chat: "room_2", messageID: "m1", timestamp: stamp)
        let roomOneLate = notification(chat: "room_1", messageID: "m9", timestamp: stamp)
        let roomOneEarly = notification(chat: "room_1", messageID: "m3", timestamp: stamp)
        let items = [roomTwo, roomOneLate, roomOneEarly]

        let ascending = items.sorted(by: ScanEngine.recentNotificationOrder)
        let permuted = [roomOneEarly, roomTwo, roomOneLate].sorted(by: ScanEngine.recentNotificationOrder)

        XCTAssertEqual(ascending.map { "\($0.chatUsername)#\($0.messageID)" }, ["room_1#m3", "room_1#m9", "room_2#m1"])
        XCTAssertEqual(permuted.map { "\($0.chatUsername)#\($0.messageID)" },
                       ascending.map { "\($0.chatUsername)#\($0.messageID)" })
    }

    func testRecentNotificationOrderNewerTimestampWins() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let older = notification(chat: "room_1", messageID: "m1", timestamp: stamp)
        let newer = notification(chat: "room_1", messageID: "m2", timestamp: stamp.addingTimeInterval(60))
        XCTAssertTrue(ScanEngine.recentNotificationOrder(newer, older))
        XCTAssertFalse(ScanEngine.recentNotificationOrder(older, newer))
    }
}
