import XCTest
@testable import WeChatHUD

final class HUDStoreTests: XCTestCase {
    var store: HUDStore!
    var tmpPath: String!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_test_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testSettingsRoundTrip() throws {
        try store.setSetting("foo", value: "bar")
        XCTAssertEqual(store.getSetting("foo"), "bar")

        try store.setSetting("foo", value: "baz")
        XCTAssertEqual(store.getSetting("foo"), "baz")
    }

    func testSettingsJSONRoundTrip() throws {
        let cfg = AIConfig(baseURL: "http://test:8080/v1", model: "test-model")
        try store.setSettingJSON("ai", value: cfg)
        let loaded = store.getSettingJSON("ai", as: AIConfig.self)
        XCTAssertEqual(loaded?.baseURL, "http://test:8080/v1")
        XCTAssertEqual(loaded?.model, "test-model")
    }

    func testWhitelistCRUD() throws {
        try store.addToWhitelist(username: "user1", displayName: "Test User", isGroup: false, category: .work)
        XCTAssertTrue(store.isWhitelisted("user1"))
        XCTAssertFalse(store.isWhitelisted("user2"))

        let list = store.getWhitelist()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Test User")
        XCTAssertEqual(list[0].category, .work)

        try store.removeFromWhitelist(username: "user1")
        XCTAssertFalse(store.isWhitelisted("user1"))
    }

    func testWhitelistMutuallyExclusive() throws {
        try store.addToWhitelist(username: "user1", displayName: "Test", isGroup: false, category: .work)
        try store.addToWhitelist(username: "user1", displayName: "Test", isGroup: false, category: .life)
        let list = store.getWhitelist()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].category, .life)
    }

    func testSyncState() throws {
        XCTAssertNil(store.getSyncState("msg_01/Msg_abc"))
        try store.updateSyncState("msg_01/Msg_abc", lastLocalId: 100)
        let state = store.getSyncState("msg_01/Msg_abc")
        XCTAssertEqual(state?.lastLocalId, 100)
    }
}
