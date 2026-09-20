import XCTest
@testable import WeChatHUD

/// §238: `repairVIPTrackingAlignment()` runs from `HUDStore.open()`, so every launch
/// and every account switch passes through it. It read the whitelist row with the
/// nil-on-error `getWhitelistEntry` and then wrote the row back through a
/// full-column overwrite — `category: existing?.category ?? .other`.
final class VIPAlignmentRepairHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "vip-align-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .watch)
        try store.upsertContact(username: "peer", displayName: "同事",
                                attentionLevel: .vip, role: .colleague)
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    /// The misalignment the repair exists to fix, with the row actually readable.
    func testRepairStillAlignsAReadableRow() throws {
        store.repairVIPTrackingAlignment()
        let row = try XCTUnwrap(store.getWhitelistEntry(username: "peer"))
        XCTAssertEqual(row.attentionLevel, .vip, "正对照：该修的要修得动")
        XCTAssertEqual(row.category, .work, "对齐 VIP 不该顺手改掉用户自己选的 工作")
    }

    /// The defect: a failed read was answered by writing a category the user never
    /// chose, and it self-healed on the next launch only if nothing failed again.
    func testRepairDoesNotRelabelAConversationItCouldNotRead() throws {
        store.repairVIPTrackingAlignment(read: { _ in .unreadable })
        let row = try XCTUnwrap(store.getWhitelistEntry(username: "peer"))
        XCTAssertEqual(row.category, .work,
                       "读不到时不能把 工作 写成 其他 —— 这是用户自己归的类")
        XCTAssertEqual(row.attentionLevel, .watch, "读不到时整行都不该被碰")
    }

    /// The branch that legitimately uses defaults, pinned so the guard above cannot
    /// be "never write anything" in disguise.
    func testAbsentRowIsStillTrackedFromTheContact() throws {
        try store.exec("DELETE FROM whitelist WHERE username='peer'")
        XCTAssertNil(store.getWhitelistEntry(username: "peer"))
        store.repairVIPTrackingAlignment()
        let row = try XCTUnwrap(store.getWhitelistEntry(username: "peer"))
        XCTAssertEqual(row.attentionLevel, .vip)
    }
}
