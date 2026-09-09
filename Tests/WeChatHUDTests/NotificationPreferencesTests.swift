import XCTest
@testable import WeChatHUD

final class NotificationPreferencesTests: XCTestCase {
    func testGroupMentionRemainsVisibleWithOrdinaryUpdatesDisabled() {
        let config = NotificationConfig()
        XCTAssertTrue(config.shouldPresent(.groupMentionFYI))
        XCTAssertFalse(config.shouldPresent(.groupInfoOnly))
        XCTAssertFalse(config.shouldPresent(.privateInfoOnly))
    }

    func testOrdinaryUpdatesDoNotBypassDisabledMentionOrVIPPreferences() {
        var config = NotificationConfig()
        config.atMention = false
        config.important = false
        config.allWhitelist = true
        XCTAssertFalse(config.shouldPresent(.groupMentionFYI))
        XCTAssertFalse(config.shouldPresent(.privateVIPRisk))
        XCTAssertTrue(config.shouldPresent(.groupInfoOnly))
        XCTAssertTrue(config.shouldPresent(.privateInfoOnly))
        XCTAssertFalse(config.shouldPresent(.handled))
    }

    func testPreferencesSurviveStoreReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HUDStore(dbPath: root.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        var config = NotificationConfig()
        config.atMention = false
        config.durationSeconds = 8
        try store.setSettingJSON("notification", value: config)
        store.close()
        try store.open()
        defer { store.close() }
        let restored = try XCTUnwrap(store.getSettingJSON("notification", as: NotificationConfig.self))
        XCTAssertFalse(restored.atMention)
        XCTAssertEqual(restored.durationSeconds, 8)
    }
}
