import XCTest
import Combine
@testable import WeChatHUD

/// Guards for the 10-second safety heartbeat.
///
/// The heartbeat used to assign the autopilot queue / stats / pause snapshot
/// unconditionally. Every published store fires objectWillChange, so an idle
/// HUD (no session, empty queue) re-rendered every observing view twice a
/// minute forever. It also ran at a fixed 10 s cadence with no tolerance, and
/// reloadAIData() re-queried the autopilot display log on every scan.
final class ChatMonitorHeartbeatPerfTests: XCTestCase {

    @MainActor
    private func makeFixture() throws -> (HUDStore, ChatMonitor, String) {
        let root = NSTemporaryDirectory() + "perf-heartbeat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        return (store, monitor, root)
    }

    private func cleanup(_ store: HUDStore, _ root: String) {
        store.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func pendingSend(chat: String = "synthetic-peer", text: String = "好的") -> PendingSend {
        PendingSend(
            chatUsername: chat,
            chatName: "合成同事",
            senderName: "同事",
            replyText: text,
            confidence: 0.9,
            risk: .low,
            reasoning: "合成测试",
            styleScore: 80,
            scheduledSendTime: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func logEntry(uid: String) -> AutopilotLogEntry {
        AutopilotLogEntry(
            id: 0,
            sessionId: 0,
            chatUsername: "synthetic-peer",
            chatName: "合成同事",
            senderUsername: "synthetic-peer",
            senderName: "同事",
            triggerMsgUID: uid,
            triggerText: "在吗",
            generatedReply: nil,
            confidence: 0.9,
            riskLevel: .low,
            action: .pending,
            aiReasoning: nil,
            sentAt: nil,
            createdAt: Date()
        )
    }

    // MARK: - Item 1: equality-guarded heartbeat publish

    @MainActor
    func testHeartbeatPublishSkipsUnchangedSnapshot() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        var emits = 0
        let cancellable = monitor.objectWillChange.sink { _ in emits += 1 }
        defer { cancellable.cancel() }

        var stats = AutopilotService.SessionStats()
        stats.totalSent = 2
        stats.totalPending = 1
        let queue = [pendingSend()]

        XCTAssertTrue(monitor.publishAutopilotHeartbeat(queue: queue, stats: stats, manuallyPaused: true))
        XCTAssertEqual(emits, 3, "the three changed slots publish once each")
        XCTAssertEqual(monitor.autopilotPendingSendQueue, queue)

        // What the 10 s tick does while autopilot sits idle: hand over the same
        // snapshot again. Nothing may be published the second time.
        XCTAssertFalse(monitor.publishAutopilotHeartbeat(queue: queue, stats: stats, manuallyPaused: true))
        XCTAssertEqual(emits, 3, "an unchanged snapshot must not fire objectWillChange")
    }

    @MainActor
    func testHeartbeatPublishEmitsForEachChangedSlot() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        let first = pendingSend(text: "好的")
        monitor.publishAutopilotHeartbeat(queue: [first], stats: .init(), manuallyPaused: false)

        var emits = 0
        let cancellable = monitor.objectWillChange.sink { _ in emits += 1 }
        defer { cancellable.cancel() }

        // Only the queue text changed — a countdown row edited in place must
        // still reach the UI.
        var edited = first
        edited.replyText = "我稍后回复你"
        XCTAssertTrue(monitor.publishAutopilotHeartbeat(queue: [edited], stats: .init(), manuallyPaused: false))
        XCTAssertEqual(emits, 1, "a changed reply text must publish exactly the queue slot")
    }

    // MARK: - Item 1: cadence + tolerance

    func testIdleHeartbeatSlowsDownButKeepsTolerance() {
        let countdown = ChatMonitor.safetySchedule(countdownActive: true)
        let idle = ChatMonitor.safetySchedule(countdownActive: false)

        XCTAssertEqual(countdown.interval, 10, "the on-screen countdown renders whole seconds, so its cadence must not change")
        XCTAssertEqual(idle.interval, 30, "with nothing queued the heartbeat should drop to a third of the wake-ups")
        XCTAssertEqual(countdown.tolerance, 2)
        XCTAssertGreaterThan(idle.tolerance, 0, "a zero-tolerance timer cannot be coalesced by the OS")
        XCTAssertEqual(idle.tolerance, 2)
    }

    @MainActor
    func testQueuingASendRestoresTheCountdownCadenceImmediately() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root); monitor.stop() }

        monitor.scheduleSafetyTimer(ChatMonitor.safetySchedule(countdownActive: false))
        XCTAssertEqual(monitor.activeSafetyTickInterval, 30)

        monitor.autopilotActive = true
        monitor.autopilotPendingSendQueue = [pendingSend()]
        XCTAssertEqual(monitor.activeSafetyTickInterval, 10,
                       "a queued send must retime the heartbeat at once, not at the next tick")

        monitor.autopilotPendingSendQueue = []
        XCTAssertEqual(monitor.activeSafetyTickInterval, 30,
                       "draining the queue must fall back to the idle cadence")
    }

    // MARK: - Item 12: autopilot display log only reloads when it can have changed

    @MainActor
    func testDisplayLogReloadIsGatedOnDirtyFlag() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        try store.insertAutopilotLog(logEntry(uid: "first"))
        monitor.reloadAIData()
        XCTAssertEqual(monitor.autopilotLog.map(\.triggerMsgUID), ["first"])

        // A row written while no monitor-side operation marked the log dirty.
        try store.insertAutopilotLog(logEntry(uid: "second"))

        monitor.reloadAIData()
        XCTAssertEqual(monitor.autopilotLog.map(\.triggerMsgUID), ["first"],
                       "reloadAIData must not re-query the display log when nothing changed")

        monitor.markAutopilotLogDirty()
        monitor.reloadAIData()
        XCTAssertEqual(Set(monitor.autopilotLog.map(\.triggerMsgUID)), ["first", "second"],
                       "a dirty log must be re-queried on the next reload")
    }
}
