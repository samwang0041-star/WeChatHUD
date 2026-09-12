import XCTest
@testable import WeChatHUD

/// `.memory` strategy: `purgeEphemeralCache` must delete every plaintext file
/// while keeping the encryption mtimes that tell the next scan which DBs are
/// unchanged. Clearing the mtimes made every file look new, so the scan
/// re-decrypted and re-parsed the whole corpus on each cycle.
final class WeChatReaderEphemeralCachePerfTests: XCTestCase {
    private let chat = "wxid_ephemeral_peer"
    private let relPath = "message/message_0.db"

    func testPurgeDeletesPlaintextButKeepsChangeDetection() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        try fixture.createMessageDB(
            relPath: relPath,
            chats: [chat: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "第一条")]],
            name2id: [chat]
        )
        let reader = try fixture.makeReader(cacheStrategy: .memory)

        XCTAssertTrue(try reader.refreshIfChanged(relPath: relPath))
        XCTAssertEqual(reader.decryptedSnapshotWriteCount, 1)
        XCTAssertFalse(try reader.refreshIfChanged(relPath: relPath), "unchanged DB must not report a change")
        XCTAssertEqual(reader.decryptedSnapshotWriteCount, 1)

        let cachedPaths = reader.decryptedFilePaths
        XCTAssertEqual(cachedPaths.count, 1)
        for path in cachedPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "expected a snapshot at \(path)")
        }

        reader.purgeEphemeralCache()

        // Privacy promise: nothing readable left behind, cache emptied.
        XCTAssertEqual(reader.decryptedCacheCount, 0)
        for path in cachedPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "plaintext residue at \(path)")
        }
        // This reader's own plaintext directory (the account-level directory is
        // shared with every other reader in the process, so only the folder that
        // held these snapshots says anything about this purge).
        let readerCacheDir = (cachedPaths[0] as NSString).deletingLastPathComponent
        let leftovers = try filesUnder(readerCacheDir)
        XCTAssertTrue(leftovers.isEmpty, "ephemeral plaintext dir still holds \(leftovers)")

        // Change detection survives the purge: this assertion fails when the
        // mtimes are cleared together with the cache (the DB looks new again).
        XCTAssertTrue(reader.tracksEncryptionMtime(forRelativePath: relPath))
        XCTAssertFalse(try reader.refreshIfChanged(relPath: relPath))
        XCTAssertEqual(reader.decryptedSnapshotWriteCount, 1, "a no-op refresh must not re-decrypt")

        // The deleted snapshot is rebuilt on demand. `getDecryptedDB`'s
        // file-exists fallback is what makes keeping the mtime safe.
        let rebuilt = try reader.getDecryptedDB(relativePath: relPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt))
        XCTAssertEqual(reader.decryptedSnapshotWriteCount, 2)
        XCTAssertEqual(try reader.getMessages(chatUsername: chat, limit: 10).map(\.text), ["第一条"])
    }

    func testChangedDatabaseAfterPurgeIsStillReDecrypted() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        try fixture.createMessageDB(
            relPath: relPath,
            chats: [chat: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "第一条")]],
            name2id: [chat]
        )
        let reader = try fixture.makeReader(cacheStrategy: .memory)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: relPath))
        reader.purgeEphemeralCache()

        // A real WeChat write: new content, newer mtime.
        try fixture.appendMessages(
            relPath: relPath,
            chats: [chat: [.init(localId: 2, createTime: 2_000, senderId: 1, text: "第二条")]]
        )

        XCTAssertTrue(try reader.refreshIfChanged(relPath: relPath), "a changed DB must still report a change")
        XCTAssertEqual(try reader.getMessages(chatUsername: chat, limit: 10).map(\.text).sorted(), ["第一条", "第二条"])
    }

    private func filesUnder(_ path: String) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
        return enumerator.compactMap { $0 as? String }.sorted()
    }
}
