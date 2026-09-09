import XCTest
@testable import WeChatHUD

/// Applies the real repair path to a copy of the live business database and
/// asserts the stale raw ids actually disappear, without touching the user's
/// data.
final class ChatNamingRepairLiveTests: XCTestCase {
    func testRepairClearsStaleRawIdsInRealDatabaseCopy() throws {
        let live = NSHomeDirectory() + "/.wechat-hud/hud.sqlite3"
        guard FileManager.default.fileExists(atPath: live) else {
            throw XCTSkip("no local business database")
        }

        // Copy database + WAL so the repair runs against real production rows.
        let dir = NSTemporaryDirectory() + "chat_naming_repair_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: live + suffix) {
            try FileManager.default.copyItem(atPath: live + suffix, toPath: dir + "/hud.sqlite3" + suffix)
        }

        let store = HUDStore(dbPath: dir + "/hud.sqlite3", createParentDirectory: false)
        try store.open()
        defer { store.close() }

        // Simulate the pre-fix state: rows carrying the raw room id.
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "repair-live-1", chatUsername: raw, chatName: raw,
            content: "确认物料", commitTo: "赖豪", confidence: 0.9, promptVersion: "v1"
        )
        let staleBefore = store.uninformativeChatNameRows().filter { $0.key == raw }
        print("[repair] uninformative rows for \(raw): \(staleBefore.count)")
        XCTAssertFalse(staleBefore.isEmpty)

        // Resolver stands in for the reader's member-derived naming.
        let updates = staleBefore.map {
            (table: $0.table, keyColumn: $0.keyColumn, nameColumn: $0.nameColumn,
             key: $0.key, oldName: $0.name, newName: "群聊 · 上步雍勋、张沛、赖豪")
        }
        let changed = store.applyResolvedChatNames(updates)
        print("[repair] rows changed=\(changed)")
        XCTAssertGreaterThan(changed, 0)

        let commitments = store.loadCommitments()
        XCTAssertTrue(commitments.allSatisfy { !ContactIdentityIndex.isRawChatIdentifier($0.chatName) })
        XCTAssertEqual(
            commitments.first { $0.msgUID == "repair-live-1" }?.chatName,
            "群聊 · 上步雍勋、张沛、赖豪"
        )

        // Convergence: resolving again finds nothing left to change.
        let remaining = store.uninformativeChatNameRows().filter {
            $0.key == raw && !ContactIdentityIndex.isRawChatIdentifier($0.name)
                && $0.name != ContactIdentityIndex.unnamedGroupPlaceholder
        }
        XCTAssertTrue(remaining.isEmpty)
    }
}
