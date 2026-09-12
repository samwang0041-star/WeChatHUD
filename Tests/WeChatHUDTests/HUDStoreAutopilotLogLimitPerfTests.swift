import XCTest
import SQLite3
@testable import WeChatHUD

/// The autopilot display list used to load every pending row in autopilot_log
/// on each refresh. It now bounds the pending half while keeping "pending
/// first, then the current session, deduped by id".
final class HUDStoreAutopilotLogLimitPerfTests: XCTestCase {

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "hudstore-autopilot-limit-" + UUID().uuidString + ".sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }

    @discardableResult
    private func insert(_ store: HUDStore,
                        index: Int,
                        sessionId: Int64,
                        action: AutopilotAction = .pending,
                        createdAt: Date) throws -> AutopilotLogEntry {
        let entry = AutopilotLogEntry(
            id: 0,
            sessionId: sessionId,
            chatUsername: "chat-" + String(index % 4),
            chatName: "会话" + String(index % 4),
            senderUsername: "peer",
            senderName: "对方",
            triggerMsgUID: "uid-" + String(index),
            triggerText: "第" + String(index) + "条",
            generatedReply: "回复" + String(index),
            confidence: 0.9,
            riskLevel: .low,
            action: action,
            aiReasoning: nil,
            sentAt: nil,
            createdAt: createdAt
        )
        try store.insertAutopilotLog(entry)
        return entry
    }

    func testDisplayLogBoundsPendingRowsWhileKeepingNewestFirst() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let session = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 {
            try insert(store, index: i, sessionId: session,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let limit = HUDStore.autopilotDisplayPendingLimit
        let displayed = store.loadAutopilotDisplayLog(sessionId: session)
        XCTAssertLessThanOrEqual(displayed.count, limit)

        // Pending rows are newest-first and the newest ones are the ones kept.
        let pending = displayed.filter { $0.action == .pending }
        XCTAssertEqual(pending.count, limit)
        XCTAssertEqual(pending.map(\.createdAt), pending.map(\.createdAt).sorted(by: >))
        XCTAssertEqual(pending.first?.triggerText, "第119条")

        // The public loader keeps its unbounded semantics for other callers.
        XCTAssertEqual(store.loadOpenAutopilotPendingItems().count, 120)
    }

    /// When the current session has no log of its own, the bounded pending
    /// query is the whole answer — so the newest leftovers are what the user
    /// sees, and the oldest ones are the ones dropped by the bound.
    func testDisplayLogKeepsNewestLeftoversFromEndedSessions() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let ended = try store.startAutopilotSession()
        try store.endAutopilotSession(id: ended)
        let current = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 {
            try insert(store, index: i, sessionId: ended,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let displayed = store.loadAutopilotDisplayLog(sessionId: current)
        XCTAssertEqual(displayed.count, HUDStore.autopilotDisplayPendingLimit)
        XCTAssertEqual(displayed.first?.triggerText, "第119条")
        XCTAssertEqual(displayed.last?.triggerText, "第70条")
        XCTAssertTrue(displayed.allSatisfy { $0.sessionId == ended },
                      "the current session has no rows, so every entry is an ended-session leftover")
    }

    func testSessionLogStillContributesPendingRowsWhenCurrentSessionIsFull() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        // 120 pending rows exist, all in an ended session, but this session
        // has a full log of its own. The pending half is bound to 50, the
        // session half to its own limit, and dedupe keeps the union unique.
        let ended = try store.startAutopilotSession()
        try store.endAutopilotSession(id: ended)
        let current = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // The ended-session leftovers are the newest pending rows, so the
        // bounded pending query is the one that surfaces them.
        let leftoverBase = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<120 {
            try insert(store, index: i, sessionId: ended, action: .pending,
                       createdAt: leftoverBase.addingTimeInterval(TimeInterval(i)))
        }
        for i in 200..<260 {
            try insert(store, index: i, sessionId: current, action: .pending,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let displayed = store.loadAutopilotDisplayLog(sessionId: current)
        // 50 pending leftovers + 50 current-session rows, all distinct.
        XCTAssertEqual(displayed.count, 100)
        XCTAssertEqual(Set(displayed.map(\.id)).count, displayed.count)
        // Pending leftovers lead, newest-first within their half; the session
        // half follows with the current session's own newest rows.
        XCTAssertEqual(Array(displayed.prefix(50)).map(\.triggerText),
                       (70...119).reversed().map { "第" + String($0) + "条" })
        XCTAssertEqual(Array(displayed.suffix(50)).map(\.triggerText),
                       (210...259).reversed().map { "第" + String($0) + "条" })
    }

    func testDisplayLogDedupesPendingRowsAlsoReturnedBySessionQuery() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let session = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // The pending rows are created LAST, so they are the newest rows and
        // the session query returns them again — dedupe must collapse them.
        for i in 0..<10 {
            try insert(store, index: i, sessionId: session, action: .sent,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }
        for i in 10..<20 {
            try insert(store, index: i, sessionId: session, action: .pending,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let displayed = store.loadAutopilotDisplayLog(sessionId: session)
        // 10 pending rows plus the session's newest 50 (which include those
        // same 10 rows) must collapse to 20, not 60.
        XCTAssertEqual(displayed.count, 20)
        XCTAssertEqual(Set(displayed.map(\.id)).count, displayed.count)
        // Pending rows come first, matching the pre-change ordering contract.
        XCTAssertTrue(displayed.prefix(10).allSatisfy { $0.action == .pending },
                      "the pending half still leads the list")
        XCTAssertEqual(displayed.first?.triggerText, "第19条")
    }

    /// The pending bound must apply on top of the relevantSince window, not
    /// replace it.
    func testDisplayLogHonoursRelevantSinceWithinThePendingBound() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let ended = try store.startAutopilotSession()
        try store.endAutopilotSession(id: ended)
        // No current-session rows, so the pending half is the whole result.
        let session = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 {
            try insert(store, index: i, sessionId: ended, action: .pending,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        XCTAssertEqual(store.loadOpenAutopilotPendingItems(relevantSince: 1_700_000_110).count, 10)

        // Only the newest 10 rows are inside the window, so the bound (50) is
        // not what trims the list here — the window is.
        let cutoff = Int(base.timeIntervalSince1970) + 110
        let displayed = store.loadAutopilotDisplayLog(sessionId: session, relevantSince: cutoff)
        XCTAssertEqual(displayed.count, 10)
        XCTAssertTrue(displayed.allSatisfy { Int($0.createdAt.timeIntervalSince1970) >= cutoff })
        XCTAssertEqual(displayed.first?.triggerText, "第119条")
        XCTAssertEqual(displayed.last?.triggerText, "第110条")
    }

    /// The bounded variant is the seam the display path uses; assert its
    /// contract directly so a regression cannot hide behind the dedupe step.
    func testBoundedVariantReturnsNewestRowsWithinTheLimit() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let session = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 {
            try insert(store, index: i, sessionId: session, action: .pending,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let bounded = store.loadOpenAutopilotPendingItems(relevantSince: nil, limit: 25)
        XCTAssertEqual(bounded.count, 25)
        XCTAssertEqual(bounded.map(\.triggerText),
                       (95...119).reversed().map { "第" + String($0) + "条" })

        // A nil limit keeps the unbounded contract for existing callers.
        XCTAssertEqual(store.loadOpenAutopilotPendingItems(relevantSince: nil, limit: nil).count, 120)
    }

    func testDisplayLogWithoutPendingRowsIsUnaffected() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let session = try store.startAutopilotSession()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<60 {
            try insert(store, index: i, sessionId: session, action: .sent,
                       createdAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let displayed = store.loadAutopilotDisplayLog(sessionId: session)
        XCTAssertEqual(displayed.count, 50, "the session half keeps its own default limit")
        XCTAssertEqual(displayed.first?.triggerText, "第59条")
    }
}
