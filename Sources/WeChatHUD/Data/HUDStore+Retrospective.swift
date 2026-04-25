import Foundation
import SQLite3

// MARK: - Migration

extension HUDStore {

    /// Idempotent migration for the 7 retrospective tables + 5 indexes.
    /// Called from `HUDStore.open()` (Plan M1.2). Uses `IF NOT EXISTS`
    /// throughout to match the existing best-effort migration pattern.
    nonisolated func migrateRetrospective() {
        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS review_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                range_start INTEGER NOT NULL,
                range_end INTEGER NOT NULL,
                generated_at INTEGER NOT NULL,
                summary_top3 TEXT,
                summary_risk TEXT,
                summary_missed TEXT,
                chat_count INTEGER NOT NULL,
                progress_chat_count INTEGER NOT NULL DEFAULT 0,
                msg_count INTEGER NOT NULL DEFAULT 0,
                failed_chats TEXT,
                status TEXT NOT NULL
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS review_todos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                origin_run_id INTEGER NOT NULL,
                last_run_id INTEGER NOT NULL,
                content TEXT NOT NULL,
                deadline INTEGER,
                direction TEXT NOT NULL,
                involved TEXT,
                source_chat_username TEXT NOT NULL,
                source_chat_name TEXT NOT NULL,
                source_msg_ids TEXT NOT NULL,
                confidence REAL NOT NULL,
                status TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                completed_at INTEGER,
                snoozed_to INTEGER,
                delegated_to TEXT,
                carry_count INTEGER NOT NULL DEFAULT 0,
                last_user_action_at INTEGER
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS review_highlights (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL,
                date INTEGER NOT NULL,
                summary TEXT NOT NULL,
                quoted_snippet TEXT,
                involved TEXT,
                source_chat_username TEXT NOT NULL,
                source_chat_name TEXT NOT NULL,
                relation TEXT,
                source_msg_ids TEXT NOT NULL,
                confidence REAL NOT NULL,
                category TEXT NOT NULL,
                flagged_uncertain INTEGER NOT NULL DEFAULT 0
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS group_scope_policy (
                chat_username TEXT PRIMARY KEY,
                decision TEXT NOT NULL,
                source TEXT NOT NULL,
                decided_at INTEGER NOT NULL,
                sample_hash TEXT,
                user_authorized INTEGER NOT NULL DEFAULT 0
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS ai_data_ledger (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                purpose TEXT NOT NULL,
                chat_count INTEGER,
                msg_count INTEGER,
                byte_count INTEGER NOT NULL,
                token_in INTEGER,
                token_out INTEGER,
                redacted INTEGER NOT NULL DEFAULT 1
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS red_banner_dismissals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                todo_id INTEGER NOT NULL,
                action TEXT NOT NULL,
                reason_text TEXT,
                snoozed_to INTEGER,
                created_at INTEGER NOT NULL
            );
        """)

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS undo_stack (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                target_table TEXT NOT NULL,
                target_id INTEGER NOT NULL,
                operation TEXT NOT NULL,
                payload_before TEXT NOT NULL,
                payload_after TEXT NOT NULL
            );
        """)

        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_review_todos_status_run ON review_todos(status, last_run_id);")
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_review_highlights_run ON review_highlights(run_id);")
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_ai_data_ledger_ts ON ai_data_ledger(ts);")
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_undo_stack_ts ON undo_stack(ts);")
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_review_runs_status_gen ON review_runs(status, generated_at);")
    }
}

// MARK: - review_runs CRUD (Plan M1.3)

extension HUDStore {

    nonisolated func insertReviewRun(rangeStart: Date, rangeEnd: Date, chatCount: Int) -> Int? {
        let sql = """
            INSERT INTO review_runs(range_start, range_end, generated_at, chat_count, status)
            VALUES(?, ?, ?, ?, 'running');
        """
        return executeInsert(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(rangeStart.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(rangeEnd.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt, 4, Int32(chatCount))
        }
    }

    nonisolated func updateReviewRunProgress(runID: Int, completedChats: Int) {
        let sql = "UPDATE review_runs SET progress_chat_count = ? WHERE id = ?;"
        executeUpdate(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(completedChats))
            sqlite3_bind_int(stmt, 2, Int32(runID))
        }
        // Spec §6.6: post "progress" kind for live UI subscribers
        NotificationCenter.default.post(
            name: .retrospectiveLiveUpdate,
            object: nil,
            userInfo: ["runId": runID, "kind": "progress", "completed": completedChats]
        )
    }

    nonisolated func finalizeReviewRun(
        runID: Int,
        status: ReviewRunStatus,
        summaryTop3: [SummaryItem],
        summaryRisk: SummaryItem?,
        summaryMissed: SummaryItem?,
        msgCount: Int,
        failedChats: [String]
    ) {
        let encoder = JSONEncoder()
        let top3JSON = (try? String(data: encoder.encode(summaryTop3), encoding: .utf8)) ?? "[]"
        let riskJSON = summaryRisk.flatMap { try? String(data: encoder.encode($0), encoding: .utf8) }
        let missedJSON = summaryMissed.flatMap { try? String(data: encoder.encode($0), encoding: .utf8) }
        let failedJSON = (try? String(data: encoder.encode(failedChats), encoding: .utf8)) ?? "[]"

        let sql = """
            UPDATE review_runs
            SET status = ?, summary_top3 = ?, summary_risk = ?, summary_missed = ?,
                msg_count = ?, failed_chats = ?, generated_at = ?
            WHERE id = ?;
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 2, top3JSON, -1, HUDStore.sqliteTransient)
            if let r = riskJSON { sqlite3_bind_text(stmt, 3, r, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 3) }
            if let m = missedJSON { sqlite3_bind_text(stmt, 4, m, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int(stmt, 5, Int32(msgCount))
            sqlite3_bind_text(stmt, 6, failedJSON, -1, HUDStore.sqliteTransient)
            sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt, 8, Int32(runID))
        }
        NotificationCenter.default.post(
            name: .retrospectiveLiveUpdate,
            object: nil,
            userInfo: ["runId": runID, "kind": "completed"]
        )
    }

    /// Crash recovery: mark all 'running' rows older than threshold as failed.
    /// Called from HUDStore.open() (Plan M1.6).
    @discardableResult
    nonisolated func reapStaleRuns(olderThanSeconds: TimeInterval = 35 * 60) -> Int {
        let cutoff = Int64(Date().timeIntervalSince1970 - olderThanSeconds)
        let sql = """
            UPDATE review_runs
            SET status = 'failed',
                failed_chats = COALESCE(failed_chats, '[]')
            WHERE status = 'running' AND generated_at < ?;
        """
        return executeUpdate(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }
    }

    nonisolated func latestCompletedRun() -> ReviewRun? {
        let sql = """
            SELECT id, range_start, range_end, generated_at, summary_top3, summary_risk,
                   summary_missed, chat_count, progress_chat_count, msg_count, failed_chats, status
            FROM review_runs WHERE status IN ('completed', 'partial')
            ORDER BY generated_at DESC LIMIT 1;
        """
        return queryOne(sql, bind: { _ in }, decode: decodeReviewRun)
    }

    nonisolated func runByID(_ runID: Int) -> ReviewRun? {
        let sql = """
            SELECT id, range_start, range_end, generated_at, summary_top3, summary_risk,
                   summary_missed, chat_count, progress_chat_count, msg_count, failed_chats, status
            FROM review_runs WHERE id = ?;
        """
        return queryOne(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(runID))
        }, decode: decodeReviewRun)
    }

    private nonisolated func decodeReviewRun(_ stmt: OpaquePointer?) -> ReviewRun? {
        guard let stmt else { return nil }
        let decoder = JSONDecoder()
        let top3Text = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? "[]"
        let riskText = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
        let missedText = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) }
        let failedText = sqlite3_column_text(stmt, 10).flatMap { String(cString: $0) } ?? "[]"
        let statusRaw = sqlite3_column_text(stmt, 11).flatMap { String(cString: $0) } ?? "failed"

        let top3 = (try? decoder.decode([SummaryItem].self, from: Data(top3Text.utf8))) ?? []
        let risk = riskText.flatMap { try? decoder.decode(SummaryItem.self, from: Data($0.utf8)) }
        let missed = missedText.flatMap { try? decoder.decode(SummaryItem.self, from: Data($0.utf8)) }
        let failed = (try? decoder.decode([String].self, from: Data(failedText.utf8))) ?? []
        let status = ReviewRunStatus(rawValue: statusRaw) ?? .failed

        return ReviewRun(
            id: Int(sqlite3_column_int(stmt, 0)),
            rangeStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
            rangeEnd: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2))),
            generatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3))),
            summaryTop3: top3,
            summaryRisk: risk,
            summaryMissed: missed,
            chatCount: Int(sqlite3_column_int(stmt, 7)),
            progressChatCount: Int(sqlite3_column_int(stmt, 8)),
            msgCount: Int(sqlite3_column_int(stmt, 9)),
            failedChats: failed,
            status: status
        )
    }
}

// MARK: - review_highlights CRUD (Plan M1.4)

extension HUDStore {

    @discardableResult
    nonisolated func insertReviewHighlight(_ h: ReviewHighlight) -> Int? {
        let encoder = JSONEncoder()
        let involvedJSON = (try? String(data: encoder.encode(h.involved), encoding: .utf8)) ?? "[]"
        let msgIDsJSON = (try? String(data: encoder.encode(h.sourceMsgIDs), encoding: .utf8)) ?? "[]"

        let sql = """
            INSERT INTO review_highlights(
                run_id, date, summary, quoted_snippet, involved,
                source_chat_username, source_chat_name, relation,
                source_msg_ids, confidence, category, flagged_uncertain
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let id = executeInsert(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(h.runID))
            sqlite3_bind_int64(stmt, 2, Int64(h.date.timeIntervalSince1970))
            sqlite3_bind_text(stmt, 3, h.summary, -1, HUDStore.sqliteTransient)
            if let q = h.quotedSnippet { sqlite3_bind_text(stmt, 4, q, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_text(stmt, 5, involvedJSON, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 6, h.sourceChatUsername, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 7, h.sourceChatName, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 8, h.relation.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 9, msgIDsJSON, -1, HUDStore.sqliteTransient)
            sqlite3_bind_double(stmt, 10, h.confidence)
            sqlite3_bind_text(stmt, 11, h.category.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_int(stmt, 12, Int32(h.flaggedUncertain ? 1 : 0))
        }
        if let id {
            NotificationCenter.default.post(
                name: .retrospectiveLiveUpdate,
                object: nil,
                userInfo: ["runId": h.runID, "kind": "highlight", "id": id]
            )
        }
        return id
    }

    nonisolated func highlights(for runID: Int) -> [ReviewHighlight] {
        let sql = """
            SELECT id, run_id, date, summary, quoted_snippet, involved,
                   source_chat_username, source_chat_name, relation,
                   source_msg_ids, confidence, category, flagged_uncertain
            FROM review_highlights
            WHERE run_id = ?
            ORDER BY date DESC;
        """
        return queryAll(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(runID))
        }, decode: decodeReviewHighlight)
    }

    private nonisolated func decodeReviewHighlight(_ stmt: OpaquePointer?) -> ReviewHighlight? {
        guard let stmt else { return nil }
        let decoder = JSONDecoder()
        let involvedText = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? "[]"
        let msgIDsText = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? "[]"
        let involved = (try? decoder.decode([String].self, from: Data(involvedText.utf8))) ?? []
        let msgIDs = (try? decoder.decode([String].self, from: Data(msgIDsText.utf8))) ?? []
        let categoryRaw = sqlite3_column_text(stmt, 11).flatMap { String(cString: $0) } ?? "discussion"
        let relationRaw = sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) } ?? "unknown"

        return ReviewHighlight(
            id: Int(sqlite3_column_int(stmt, 0)),
            runID: Int(sqlite3_column_int(stmt, 1)),
            date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2))),
            summary: sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? "",
            quotedSnippet: sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) },
            involved: involved,
            sourceChatUsername: sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "",
            sourceChatName: sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) } ?? "",
            relation: Relation(rawValue: relationRaw) ?? .unknown,
            sourceMsgIDs: msgIDs,
            confidence: sqlite3_column_double(stmt, 10),
            category: HighlightCategory(rawValue: categoryRaw) ?? .discussion,
            flaggedUncertain: sqlite3_column_int(stmt, 12) != 0
        )
    }
}

// MARK: - review_todos CRUD (Plan M1.4)

extension HUDStore {

    @discardableResult
    nonisolated func insertReviewTodo(_ t: ReviewTodo) -> Int? {
        let encoder = JSONEncoder()
        let involvedJSON = (try? String(data: encoder.encode(t.involved), encoding: .utf8)) ?? "[]"
        let msgIDsJSON = (try? String(data: encoder.encode(t.sourceMsgIDs), encoding: .utf8)) ?? "[]"

        let sql = """
            INSERT INTO review_todos(
                origin_run_id, last_run_id, content, deadline, direction, involved,
                source_chat_username, source_chat_name, source_msg_ids, confidence,
                status, created_at, completed_at, snoozed_to, delegated_to,
                carry_count, last_user_action_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let id = executeInsert(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(t.originRunID))
            sqlite3_bind_int(stmt, 2, Int32(t.lastRunID))
            sqlite3_bind_text(stmt, 3, t.content, -1, HUDStore.sqliteTransient)
            if let d = t.deadline { sqlite3_bind_int64(stmt, 4, Int64(d.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_text(stmt, 5, t.direction.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 6, involvedJSON, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 7, t.sourceChatUsername, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 8, t.sourceChatName, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 9, msgIDsJSON, -1, HUDStore.sqliteTransient)
            sqlite3_bind_double(stmt, 10, t.confidence)
            sqlite3_bind_text(stmt, 11, t.status.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_int64(stmt, 12, Int64(t.createdAt.timeIntervalSince1970))
            if let c = t.completedAt { sqlite3_bind_int64(stmt, 13, Int64(c.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 13) }
            if let s = t.snoozedTo { sqlite3_bind_int64(stmt, 14, Int64(s.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 14) }
            if let d = t.delegatedTo { sqlite3_bind_text(stmt, 15, d, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 15) }
            sqlite3_bind_int(stmt, 16, Int32(t.carryCount))
            if let l = t.lastUserActionAt { sqlite3_bind_int64(stmt, 17, Int64(l.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 17) }
        }
        if let id {
            NotificationCenter.default.post(
                name: .retrospectiveLiveUpdate,
                object: nil,
                userInfo: ["runId": t.lastRunID, "kind": "todo", "id": id]
            )
        }
        return id
    }

    /// Updates a todo's status. Non-status columns use COALESCE — passing
    /// nil preserves the prior value (e.g., transitioning out of `snoozed`
    /// won't wipe `snoozed_to`). Posts a `kind: "todo"` NotificationCenter
    /// event so live UI subscribers refresh (Spec §6.6).
    ///
    /// To explicitly clear a column, use a follow-up direct update — this
    /// path is purely state-machine driven (markCompleted / snooze /
    /// delegate / archive / notMine).
    nonisolated func updateTodoStatus(
        todoID: Int,
        status: TodoStatus,
        completedAt: Date? = nil,
        snoozedTo: Date? = nil,
        delegatedTo: String? = nil
    ) {
        let sql = """
            UPDATE review_todos
            SET status = ?,
                completed_at = COALESCE(?, completed_at),
                snoozed_to = COALESCE(?, snoozed_to),
                delegated_to = COALESCE(?, delegated_to),
                last_user_action_at = ?
            WHERE id = ?;
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, HUDStore.sqliteTransient)
            if let c = completedAt { sqlite3_bind_int64(stmt, 2, Int64(c.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 2) }
            if let s = snoozedTo { sqlite3_bind_int64(stmt, 3, Int64(s.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 3) }
            if let d = delegatedTo { sqlite3_bind_text(stmt, 4, d, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int64(stmt, 5, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt, 6, Int32(todoID))
        }
        // Look up the todo's last_run_id so subscribers know which run to refresh.
        let runIDLookup = "SELECT last_run_id FROM review_todos WHERE id = ?;"
        let runID: Int? = queryOne(runIDLookup, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(todoID))
        }, decode: { stmt in
            guard let stmt else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        })
        if let runID {
            NotificationCenter.default.post(
                name: .retrospectiveLiveUpdate,
                object: nil,
                userInfo: ["runId": runID, "kind": "todo", "id": todoID]
            )
        }
    }

    nonisolated func bumpTodoCarry(todoID: Int, newRunID: Int) {
        let sql = """
            UPDATE review_todos
            SET last_run_id = ?, carry_count = carry_count + 1
            WHERE id = ?;
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(newRunID))
            sqlite3_bind_int(stmt, 2, Int32(todoID))
        }
    }

    nonisolated func todos(for runID: Int, statuses: [TodoStatus]? = nil) -> [ReviewTodo] {
        let statusClause: String
        if let statuses, !statuses.isEmpty {
            let placeholders = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            statusClause = " AND status IN (\(placeholders))"
        } else {
            statusClause = ""
        }
        let sql = """
            SELECT id, origin_run_id, last_run_id, content, deadline, direction, involved,
                   source_chat_username, source_chat_name, source_msg_ids, confidence, status,
                   created_at, completed_at, snoozed_to, delegated_to, carry_count, last_user_action_at
            FROM review_todos
            WHERE last_run_id = ?\(statusClause)
            ORDER BY confidence DESC, deadline ASC;
        """
        return queryAll(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(runID))
        }, decode: decodeReviewTodo)
    }

    nonisolated func pendingTodos(direction: TodoDirection? = nil, since: Date? = nil) -> [ReviewTodo] {
        var sql = """
            SELECT id, origin_run_id, last_run_id, content, deadline, direction, involved,
                   source_chat_username, source_chat_name, source_msg_ids, confidence, status,
                   created_at, completed_at, snoozed_to, delegated_to, carry_count, last_user_action_at
            FROM review_todos WHERE status = 'pending'
        """
        if direction != nil { sql += " AND direction = ?" }
        if since != nil { sql += " AND created_at >= ?" }
        sql += " ORDER BY deadline ASC;"

        return queryAll(sql, bind: { stmt in
            var idx: Int32 = 1
            if let direction {
                sqlite3_bind_text(stmt, idx, direction.rawValue, -1, HUDStore.sqliteTransient); idx += 1
            }
            if let since {
                sqlite3_bind_int64(stmt, idx, Int64(since.timeIntervalSince1970)); idx += 1
            }
        }, decode: decodeReviewTodo)
    }

    private nonisolated func decodeReviewTodo(_ stmt: OpaquePointer?) -> ReviewTodo? {
        guard let stmt else { return nil }
        let decoder = JSONDecoder()
        let involvedText = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "[]"
        let msgIDsText = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? "[]"
        let involved = (try? decoder.decode([String].self, from: Data(involvedText.utf8))) ?? []
        let msgIDs = (try? decoder.decode([String].self, from: Data(msgIDsText.utf8))) ?? []

        return ReviewTodo(
            id: Int(sqlite3_column_int(stmt, 0)),
            originRunID: Int(sqlite3_column_int(stmt, 1)),
            lastRunID: Int(sqlite3_column_int(stmt, 2)),
            content: sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? "",
            deadline: optionalDate(stmt, col: 4),
            direction: TodoDirection(rawValue: sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? "unclear") ?? .unclear,
            involved: involved,
            sourceChatUsername: sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) } ?? "",
            sourceChatName: sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) } ?? "",
            sourceMsgIDs: msgIDs,
            confidence: sqlite3_column_double(stmt, 10),
            status: TodoStatus(rawValue: sqlite3_column_text(stmt, 11).flatMap { String(cString: $0) } ?? "pending") ?? .pending,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 12))),
            completedAt: optionalDate(stmt, col: 13),
            snoozedTo: optionalDate(stmt, col: 14),
            delegatedTo: sqlite3_column_text(stmt, 15).flatMap { String(cString: $0) },
            carryCount: Int(sqlite3_column_int(stmt, 16)),
            lastUserActionAt: optionalDate(stmt, col: 17)
        )
    }

    private nonisolated func optionalDate(_ stmt: OpaquePointer?, col: Int32) -> Date? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, col)))
    }
}

// MARK: - group_scope_policy CRUD (Plan M1.5)

extension HUDStore {

    nonisolated func upsertGroupScopePolicy(_ p: GroupScopePolicy) {
        let sql = """
            INSERT OR REPLACE INTO group_scope_policy(
                chat_username, decision, source, decided_at, sample_hash, user_authorized
            ) VALUES (?, ?, ?, ?, ?, ?);
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_text(stmt, 1, p.chatUsername, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 2, p.decision.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 3, p.source.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_int64(stmt, 4, Int64(p.decidedAt.timeIntervalSince1970))
            if let s = p.sampleHash { sqlite3_bind_text(stmt, 5, s, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_int(stmt, 6, Int32(p.userAuthorized ? 1 : 0))
        }
    }

    nonisolated func groupScopePolicy(chatUsername: String) -> GroupScopePolicy? {
        let sql = """
            SELECT chat_username, decision, source, decided_at, sample_hash, user_authorized
            FROM group_scope_policy WHERE chat_username = ?;
        """
        return queryOne(sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, HUDStore.sqliteTransient)
        }, decode: decodeGroupScopePolicy)
    }

    nonisolated func allGroupScopePolicies() -> [GroupScopePolicy] {
        let sql = """
            SELECT chat_username, decision, source, decided_at, sample_hash, user_authorized
            FROM group_scope_policy ORDER BY decided_at DESC;
        """
        return queryAll(sql, bind: { _ in }, decode: decodeGroupScopePolicy)
    }

    private nonisolated func decodeGroupScopePolicy(_ stmt: OpaquePointer?) -> GroupScopePolicy? {
        guard let stmt else { return nil }
        let username = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
        let decisionRaw = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? "ask_each_time"
        let sourceRaw = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? "ai"
        return GroupScopePolicy(
            chatUsername: username,
            decision: ScopeDecision(rawValue: decisionRaw) ?? .askEachTime,
            source: ScopeSource(rawValue: sourceRaw) ?? .ai,
            decidedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3))),
            sampleHash: sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) },
            userAuthorized: sqlite3_column_int(stmt, 5) != 0
        )
    }
}

// MARK: - ai_data_ledger CRUD (Plan M1.5)

extension HUDStore {

    nonisolated func recordLedgerBatch(_ entries: [AILedgerEntry]) {
        guard !entries.isEmpty else { return }
        execIgnoringError("BEGIN TRANSACTION;")
        let sql = """
            INSERT INTO ai_data_ledger(
                ts, provider, model, purpose,
                chat_count, msg_count, byte_count,
                token_in, token_out, redacted
            ) VALUES (?,?,?,?,?,?,?,?,?,?);
        """
        var failed = 0
        for e in entries {
            let changes = executeUpdate(sql) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(e.ts.timeIntervalSince1970))
                sqlite3_bind_text(stmt, 2, e.provider, -1, HUDStore.sqliteTransient)
                sqlite3_bind_text(stmt, 3, e.model, -1, HUDStore.sqliteTransient)
                sqlite3_bind_text(stmt, 4, e.purpose.rawValue, -1, HUDStore.sqliteTransient)
                if let c = e.chatCount { sqlite3_bind_int(stmt, 5, Int32(c)) } else { sqlite3_bind_null(stmt, 5) }
                if let m = e.msgCount { sqlite3_bind_int(stmt, 6, Int32(m)) } else { sqlite3_bind_null(stmt, 6) }
                sqlite3_bind_int(stmt, 7, Int32(e.byteCount))
                if let i = e.tokenIn { sqlite3_bind_int(stmt, 8, Int32(i)) } else { sqlite3_bind_null(stmt, 8) }
                if let o = e.tokenOut { sqlite3_bind_int(stmt, 9, Int32(o)) } else { sqlite3_bind_null(stmt, 9) }
                sqlite3_bind_int(stmt, 10, Int32(e.redacted ? 1 : 0))
            }
            if changes == 0 { failed += 1 }
        }
        if failed == entries.count {
            execIgnoringError("ROLLBACK;")
        } else {
            execIgnoringError("COMMIT;")
        }
    }

    nonisolated func recentLedger(days: Int) -> [AILedgerEntry] {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(days * 86400))
        let sql = """
            SELECT id, ts, provider, model, purpose,
                   chat_count, msg_count, byte_count, token_in, token_out, redacted
            FROM ai_data_ledger WHERE ts >= ? ORDER BY ts DESC;
        """
        return queryAll(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }, decode: decodeLedgerEntry)
    }

    @discardableResult
    nonisolated func clearLedger(olderThanDays: Int) -> Int {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(olderThanDays * 86400))
        let sql = "DELETE FROM ai_data_ledger WHERE ts < ?;"
        return executeUpdate(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }
    }

    private nonisolated func decodeLedgerEntry(_ stmt: OpaquePointer?) -> AILedgerEntry? {
        guard let stmt else { return nil }
        let purposeRaw = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? "chat_analysis"
        let chatCount: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let msgCount: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
        let tokenIn: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
        let tokenOut: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        return AILedgerEntry(
            id: Int(sqlite3_column_int(stmt, 0)),
            ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
            provider: sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? "",
            model: sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? "",
            purpose: LedgerPurpose(rawValue: purposeRaw) ?? .chatAnalysis,
            chatCount: chatCount,
            msgCount: msgCount,
            byteCount: Int(sqlite3_column_int(stmt, 7)),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            redacted: sqlite3_column_int(stmt, 10) != 0
        )
    }
}

// MARK: - red_banner_dismissals CRUD (Plan M1.5)

extension HUDStore {

    @discardableResult
    nonisolated func recordDismissal(_ d: RedBannerDismissal) -> Int? {
        let sql = """
            INSERT INTO red_banner_dismissals(todo_id, action, reason_text, snoozed_to, created_at)
            VALUES (?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(d.todoID))
            sqlite3_bind_text(stmt, 2, d.action.rawValue, -1, HUDStore.sqliteTransient)
            if let r = d.reasonText { sqlite3_bind_text(stmt, 3, r, -1, HUDStore.sqliteTransient) } else { sqlite3_bind_null(stmt, 3) }
            if let s = d.snoozedTo { sqlite3_bind_int64(stmt, 4, Int64(s.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int64(stmt, 5, Int64(d.createdAt.timeIntervalSince1970))
        }
    }

    nonisolated func hasDismissal(todoID: Int, validForHours: Int) -> Bool {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(validForHours * 3600))
        let sql = """
            SELECT 1 FROM red_banner_dismissals
            WHERE todo_id = ? AND created_at >= ? LIMIT 1;
        """
        let found: Int? = queryOne(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(todoID))
            sqlite3_bind_int64(stmt, 2, cutoff)
        }, decode: { stmt in
            guard stmt != nil else { return nil }
            return 1
        })
        return found != nil
    }

    nonisolated func dismissalCount(todoID: Int) -> Int {
        let sql = "SELECT COUNT(*) FROM red_banner_dismissals WHERE todo_id = ?;"
        return queryOne(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(todoID))
        }, decode: { stmt in
            guard let stmt else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }) ?? 0
    }
}

// MARK: - undo_stack CRUD (Plan M1.5)

extension HUDStore {

    @discardableResult
    nonisolated func pushUndo(_ e: UndoEntry) -> Int? {
        let sql = """
            INSERT INTO undo_stack(ts, target_table, target_id, operation, payload_before, payload_after)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(e.ts.timeIntervalSince1970))
            sqlite3_bind_text(stmt, 2, e.targetTable, -1, HUDStore.sqliteTransient)
            sqlite3_bind_int(stmt, 3, Int32(e.targetID))
            sqlite3_bind_text(stmt, 4, e.operation.rawValue, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 5, e.payloadBefore, -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 6, e.payloadAfter, -1, HUDStore.sqliteTransient)
        }
    }

    nonisolated func popLatestUndo() -> UndoEntry? {
        let selectSQL = """
            SELECT id, ts, target_table, target_id, operation, payload_before, payload_after
            FROM undo_stack ORDER BY ts DESC, id DESC LIMIT 1;
        """
        let entry = queryOne(selectSQL, bind: { _ in }, decode: decodeUndoEntry)
        if let entry {
            executeUpdate("DELETE FROM undo_stack WHERE id = ?;") { stmt in
                sqlite3_bind_int(stmt, 1, Int32(entry.id))
            }
        }
        return entry
    }

    @discardableResult
    nonisolated func reapStaleUndo(olderThanSeconds: TimeInterval) -> Int {
        let cutoff = Int64(Date().timeIntervalSince1970 - olderThanSeconds)
        let sql = "DELETE FROM undo_stack WHERE ts < ?;"
        return executeUpdate(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, cutoff)
        }
    }

    private nonisolated func decodeUndoEntry(_ stmt: OpaquePointer?) -> UndoEntry? {
        guard let stmt else { return nil }
        let opRaw = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? "status_change"
        return UndoEntry(
            id: Int(sqlite3_column_int(stmt, 0)),
            ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
            targetTable: sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? "",
            targetID: Int(sqlite3_column_int(stmt, 3)),
            operation: UndoOperation(rawValue: opRaw) ?? .statusChange,
            payloadBefore: sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? "{}",
            payloadAfter: sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "{}"
        )
    }
}
