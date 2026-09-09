import XCTest
@testable import WeChatHUD

/// Exercises the naming decisions through `ChatMonitor` — the type the UI
/// actually calls — against the live WeChat database.
@MainActor
final class ChatNamingMonitorLiveTests: XCTestCase {
    func testNamelessGroupIsDetectedThroughMonitor() throws {
        let roots = WeChatReader.databaseCandidates()
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0 + "/contact/contact.db") }) else {
            throw XCTSkip("no local WeChat database")
        }
        let reader = WeChatReader(dbDir: root, cacheStrategy: .temporary)
        guard (try? reader.loadKeys()) != nil else { throw XCTSkip("no local keys") }
        try reader.refreshContactsIfChanged(strict: true)

        let path = NSTemporaryDirectory() + "chat_naming_monitor_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))

        let nameless = "43753159251@chatroom"
        XCTAssertTrue(monitor.hasOnlyFallbackName(chatUsername: nameless))
        XCTAssertEqual(monitor.displayName(for: nameless), "群聊 · 上步雍勋、张沛、赖豪")

        let named = "54461316910@chatroom"
        XCTAssertFalse(monitor.hasOnlyFallbackName(chatUsername: named))
        XCTAssertEqual(monitor.displayName(for: named), "产品营销组")
    }

    func testUserAliasWinsAndClearingRestoresWeChatName() throws {
        let roots = WeChatReader.databaseCandidates()
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0 + "/contact/contact.db") }) else {
            throw XCTSkip("no local WeChat database")
        }
        let reader = WeChatReader(dbDir: root, cacheStrategy: .temporary)
        guard (try? reader.loadKeys()) != nil else { throw XCTSkip("no local keys") }
        try reader.refreshContactsIfChanged(strict: true)

        let path = NSTemporaryDirectory() + "chat_naming_alias_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))

        let nameless = "43753159251@chatroom"
        try monitor.renameChat(chatUsername: nameless, displayName: "供应链周会")
        XCTAssertEqual(monitor.displayName(for: nameless), "供应链周会")
        XCTAssertFalse(monitor.hasOnlyFallbackName(chatUsername: nameless), "an alias is a real name")

        try monitor.clearChatAlias(chatUsername: nameless)
        XCTAssertEqual(monitor.displayName(for: nameless), "群聊 · 上步雍勋、张沛、赖豪")
        XCTAssertTrue(monitor.hasOnlyFallbackName(chatUsername: nameless))
    }
}
