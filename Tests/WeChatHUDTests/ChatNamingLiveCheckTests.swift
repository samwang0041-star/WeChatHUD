import XCTest
@testable import WeChatHUD

/// Reads the machine's real WeChat databases (read-only) to confirm the
/// nameless-group fallback works on actual data rather than only fixtures.
/// Skipped when no local account/keys are available.
final class ChatNamingLiveCheckTests: XCTestCase {
    func testNamelessGroupsGetAReadableName() throws {
        let roots = WeChatReader.databaseCandidates()
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0 + "/contact/contact.db") }) else {
            throw XCTSkip("no local WeChat database")
        }
        let reader = WeChatReader(dbDir: root, cacheStrategy: .temporary)
        guard (try? reader.loadKeys()) != nil else { throw XCTSkip("no local keys") }
        try reader.loadContacts()

        let contacts = reader.allContacts()
        let groups = contacts.keys.filter { $0.contains("@chatroom") }
        let nameless = groups.filter { reader.displayName(for: $0) == ContactIdentityIndex.unnamedGroupPlaceholder }
        print("[live] groups=\(groups.count) nameless=\(nameless.count)")

        // Whatever the mix, no group may resolve to its raw room id.
        for group in groups {
            let name = reader.displayName(for: group)
            XCTAssertFalse(name.contains("@chatroom"), "raw id leaked for \(group)")
            XCTAssertFalse(name.isEmpty)
        }

        if let sample = groups.first(where: { $0 == "43753159251@chatroom" }) {
            let name = reader.displayName(for: sample)
            print("[live] 43753159251@chatroom → \(name)")
            XCTAssertNotEqual(name, sample)
        }
    }
}
