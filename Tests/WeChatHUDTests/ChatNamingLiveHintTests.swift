import XCTest
@testable import WeChatHUD

/// Verifies the rename hint decision against the live WeChat database: the
/// group in the original report must be recognised as nameless in WeChat while
/// a genuinely named group must not be.
final class ChatNamingLiveHintTests: XCTestCase {
    func testWeChatNamePresenceMatchesRealData() throws {
        let roots = WeChatReader.databaseCandidates()
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0 + "/contact/contact.db") }) else {
            throw XCTSkip("no local WeChat database")
        }
        let reader = WeChatReader(dbDir: root, cacheStrategy: .temporary)
        guard (try? reader.loadKeys()) != nil else { throw XCTSkip("no local keys") }
        try reader.loadContacts()

        let nameless = "43753159251@chatroom"
        XCTAssertFalse(reader.hasWeChatName(for: nameless), "WeChat has no name for this room")
        XCTAssertFalse(reader.displayName(for: nameless).contains("@chatroom"))
        XCTAssertFalse(reader.groupMemberNames(for: nameless).isEmpty)

        let named = "54461316910@chatroom"
        XCTAssertTrue(reader.hasWeChatName(for: named), "this group is named in WeChat")
        XCTAssertEqual(reader.displayName(for: named), "产品营销组")

        // Nothing may resolve to a raw room id, named or not.
        for group in reader.allContacts().keys where group.contains("@chatroom") {
            XCTAssertFalse(reader.displayName(for: group).contains("@chatroom"), "raw id leaked: \(group)")
        }
    }
}
