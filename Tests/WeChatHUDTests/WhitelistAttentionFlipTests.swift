import XCTest
@testable import WeChatHUD

/// §242: 标 VIP used to read the whitelist row with the nil-on-error
/// `getWhitelistEntry` and then write every column back through `addToWhitelist`, so a
/// transient read failure during an ordinary click reset the user's own 分类 and 显示名.
final class WhitelistAttentionFlipTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    @MainActor
    private func prepare() throws -> ChatMonitor {
        dbPath = NSTemporaryDirectory() + "attention-flip-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reader = WeChatReader(keysPath: "/nonexistent/test-keys.json",
                                  dbDir: root.path, cacheStrategy: .memory)
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .watch)
        return ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
    }

    private func cleanup() {
        store?.close()
        guard let dbPath else { return }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
    }

    /// The caller passes a display name, an isGroup guess and a fallback category
    /// because the old API needed them — none of them may land on an existing row.
    @MainActor
    func testMarkingVIPTouchesOnlyTheAttentionLevel() throws {
        let monitor = try prepare()
        defer { cleanup() }
        monitor.updateWhitelistAttention(username: "peer", displayName: "错的名称",
                                         isGroup: true, fallbackCategory: .other,
                                         attentionLevel: .vip)
        let row = try XCTUnwrap(store.getWhitelistEntry(username: "peer"))
        XCTAssertEqual(row.attentionLevel, .vip, "该改的档位要改得动")
        XCTAssertEqual(row.displayName, "同事", "标 VIP 不该顺手改掉显示名")
        XCTAssertEqual(row.category, .work, "标 VIP 不该顺手改掉用户自己归的分类")
        XCTAssertFalse(row.isGroup, "标 VIP 不该把私聊变成群")
    }

    /// `false` must mean 「这行确实没有」, never 「这次写失败」 — otherwise the caller
    /// falls into its insert branch and a transient error becomes a silent no-op.
    @MainActor
    func testFailedStatementThrowsInsteadOfAnsweringNoRow() throws {
        _ = try prepare()
        defer { cleanup() }
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        XCTAssertThrowsError(
            try store.setWhitelistAttentionLevel(.vip, username: "peer"),
            "写失败要抛，不能被读成「没有这一行」")
    }

    /// The branch that legitimately needs the caller's values: nothing to preserve.
    @MainActor
    func testUnknownChatIsStillFollowedWithTheCallersValues() throws {
        let monitor = try prepare()
        defer { cleanup() }
        try store.exec("DELETE FROM whitelist WHERE username='peer'")
        monitor.updateWhitelistAttention(username: "peer", displayName: "张总",
                                         isGroup: false, fallbackCategory: .life,
                                         attentionLevel: .vip)
        let row = try XCTUnwrap(store.getWhitelistEntry(username: "peer"))
        XCTAssertEqual(row.displayName, "张总")
        XCTAssertEqual(row.category, .life)
        XCTAssertEqual(row.attentionLevel, .vip)
    }
    @MainActor
    func testFailedAttentionWriteDoesNotPretendSuccess() throws {
        let monitor = try prepare()
        defer { cleanup() }
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        XCTAssertFalse(
            monitor.updateWhitelistAttention(username: "peer", displayName: "同事",
                                             isGroup: false, fallbackCategory: .work,
                                             attentionLevel: .vip)
        )
        XCTAssertEqual(monitor.inboxActionError, CompanionInteractionCopy.followLevelFailed)
    }

}
