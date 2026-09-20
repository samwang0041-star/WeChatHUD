import XCTest
import SQLite3
@testable import WeChatHUD

/// §231/§234: `AutopilotService.start()` recovered the live session with the lossy
/// `currentAutopilotSession()`, whose nil means 「没有活动会话」 and 「这次读不到」 alike.
/// The fallback creates a *fresh* session, so a transient read error reset
/// `sessionSent` to 0 — and `maxSendsPerSession` is the ceiling that keeps autopilot
/// from typing at a person on its own.
final class AutopilotSessionRecoveryHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "session-recovery-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
    }

    private func freshService() -> AutopilotService {
        AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    private func sessionRowCount() throws -> Int {
        let n: Int? = try store.queryOneThrowing(
            "SELECT COUNT(*) FROM autopilot_sessions", bind: { _ in },
            decode: { stmt in Int(sqlite3_column_int64(stmt, 0)) })
        return n ?? -1
    }

    /// The read fails while writes still work: `startAutopilotSession()` only inserts
    /// `started_at`, so renaming `total_sent` breaks exactly the recovery SELECT.
    private func breakSessionRead() throws {
        try store.exec("ALTER TABLE autopilot_sessions RENAME COLUMN total_sent TO total_sent_x")
    }

    private func healSessionRead() throws {
        try store.exec("ALTER TABLE autopilot_sessions RENAME COLUMN total_sent_x TO total_sent")
    }

    func testUnreadableSessionDoesNotQuietlySpendTheSendCeilingTwice() async throws {
        try await service.start()
        let sidA = try XCTUnwrap(store.currentAutopilotSession()).id
        try store.updateAutopilotSessionCounts(id: sidA, handled: 5, pending: 1, sent: 40)

        try breakSessionRead()
        let revived = freshService()
        var thrown: Error?
        do {
            try await revived.start()
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "读不到活动会话时必须报错，不能当「没有会话」再开一个")
        let stillDormant = await revived.isActive
        XCTAssertFalse(stillDormant, "报错之后不能自称已经开启")
        try healSessionRead()

        XCTAssertEqual(try sessionRowCount(), 1, "一次读失败不该悄悄开出第二个会话")
        let live = try XCTUnwrap(store.currentAutopilotSession())
        XCTAssertEqual(live.id, sidA)
        XCTAssertEqual(live.totalSent, 40, "旧会话的计数不能因为开出新会话而被弃用")
    }

    /// Positive control: a healthy restart still resumes the same session and carries
    /// the counters — the fix must not turn recovery into 「always a fresh session」.
    func testHealthyRestartStillResumesTheSameSession() async throws {
        try await service.start()
        let sidA = try XCTUnwrap(store.currentAutopilotSession()).id
        try store.updateAutopilotSessionCounts(id: sidA, handled: 5, pending: 1, sent: 40)

        let revived = freshService()
        try await revived.start()
        XCTAssertEqual(try sessionRowCount(), 1)
        let stats = await revived.sessionStats
        XCTAssertEqual(stats.totalSent, 40, "恢复必须沿用既有会话的已发送数，上限才会继续生效")
        try? await revived.stop()
    }
}
