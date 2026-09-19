import XCTest

/// `WeChatReader` serializes all database access behind one recursive lock, and
/// a shard decrypt holds it for the whole read + AES + WAL pass. The naming
/// lookups below touch no database — they are what every inbox row renders —
/// so they must not queue behind that decrypt, or the island stops animating
/// for as long as a background scan takes to decrypt a shard.
///
/// A behavioral proof would have to hold the reader's private lock open in the
/// middle of a real decrypt, and no test seam exposes that, so this gates the
/// source shape instead. `namingLock.withLock` never contains the string
/// `lock.withLock` (case matters), which keeps the check simple.
final class ReaderNamingLookupIsolationTests: XCTestCase {

    private var source: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (try? String(contentsOfFile: root + "/Sources/WeChatHUD/Data/WeChatReader.swift", encoding: .utf8)) ?? ""
    }

    private func body(of function: String) -> String {
        guard let start = source.range(of: function) else {
            XCTFail("missing \(function) — the naming lookups changed shape")
            return ""
        }
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "\n    }") else { return String(tail) }
        return String(tail[..<end.upperBound])
    }

    func testNamingLookupsTakeTheNamingLockNotTheDatabaseLock() {
        let readers = [
            "func displayName(for username: String) -> String {",
            "func groupMemberNames(for username: String) -> [String] {",
            "func weChatSearchNames(for username: String) -> [String] {",
            "func weChatRemark(for username: String) -> String? {",
            "func weChatNickName(for username: String) -> String? {",
            "func hasWeChatName(for username: String) -> Bool {",
            "func canonicalContactUsername(for usernameOrAlias: String) -> String? {",
            "func normalizeContactMentions(in text: String) -> String {",
        ]
        for reader in readers {
            let body = body(of: reader)
            XCTAssertTrue(body.contains("namingLock.withLock"), "\(reader) no longer takes the naming lock")
            XCTAssertFalse(body.contains("lock.withLock") || body.contains("lock.lock()"),
                           "\(reader) blocks on the database lock: a running decrypt freezes the main thread")
        }
    }

    func testNamingCachesArePublishedAtomically() {
        XCTAssertTrue(body(of: "func loadContacts() throws {").contains("namingLock.withLock"),
                      "the naming caches must be replaced inside the lock readers use")
        XCTAssertTrue(body(of: "func loadGroupMemberNames(").contains("namingLock.withLock"))
    }
}
