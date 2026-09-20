import XCTest
import SQLite3
@testable import WeChatHUD

/// §231/§233: re-following a chat merges the existing contact row with defaults and
/// writes every column back. `getContact` answers nil both for 「no such contact」 and
/// for 「this read failed」, so a transient read error used to reset the user's role
/// note and reply window to defaults while telling them nothing.
final class ContactMergeHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "contact-merge-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work)
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    private func stampCustomization() throws {
        let base = try XCTUnwrap(store.getContact(username: "peer"))
        try store.upsertContact(username: "peer", displayName: base.displayName,
                                attentionLevel: base.attentionLevel, role: base.role,
                                roleNote: "老客户，别催", replyWindowMinutes: 7)
    }

    /// Stand-in for the read failing while the table itself is still writable later:
    /// schema moved out from under the prepared SELECT (failed migration, column
    /// drift) — exactly the case `queryOne`'s `try?` turns into a bare nil.
    private func makeContactsUnreadable() throws {
        try store.exec("ALTER TABLE contacts RENAME TO contacts_hidden")
    }

    private func restoreContacts() throws {
        try store.exec("ALTER TABLE contacts_hidden RENAME TO contacts")
    }

    func testThreeStateReadSeparatesAbsentFromUnreadable() throws {
        XCTAssertEqual(store.contactRead("peer").kindDescription, "value")
        XCTAssertEqual(store.contactRead("nobody").kindDescription, "absent")
        try makeContactsUnreadable()
        XCTAssertEqual(store.contactRead("peer").kindDescription, "unreadable",
                       "读失败不能和「没有这个人」共用一个答案")
    }

    func testReFollowKeepsTheExistingCustomization() throws {
        try stampCustomization()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work)
        let after = try XCTUnwrap(store.getContact(username: "peer"))
        XCTAssertEqual(after.roleNote, "老客户，别催")
        XCTAssertEqual(after.replyWindowMinutes, 7)
    }

    /// The defect: a failed read was indistinguishable from a brand-new contact, so
    /// the merge wrote defaults over the real ones. Following must still succeed
    /// (that is what the user asked for) — only the destructive merge is refused.
    func testReFollowWhileTheContactReadFailsNeitherThrowsNorResets() throws {
        try stampCustomization()
        try makeContactsUnreadable()
        XCTAssertNoThrow(
            try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work),
            "读不到既有联系人时，关注这件事本身不该失败")
        try restoreContacts()
        let after = try XCTUnwrap(store.getContact(username: "peer"))
        XCTAssertEqual(after.roleNote, "老客户，别催", "读失败不能被当成「没有旧值」再写回默认")
        XCTAssertEqual(after.replyWindowMinutes, 7)
    }

    /// The follow itself must survive: refusing the merge may not silently un-follow
    /// the chat, which is what a thrown error would do to `try?` callers.
    func testRefusedMergeStillFollowsTheChat() throws {
        try store.removeFromWhitelist(username: "peer")
        try makeContactsUnreadable()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work)
        XCTAssertEqual(store.whitelistRead("peer"), .followed)
    }
}
