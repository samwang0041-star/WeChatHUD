import XCTest
@testable import WeChatHUD

/// The scan-apply tail used to run four whole-table passes on the main actor
/// every single scan (FSEvents at 0.0s latency plus the heartbeat is 6-10
/// scans a minute while WeChat is active), and the cost grew with the tables
/// themselves — so a long-lived resident app got slower by the hour and the
/// island's display-link animation started dropping frames.
final class ChatRepairThrottleTests: XCTestCase {

    @MainActor
    private func makeMonitor() throws -> (ChatMonitor, HUDStore, String) {
        let root = NSTemporaryDirectory() + "chat-repair-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(keysPath: root + "/absent-keys.json",
                                  dbDir: root + "/synthetic/db_storage", cacheStrategy: .memory)
        return (ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig())), store, root)
    }

    /// Priming the cache and getting it back is how this test sees that the
    /// naming pass actually ran: it is the first thing that pass does.
    @MainActor
    func testRepairsDoNotRunOnEveryScan() throws {
        let (monitor, store, root) = try makeMonitor()
        defer { store.close(); try? FileManager.default.removeItem(atPath: root) }
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)

        monitor.displayNameCache["chat-a"] = "小美"
        _ = monitor.repairPersistedChatDataIfNeeded(contactsChanged: false, now: t0)
        XCTAssertTrue(monitor.displayNameCache.isEmpty, "the first pass must run")
        XCTAssertEqual(monitor.lastChatRepairAt, t0)

        monitor.displayNameCache["chat-a"] = "小美"
        _ = monitor.repairPersistedChatDataIfNeeded(contactsChanged: false, now: t0.addingTimeInterval(10))
        XCTAssertEqual(monitor.displayNameCache.count, 1,
                       "ten seconds later the same scan must not repeat the sweep")
        XCTAssertEqual(monitor.lastChatRepairAt, t0, "the stamp must not move")

        monitor.displayNameCache["chat-a"] = "小美"
        _ = monitor.repairPersistedChatDataIfNeeded(contactsChanged: false,
                                                    now: t0.addingTimeInterval(ChatMonitor.chatRepairInterval))
        XCTAssertTrue(monitor.displayNameCache.isEmpty, "the interval has elapsed; run again")
        XCTAssertEqual(monitor.lastChatRepairAt, t0.addingTimeInterval(ChatMonitor.chatRepairInterval))
    }

    /// A renamed 备注 is the one event that can make the persisted names wrong,
    /// and it must not wait for the hour.
    @MainActor
    func testContactChangeRunsThePassImmediately() throws {
        let (monitor, store, root) = try makeMonitor()
        defer { store.close(); try? FileManager.default.removeItem(atPath: root) }
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        _ = monitor.repairPersistedChatDataIfNeeded(contactsChanged: false, now: t0)

        monitor.displayNameCache["chat-a"] = "小美"
        _ = monitor.repairPersistedChatDataIfNeeded(contactsChanged: true, now: t0.addingTimeInterval(3))
        XCTAssertTrue(monitor.displayNameCache.isEmpty)
        XCTAssertEqual(monitor.lastChatRepairAt, t0, "an event-driven run must not reset the hour")
    }
}
