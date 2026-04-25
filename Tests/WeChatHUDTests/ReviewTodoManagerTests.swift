import Testing
import Foundation
@testable import WeChatHUD

@Suite("ReviewTodoManager")
struct ReviewTodoManagerTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func makeTodo(
        runID: Int,
        content: String = "x",
        chat: String = "wxid_x",
        msgIDs: [String] = ["m1"],
        involved: [String] = [],
        deadline: Date? = nil
    ) -> ReviewTodo {
        ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: content,
            deadline: deadline, direction: .mine, involved: involved,
            sourceChatUsername: chat, sourceChatName: "chat",
            sourceMsgIDs: msgIDs, confidence: 0.8, status: .pending,
            createdAt: Date(timeIntervalSinceNow: -86400),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
    }

    @Test("Carry-forward dedupes by msg_ids overlap")
    func dedupeMsgIDsOverlap() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let oldID = store.insertReviewTodo(makeTodo(runID: runA, msgIDs: ["m100", "m200"]))!

        let cand = makeTodo(runID: runB, content: "different wording", msgIDs: ["m200", "m300"])
        let kept = await mgr.carryForward(prevRunID: runA, newRunID: runB, newCandidates: [cand])
        #expect(kept.isEmpty)
        let bumped = store.todos(for: runB, statuses: [.pending])
        #expect(bumped.count == 1)
        #expect(bumped.first?.id == oldID)
        #expect(bumped.first?.carryCount == 1)
    }

    @Test("Carry-forward dedupes by Jaccard content similarity")
    func dedupeJaccard() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        _ = store.insertReviewTodo(makeTodo(runID: runA, content: "周一上线 v2 砍掉地图", msgIDs: ["m1"]))!

        let cand = makeTodo(runID: runB, content: "v2 周一上线 砍地图", msgIDs: ["m99"])
        let kept = await mgr.carryForward(prevRunID: runA, newRunID: runB, newCandidates: [cand])
        #expect(kept.isEmpty)
    }

    @Test("Carry-forward keeps brand-new candidates")
    func keepsNew() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let trulyNew = makeTodo(runID: runB, content: "completely new", chat: "wxid_y", msgIDs: ["m42"])
        let kept = await mgr.carryForward(prevRunID: 999, newRunID: runB, newCandidates: [trulyNew])
        #expect(kept.count == 1)
        #expect(kept.first?.content == "completely new")
    }

    @Test("Carry-forward bumps prev pending todos that are not re-extracted")
    func unmatchedPrevStillCarried() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        _ = store.insertReviewTodo(makeTodo(runID: runA, content: "old A", msgIDs: ["m500"]))!
        // No candidates this run.
        let kept = await mgr.carryForward(prevRunID: runA, newRunID: runB, newCandidates: [])
        #expect(kept.isEmpty)
        // Old todo should still be pending and bumped to runB.
        let stillThere = store.todos(for: runB, statuses: [.pending])
        #expect(stillThere.count == 1)
        #expect(stillThere.first?.carryCount == 1)
    }

    @Test("suggestArchive surfaces todos with carryCount ≥ threshold")
    func suggestArchive() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        var stale = makeTodo(runID: runID, content: "old")
        stale = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: stale.content,
            deadline: nil, direction: stale.direction, involved: stale.involved,
            sourceChatUsername: stale.sourceChatUsername, sourceChatName: stale.sourceChatName,
            sourceMsgIDs: stale.sourceMsgIDs, confidence: stale.confidence,
            status: .pending, createdAt: stale.createdAt,
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 4, lastUserActionAt: nil
        )
        _ = store.insertReviewTodo(stale)
        let suggestions = await mgr.suggestArchiveStaleTodos(olderThanWeeks: 4)
        #expect(suggestions.count == 1)
    }

    @Test("State transitions: complete / snooze / delegate / notMine / archive")
    func stateTransitions() async throws {
        let store = try tempStore()
        let mgr = ReviewTodoManager(store: store)
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        let id1 = store.insertReviewTodo(makeTodo(runID: runID, content: "complete me"))!
        await mgr.markCompleted(todoID: id1)
        #expect(store.todos(for: runID, statuses: [.completed]).count == 1)

        let id2 = store.insertReviewTodo(makeTodo(runID: runID, content: "snooze me"))!
        await mgr.snooze(todoID: id2, until: Date(timeIntervalSinceNow: 86400))
        #expect(store.todos(for: runID, statuses: [.snoozed]).count == 1)

        let id3 = store.insertReviewTodo(makeTodo(runID: runID, content: "delegate me"))!
        await mgr.delegate(todoID: id3, to: "Bob")
        let delegated = store.todos(for: runID, statuses: [.delegated]).first
        #expect(delegated?.delegatedTo == "Bob")

        let id4 = store.insertReviewTodo(makeTodo(runID: runID, content: "not mine"))!
        await mgr.markNotMine(todoID: id4)
        #expect(store.todos(for: runID, statuses: [.notMine]).count == 1)

        let id5 = store.insertReviewTodo(makeTodo(runID: runID, content: "archive me"))!
        await mgr.archive(todoID: id5)
        #expect(store.todos(for: runID, statuses: [.archived]).count == 1)
    }
}

@Suite("UndoStore")
struct UndoStoreTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    @Test("record + popLatest returns most recent entry")
    func recordAndPop() async throws {
        let store = try tempStore()
        let undo = UndoStore(store: store)
        struct Snap: Codable { let v: Int }
        await undo.record(targetTable: "review_todos", targetID: 1, operation: .statusChange,
                          before: Snap(v: 0), after: Snap(v: 1))
        await undo.record(targetTable: "review_todos", targetID: 2, operation: .statusChange,
                          before: Snap(v: 5), after: Snap(v: 6))
        let popped = await undo.popLatest()
        #expect(popped?.targetID == 2)
        let popped2 = await undo.popLatest()
        #expect(popped2?.targetID == 1)
        let popped3 = await undo.popLatest()
        #expect(popped3 == nil)
    }
}

@Suite("DataLedger")
struct DataLedgerTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    @Test("recordBatch persists + recent retrieves")
    func batchAndRecent() async throws {
        let store = try tempStore()
        let ledger = DataLedger(store: store)
        let entries = (0..<3).map {
            AILedgerEntry(
                id: 0, ts: Date(), provider: "openai", model: "gpt-5.4",
                purpose: .chatAnalysis, chatCount: 1, msgCount: 50,
                byteCount: $0 * 100, tokenIn: nil, tokenOut: nil, redacted: true
            )
        }
        await ledger.recordBatch(entries)
        let recent = await ledger.recent(days: 7)
        #expect(recent.count == 3)
    }

    @Test("CSV export roundtrip")
    func csvExport() async throws {
        let store = try tempStore()
        let ledger = DataLedger(store: store)
        let entry = AILedgerEntry(
            id: 0, ts: Date(), provider: "openai-codex", model: "gpt-5.4",
            purpose: .groupScreen, chatCount: 18, msgCount: 360,
            byteCount: 12000, tokenIn: 1500, tokenOut: 200, redacted: true
        )
        await ledger.recordBatch([entry])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).csv")
        try await ledger.exportCSV(to: url, days: 1)

        let csv = try String(contentsOf: url, encoding: .utf8)
        #expect(csv.contains("openai-codex"))
        #expect(csv.contains("gpt-5.4"))
        #expect(csv.contains("group_screen"))
        #expect(csv.contains("12000"))
        try? FileManager.default.removeItem(at: url)
    }
}
