import Testing
import Foundation
import SQLite3
@testable import WeChatHUD

@Suite("HUDStore Retrospective")
struct HUDStoreRetrospectiveTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    @Test("Migration creates 7 tables idempotently")
    func migrationIdempotent() throws {
        let store = try tempStore()
        // open() already ran migration; explicit re-call should not throw.
        store.migrateRetrospective()
        // Verify by inserting a row.
        let runID = store.insertReviewRun(rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(), chatCount: 5)
        #expect(runID != nil)
    }

    @Test("insertReviewRun starts in running state")
    func insertRunRunning() throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 3)!
        let run = store.runByID(runID)
        #expect(run?.status == .running)
        #expect(run?.chatCount == 3)
        #expect(run?.progressChatCount == 0)
    }

    @Test("finalizeReviewRun writes summary + posts notification")
    func finalizeWritesAndPosts() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        // Set up observer BEFORE the finalize call.
        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: .retrospectiveLiveUpdate, object: nil, queue: nil
            ) { note in
                if let kind = note.userInfo?["kind"] as? String, kind == "completed" {
                    if let token { NotificationCenter.default.removeObserver(token) }
                    continuation.resume(returning: true)
                }
            }
            store.finalizeReviewRun(
                runID: runID, status: .completed,
                summaryTop3: [SummaryItem(text: "x", evidenceHighlightIDs: [1])],
                summaryRisk: nil, summaryMissed: nil, msgCount: 50, failedChats: []
            )
        }
        #expect(received == true)

        let run = store.runByID(runID)
        #expect(run?.status == .completed)
        #expect(run?.summaryTop3.count == 1)
        #expect(run?.summaryTop3.first?.text == "x")
    }

    @Test("reapStaleRuns marks old running rows failed")
    func reapStale() throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(
            rangeStart: Date(timeIntervalSinceNow: -3600),
            rangeEnd: Date(timeIntervalSinceNow: -3600),
            chatCount: 1
        )!
        // Backdate generated_at so the row is "stale" relative to the
        // 35-minute default cutoff.
        store.executeUpdate("UPDATE review_runs SET generated_at = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970 - 3600))
            sqlite3_bind_int(stmt, 2, Int32(runID))
        }
        let count = store.reapStaleRuns(olderThanSeconds: 60)
        #expect(count == 1)
        #expect(store.runByID(runID)?.status == .failed)
    }

    @Test("highlight + todo insert posts notifications")
    func liveUpdates() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        let seenLock = NSLock()
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .retrospectiveLiveUpdate, object: nil, queue: nil
        ) { note in
            if let kind = note.userInfo?["kind"] as? String {
                seenLock.lock(); seen.append(kind); seenLock.unlock()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let h = ReviewHighlight(
            id: 0, runID: runID, date: Date(), summary: "test", quotedSnippet: nil,
            involved: ["A1"], sourceChatUsername: "wxid_x", sourceChatName: "chat",
            relation: .peer, sourceMsgIDs: ["m42"], confidence: 0.9,
            category: .decision, flaggedUncertain: false
        )
        store.insertReviewHighlight(h)

        let t = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: "do thing",
            deadline: nil, direction: .mine, involved: ["A1"],
            sourceChatUsername: "wxid_x", sourceChatName: "chat",
            sourceMsgIDs: ["m42"], confidence: 0.8, status: .pending,
            createdAt: Date(), completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        store.insertReviewTodo(t)

        try? await Task.sleep(nanoseconds: 100_000_000)
        seenLock.lock()
        let snapshot = seen
        seenLock.unlock()
        #expect(snapshot.contains("highlight"))
        #expect(snapshot.contains("todo"))
    }

    @Test("updateTodoStatus moves through state machine")
    func todoStateMachine() throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let t = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: "x",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "u", sourceChatName: "n", sourceMsgIDs: [],
            confidence: 0.7, status: .pending, createdAt: Date(),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        let id = store.insertReviewTodo(t)!
        store.updateTodoStatus(todoID: id, status: .completed, completedAt: Date())
        let after = store.todos(for: runID, statuses: [.completed]).first
        #expect(after?.status == .completed)
        #expect(after?.completedAt != nil)
    }

    @Test("bumpTodoCarry increments carry_count and updates last_run_id")
    func carryBump() throws {
        let store = try tempStore()
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let t = ReviewTodo(
            id: 0, originRunID: runA, lastRunID: runA, content: "x",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "u", sourceChatName: "n", sourceMsgIDs: [],
            confidence: 0.7, status: .pending, createdAt: Date(),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        let id = store.insertReviewTodo(t)!
        store.bumpTodoCarry(todoID: id, newRunID: runB)
        let after = store.todos(for: runB, statuses: [.pending]).first
        #expect(after?.lastRunID == runB)
        #expect(after?.carryCount == 1)
    }

    @Test("recordLedgerBatch wraps in transaction and persists")
    func ledgerBatch() throws {
        let store = try tempStore()
        let entries = (0..<5).map { i in
            AILedgerEntry(
                id: 0, ts: Date(), provider: "openai", model: "gpt-5.4",
                purpose: .chatAnalysis, chatCount: 1, msgCount: 100,
                byteCount: i * 1000, tokenIn: nil, tokenOut: nil, redacted: true
            )
        }
        store.recordLedgerBatch(entries)
        let recent = store.recentLedger(days: 7)
        #expect(recent.count == 5)
    }

    @Test("group scope policy upsert + query")
    func scopePolicy() throws {
        let store = try tempStore()
        let policy = GroupScopePolicy(
            chatUsername: "wxid_test@chatroom",
            decision: .include,
            source: .ai,
            decidedAt: Date(),
            sampleHash: "hash123",
            userAuthorized: true
        )
        store.upsertGroupScopePolicy(policy)
        let read = store.groupScopePolicy(chatUsername: "wxid_test@chatroom")
        #expect(read?.decision == .include)
        #expect(read?.source == .ai)
        #expect(read?.userAuthorized == true)

        // Upsert with new decision should overwrite.
        let updated = GroupScopePolicy(
            chatUsername: "wxid_test@chatroom",
            decision: .exclude,
            source: .user,
            decidedAt: Date(),
            sampleHash: nil,
            userAuthorized: true
        )
        store.upsertGroupScopePolicy(updated)
        let read2 = store.groupScopePolicy(chatUsername: "wxid_test@chatroom")
        #expect(read2?.decision == .exclude)
        #expect(read2?.source == .user)
    }

    @Test("dismissal records + hasDismissal within window")
    func dismissals() throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let t = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: "x",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "u", sourceChatName: "n", sourceMsgIDs: [],
            confidence: 0.5, status: .pending, createdAt: Date(),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        let todoID = store.insertReviewTodo(t)!
        let dismissal = RedBannerDismissal(
            id: 0, todoID: todoID, action: .snoozed,
            reasonText: nil, snoozedTo: Date().addingTimeInterval(86400),
            createdAt: Date()
        )
        store.recordDismissal(dismissal)
        #expect(store.hasDismissal(todoID: todoID, validForHours: 24) == true)
        #expect(store.dismissalCount(todoID: todoID) == 1)
    }

    @Test("undo push + pop returns latest first")
    func undoStack() throws {
        let store = try tempStore()
        let e1 = UndoEntry(
            id: 0, ts: Date().addingTimeInterval(-10),
            targetTable: "review_todos", targetID: 1,
            operation: .statusChange,
            payloadBefore: "{\"old\":true}", payloadAfter: "{\"new\":true}"
        )
        let e2 = UndoEntry(
            id: 0, ts: Date(),
            targetTable: "review_todos", targetID: 2,
            operation: .statusChange,
            payloadBefore: "{\"a\":1}", payloadAfter: "{\"a\":2}"
        )
        _ = store.pushUndo(e1)
        _ = store.pushUndo(e2)
        let popped = store.popLatestUndo()
        #expect(popped?.targetID == 2)
        #expect(popped?.payloadBefore == "{\"a\":1}")
        // Pop again should return e1 (e2 was deleted).
        let popped2 = store.popLatestUndo()
        #expect(popped2?.targetID == 1)
    }

    @Test("ledger CSV-like roundtrip preserves provider/model/purpose")
    func ledgerRoundtrip() throws {
        let store = try tempStore()
        let entry = AILedgerEntry(
            id: 0, ts: Date(),
            provider: "openai-codex", model: "gpt-5.4",
            purpose: .groupScreen, chatCount: 18, msgCount: 360,
            byteCount: 12_000, tokenIn: 1500, tokenOut: 200, redacted: true
        )
        store.recordLedgerBatch([entry])
        let read = store.recentLedger(days: 1).first
        #expect(read?.provider == "openai-codex")
        #expect(read?.model == "gpt-5.4")
        #expect(read?.purpose == .groupScreen)
        #expect(read?.byteCount == 12_000)
        #expect(read?.tokenIn == 1500)
    }
}
