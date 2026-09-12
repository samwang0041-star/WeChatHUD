import XCTest
@testable import WeChatHUD

/// `.persistent` strategy: the manifest used to be rewritten (full JSON +
/// atomic write + `setAttributes`) on every changed DB, so one scan could pay
/// that cost a dozen times. It is now marked dirty and written once, shortly
/// after the burst, with `deinit` as the last-chance flush.
final class WeChatReaderManifestDebouncePerfTests: XCTestCase {
    private let chat = "wxid_manifest_peer"
    private let dbs = ["message/message_0.db", "message/message_1.db", "message/message_2.db"]

    func testRefreshBurstCollapsesIntoASingleManifestWrite() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        for (index, relPath) in dbs.enumerated() {
            try fixture.createMessageDB(
                relPath: relPath,
                chats: [chat: [.init(localId: index + 1, createTime: 1_000 + index, senderId: 1, text: "消息\(index)")]],
                name2id: [chat]
            )
        }
        let reader = try fixture.makeReader(cacheStrategy: .persistent)
        XCTAssertEqual(reader.manifestWriteCount, 0)

        for relPath in dbs {
            XCTAssertTrue(try reader.refreshIfChanged(relPath: relPath))
        }

        // Still inside the debounce window: nothing has been serialized yet.
        XCTAssertEqual(reader.manifestWriteCount, 0, "refreshes must not each write the manifest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath(for: fixture)))

        // No scan-boundary call site is required — the debounce timer must land
        // the write on its own.
        XCTAssertTrue(
            waitUntil { reader.manifestWriteCount == 1 },
            "debounced manifest flush never fired"
        )
        XCTAssertEqual(reader.manifestWriteCount, 1, "three refreshes must produce exactly one write")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath(for: fixture))))
                as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), Set(dbs), "manifest must carry one entry per cached DB")

        // Content is loadable: a fresh reader restores the index from it, so an
        // unchanged DB is not reported as changed (and not re-decrypted).
        let restored = try fixture.makeReader(cacheStrategy: .persistent)
        for relPath in dbs {
            XCTAssertFalse(
                try restored.refreshIfChanged(relPath: relPath),
                "manifest entry for \(relPath) did not survive the round trip"
            )
        }
    }

    func testDeinitFlushesAPendingManifestWrite() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        try fixture.createMessageDB(
            relPath: dbs[0],
            chats: [chat: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "消息")]],
            name2id: [chat]
        )
        var reader: WeChatReader? = try fixture.makeReader(cacheStrategy: .persistent)
        XCTAssertTrue(try reader!.refreshIfChanged(relPath: dbs[0]))
        XCTAssertEqual(reader!.manifestWriteCount, 0)

        reader = nil  // deinit must flush before the debounce timer would fire

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestPath(for: fixture)),
            "deinit did not flush the pending manifest"
        )
        let restored = try fixture.makeReader(cacheStrategy: .persistent)
        XCTAssertFalse(try restored.refreshIfChanged(relPath: dbs[0]))
    }

    func testFlushWithoutNewEntriesDoesNotWrite() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        try fixture.createMessageDB(
            relPath: dbs[0],
            chats: [chat: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "消息")]],
            name2id: [chat]
        )
        let reader = try fixture.makeReader(cacheStrategy: .persistent)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: dbs[0]))
        reader.flushManifestIfNeeded()
        XCTAssertEqual(reader.manifestWriteCount, 1)

        let before = try modificationDate(of: manifestPath(for: fixture))
        reader.flushManifestIfNeeded()
        reader.flushManifestIfNeeded()
        XCTAssertEqual(reader.manifestWriteCount, 1, "a clean manifest must not be rewritten")
        XCTAssertEqual(try modificationDate(of: manifestPath(for: fixture)), before)

        // An unchanged DB reports "nothing moved", so it marks nothing dirty:
        // the periodic scan does not rewrite the manifest just by running.
        XCTAssertFalse(try reader.refreshIfChanged(relPath: dbs[0]))
        reader.flushManifestIfNeeded()
        XCTAssertEqual(reader.manifestWriteCount, 1)
    }

    // MARK: Helpers

    private func manifestPath(for fixture: WeChatReaderPerfFixture) -> String {
        WeChatReader.cacheDir(for: .persistent, databaseRoot: fixture.dbDir.path) + "/manifest.json"
    }

    private func modificationDate(of path: String) throws -> Date {
        try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        )
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
