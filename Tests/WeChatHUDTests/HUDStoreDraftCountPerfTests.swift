import XCTest
@testable import WeChatHUD

/// The workspace badge used to compute its number by materialising every
/// saved draft plus every composer draft (with a display-name lookup each)
/// and taking .count. It now counts in SQL; these tests pin the parity.
final class HUDStoreDraftCountPerfTests: XCTestCase {

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "hudstore-draft-count-" + UUID().uuidString + ".sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }

    func testCountMatchesLoadedDraftsForMixedSavedAndComposerData() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        // Saved drafts, deliberately including the same chat twice with the
        // same text — a duplicate that must still be counted twice.
        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "重复文本", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "重复文本", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "只有草稿", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-b", chatName: "乙群", text: "乙的草稿", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-c", chatName: "丙群", text: "   ", sendAt: nil)

        // Composer drafts:
        //  - exact duplicate of a saved (chat, text) pair -> not counted
        //  - same text as a saved row but a different chat -> counted
        //  - text that matches no saved row -> counted
        //  - blank after trimming -> never counted
        //  - whitespace-different from a saved row -> counted (no normalization)
        try store.setSetting("composer_draft:chat-a", value: "重复文本")
        try store.setSetting("composer_draft:chat-b", value: "重复文本")
        try store.setSetting("composer_draft:chat-d", value: "全新的输入")
        try store.setSetting("composer_draft:chat-e", value: "   ")
        try store.setSetting("composer_draft:chat-f", value: "重复文本 ")

        XCTAssertEqual(store.workspaceDraftCount(), store.loadWorkspaceDrafts().count)
        // 5 saved + 4 composer-only (chat-b, chat-d, chat-f, and the duplicate
        // text from a different chat only counts once per chat) = 8.
        XCTAssertEqual(store.workspaceDraftCount(), 8)
    }

    func testCountMatchesLoadedDraftsOnEmptyStore() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(store.workspaceDraftCount(), 0)
        XCTAssertEqual(store.workspaceDraftCount(), store.loadWorkspaceDrafts().count)
    }

    func testCountMatchesLoadedDraftsWithSavedRowsOnly() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "一", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "二", sendAt: nil)
        try store.saveDraft(chatUsername: "chat-b", chatName: "乙群", text: "一", sendAt: nil)

        XCTAssertEqual(store.workspaceDraftCount(), 3)
        XCTAssertEqual(store.workspaceDraftCount(), store.loadWorkspaceDrafts().count)
    }

    func testCountMatchesLoadedDraftsWithComposerRowsOnly() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.setSetting("composer_draft:chat-a", value: "甲")
        try store.setSetting("composer_draft:chat-b", value: "乙")
        try store.setSetting("composer_draft:chat-c", value: "")

        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertEqual(store.workspaceDraftCount(), store.loadWorkspaceDrafts().count)
    }

    /// A draft deleted from the saved table must stop suppressing the
    /// composer row for the same (chat, text) pair.
    func testCountTracksDeletionOfSavedRow() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "同文本", sendAt: nil)
        try store.setSetting("composer_draft:chat-a", value: "同文本")
        XCTAssertEqual(store.workspaceDraftCount(), 1)

        let saved = try XCTUnwrap(store.loadDrafts().first)
        try store.deleteDraft(id: saved.id)

        XCTAssertEqual(store.workspaceDraftCount(), 1, "the composer row is now the only copy")
        XCTAssertEqual(store.workspaceDraftCount(), store.loadWorkspaceDrafts().count)
    }

    // MARK: - Draft-count instrumentation

    /// The count path must not go through the full load. The observable proof
    /// is that counting prepares only its own statements: repeated counts are
    /// cache hits, so the prepare counter moves once.
    func testRepeatedCountsReuseTheirStatements() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.saveDraft(chatUsername: "chat-a", chatName: "甲群", text: "草稿", sendAt: nil)
        try store.setSetting("composer_draft:chat-b", value: "输入")
        XCTAssertEqual(store.workspaceDraftCount(), 2)

        let before = store.statementPrepareCount
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertEqual(store.statementPrepareCount - before, 0,
                       "the count path must hit the statement cache on repeat")
    }
}
