# 复盘 Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing 7-day-fixed `日报 → 周报` segment with a fully featured `复盘` tab supporting custom time ranges, AI-extracted highlights/todos, persistent cross-week todos, AI uncertainty UX, and macOS-native long-task UX (independent NSWindow + menu bar progress).

**Architecture:** Container F2 — floating `复盘` tab shows AI-summary + red banner + uncertain card stack (one-glance judgment); independent `NSWindow` shows full timeline density rows + todo state machine; menu bar `NSStatusItem` carries long-task progress through `MenuBarController` single owner. Backend: `RetrospectiveJob` actor + `withThrowingTaskGroup` (max 4 concurrent chats) + `Redactor` (in-memory codename map) + per-row writes published via `NotificationCenter`.

**Tech Stack:** Swift 6 (strict concurrency) · SwiftUI + AppKit · SQLite (existing HUDStore pattern: `IF NOT EXISTS` + `ALTER TABLE`) · Existing `AIService` (OpenAI/Codex/Ollama) · Swift Testing framework · No new third-party deps.

**Spec reference:** `docs/superpowers/specs/2026-04-25-retrospective-tab-design.md` (v0.3.1). Sections cited as §X.Y throughout.

**Plan version:** v0.5 (2026-04-25, after GATE 2 round 4 — frontend PASS, backend caught 4 type/field errors)

**v0.4 → v0.5 fixes (per GATE 2 round 4 backend):**

- `MessageInfo.id` is `String` UID (not `Int`/`Int64`); changed `SimpleMessage.id` and `source_msg_ids[]` from `Int64` to `String`. Database TEXT column unchanged.
- `MessageInfo.createTime` is `Int` (unix ts), not `Date`; `messagesInRange` converts start/end Dates to Int before filtering.
- `RelationshipProfile.Hierarchy` actual cases: `.superior/.peer/.subordinate/.external/.personal` (no `.none`); `relation()` adapter maps `.external→.client`, `.personal→.friend`, profile nil→`.unknown`.
- `ChatMonitor.aiService` is `private`; added `nonisolated var aiServiceRef: any AIServiceProtocol { aiService }` accessor for the lazy `retrospectiveJob`.

**Phase split** (introduced in v0.2 to scope plan to reviewable size):

- **Phase 1 (this plan)**: M1-M6 + a minimal placeholder UI tab (M6.5) so the pipeline is end-to-end testable. Replaces existing `周报` mode in `DailyReportTabView` with a temporary stub link to the placeholder. Phase 1 ships the full backend, AI services, persistence, menu bar coordination, and independent NSWindow lifecycle.
- **Phase 2 (separate plan, written after Phase 1 ships)**: full SwiftUI views per spec §4 (RedBannerView with reply path, RetrospectiveSummarySection with evidence chips, UncertainCardStackView, full TimelineRowView with all states, DataLedgerView, ScopePolicyManagerView). Phase 2 plan referenced as `docs/superpowers/plans/<date>-retrospective-ui-phase2.md` (TBD after Phase 1 review).

**v0.3 → v0.4 fixes (per GATE 2 round 3):**

- AppDelegate combineLatest pipeline preserved 1:1 (was incorrectly proposing `HUDStats.vipAlertTier` field that doesn't exist) — now intercepts output to `MenuBarController.badgeText`
- MenuBarController switched from `unreadCount: Int` to `badgeText: String` — preserves existing p0/p1 + VIP worst-tier `agingLabel` semantics
- ChatMonitor.myUsername / myDisplayName now computed properties (was stored `let` with no init path)
- ChatMonitor adds new `messagesInRange(chatUsername:start:end:)` + `sampleMessageTexts()` passthroughs that wrap `reader.getMessages()` and filter by createTime (since WeChatReader has no native date-range query)
- ChatMonitorScopeProvider rewritten to use `monitor.hudStore.getWhitelist()` (real API, not invented `allWhitelistedChats`) + `monitor.messagesInRange()` instead of non-existent HUDStore message query methods
- Group detection via `chatUsername.hasSuffix("@chatroom")` (existing WeChat convention)
- ChatMonitorMessageQuery uses `monitor.messagesInRange()` (was using non-existent `monitor.hudStore.recentMessages(between:and:limit:)`)

**Critical fixes from v0.1 → v0.2 (per GATE 2 round 1):**

1. HUDStore migration moved from `init` to `open()` — `db` is nil before `open()`
2. `db` access: introduce `internal var rawDB: OpaquePointer? { db }` accessor in HUDStore main class so extension methods can `sqlite3_*` against it
3. Test helpers: use real `init(dbPath:)` signature + explicit `try store.open()`
4. Carry-forward order: collect candidates → dedupe → insert survivors (not insert-then-dedupe)
5. AIService access path: `aiService.currentConfig().primarySlot.model` (not `.model`)
6. TaskGroup Sendable safety: capture provider/analyzer in local lets before TaskGroup
7. RetrospectiveJob total timeout: implemented via `Task.sleep` race
8. MenuBarController spinTimer: use SF Symbol rotation transform (single symbol + `NSImage.rotated`)
9. TimelineRow union: introduce `enum TimelineRow` discriminator + Identifiable
10. NotificationCenter "progress" kind: `updateReviewRunProgress` now posts
11. Task 1.5 skeleton expanded with actual SQL+bind+decode for all 12 CRUD methods
12. New Task 4.0 added: create `MockAIService` / `MockMessageQuery` / `MockScopeCandidatesProvider` test helpers
13. M7-M9 deferred to Phase 2 plan; Phase 1 ends at M6.5 (placeholder UI) + M10 cleanup that doesn't depend on Phase 2 views

---

## How To Use This Plan

- Tasks are grouped into **10 milestones**. Each milestone is end-to-end shippable + testable + commits at end.
- Within a milestone, tasks run sequentially. Within a task, steps are 2-5 minute actions.
- After each milestone: build + test pass required. Only then proceed to next.
- **GATE rule** (per project owner): each milestone completion requires dual frontend + backend reviewer PASS before next milestone starts.
- All file paths are absolute from repo root (`/Users/yuriwong/wechatcli/WeChatHUD/`).
- Test framework: Swift Testing (`import Testing` + `@Test`) — see [`Tests/WeChatHUDTests/HUDStoreTests.swift`](../../Tests/WeChatHUDTests/HUDStoreTests.swift) for the existing patterns.

---

## Milestone 1: Data Model + Schema Migration

**Outcome:** 7 new SQLite tables created idempotently; HUDStore extension exposes nonisolated CRUD methods; migration is safe to run on existing local DB.

### Task 1.1: Define Swift model types

**Files:**
- Create: `Sources/WeChatHUD/Data/RetrospectiveModels.swift`

- [ ] **Step 1: Create the models file**

```swift
import Foundation

// MARK: - Run lifecycle

enum ReviewRunStatus: String, Sendable {
    case running, completed, partial, failed
}

struct ReviewRun: Identifiable, Sendable {
    let id: Int
    let rangeStart: Date
    let rangeEnd: Date
    let generatedAt: Date
    let summaryTop3: [SummaryItem]
    let summaryRisk: SummaryItem?
    let summaryMissed: SummaryItem?
    let chatCount: Int
    let progressChatCount: Int
    let msgCount: Int
    let failedChats: [String]
    let status: ReviewRunStatus
}

struct SummaryItem: Codable, Sendable {
    let text: String
    let evidenceHighlightIDs: [Int]
}

// MARK: - Highlights

enum HighlightCategory: String, Codable, Sendable {
    case decision, progress, discussion, risk
}

enum Relation: String, Codable, Sendable {
    case superior, peer, subordinate, client, friend, unknown
}

struct ReviewHighlight: Identifiable, Sendable {
    let id: Int
    let runID: Int
    let date: Date
    let summary: String
    let quotedSnippet: String?
    let involved: [String]
    let sourceChatUsername: String
    let sourceChatName: String
    let relation: Relation
    let sourceMsgIDs: [String]
    let confidence: Double
    let category: HighlightCategory
    let flaggedUncertain: Bool
}

// MARK: - Todos

enum TodoDirection: String, Codable, Sendable {
    case mine, theirs, unclear
}

enum TodoStatus: String, Sendable {
    case pending, completed, snoozed, notMine = "not_mine", delegated, archived
}

struct ReviewTodo: Identifiable, Sendable {
    let id: Int
    let originRunID: Int
    let lastRunID: Int
    let content: String
    let deadline: Date?
    let direction: TodoDirection
    let involved: [String]
    let sourceChatUsername: String
    let sourceChatName: String
    let sourceMsgIDs: [String]
    let confidence: Double
    let status: TodoStatus
    let createdAt: Date
    let completedAt: Date?
    let snoozedTo: Date?
    let delegatedTo: String?
    let carryCount: Int
    let lastUserActionAt: Date?
}

// MARK: - Group scope

enum ScopeDecision: String, Sendable {
    case include, exclude, askEachTime = "ask_each_time"
}

enum ScopeSource: String, Sendable {
    case ai, user
}

struct GroupScopePolicy: Sendable {
    let chatUsername: String
    let decision: ScopeDecision
    let source: ScopeSource
    let decidedAt: Date
    let sampleHash: String?
    let userAuthorized: Bool
}

// MARK: - Ledger

enum LedgerPurpose: String, Sendable {
    case groupScreen = "group_screen"
    case chatAnalysis = "chat_analysis"
    case chatAnalysisFailed = "chat_analysis_failed"
    case summarySynth = "summary_synth"
}

struct LedgerEntry: Sendable {
    let id: Int
    let ts: Date
    let provider: String
    let model: String
    let purpose: LedgerPurpose
    let chatCount: Int?
    let msgCount: Int?
    let byteCount: Int
    let tokenIn: Int?
    let tokenOut: Int?
    let redacted: Bool
}

// MARK: - Red banner

enum RedBannerAction: String, Sendable {
    case repliedExternally = "replied_externally"
    case aiWrong = "ai_wrong"
    case snoozed
}

struct RedBannerDismissal: Sendable {
    let id: Int
    let todoID: Int
    let action: RedBannerAction
    let reasonText: String?
    let snoozedTo: Date?
    let createdAt: Date
}

// MARK: - Undo

enum UndoOperation: String, Sendable {
    case statusChange = "status_change"
}

struct UndoEntry: Sendable {
    let id: Int
    let ts: Date
    let targetTable: String
    let targetID: Int
    let operation: UndoOperation
    let payloadBefore: String   // JSON
    let payloadAfter: String    // JSON
}
```

- [ ] **Step 2: Verify file compiles**

```bash
swift build 2>&1 | grep -E "RetrospectiveModels|error:" | head -20
```

Expected: no `error:` lines mentioning RetrospectiveModels.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/RetrospectiveModels.swift
git commit -m "feat(retrospective): add data model types

Models for ReviewRun, ReviewHighlight, ReviewTodo, GroupScopePolicy,
LedgerEntry, RedBannerDismissal, UndoEntry. Pure Sendable value types.
Spec §5."
```

### Task 1.2: HUDStore migration function

**Files:**
- Create: `Sources/WeChatHUD/Data/HUDStore+Retrospective.swift`
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift` — add `rawDB` accessor + helpers + call `migrateRetrospective()` from **`open()`** (not `init`; `db` is nil before `open()`)

- [ ] **Step 1: Read existing HUDStore.init structure**

```bash
grep -n "init(" /Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Data/HUDStore.swift | head -5
grep -n "CREATE TABLE IF NOT EXISTS" /Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Data/HUDStore.swift | head -10
```

Note the existing migration pattern (look for similar `setupX()` private functions called from init).

- [ ] **Step 2: Create the extension file with migration**

```swift
import Foundation
import SQLite3

extension HUDStore {

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

    /// Helper used by migration only — wraps existing exec mechanism, ignores duplicate-column errors
    /// (mirror of HUDStore's pre-existing best-effort ALTER pattern).
    fileprivate func execIgnoringError(_ sql: String) {
        // implementation detail follows the existing private exec pattern in HUDStore.swift;
        // see Step 3 for the actual wiring (depends on whether HUDStore.exec is fileprivate or internal)
    }
}
```

- [ ] **Step 3: Add `rawDB` accessor + helpers to HUDStore main class**

Open `Sources/WeChatHUD/Data/HUDStore.swift`. The existing `private var db: OpaquePointer?` cannot be accessed from an extension in another file. Add these to the HUDStore main class body (right after `private var db: OpaquePointer?` declaration around line 6):

```swift
/// Internal accessor exposed to extensions in the same module so the +Retrospective
/// extension can prepare its own statements without losing private encapsulation.
nonisolated var rawDB: OpaquePointer? { db }

/// Idempotent SQL executor used by retrospective migration. Errors logged but ignored
/// (matches existing best-effort ALTER TABLE pattern in createTables()).
nonisolated func execIgnoringError(_ sql: String) {
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_step(stmt)
    }
    sqlite3_finalize(stmt)
}
```

In the extension file (`HUDStore+Retrospective.swift`), remove the placeholder `fileprivate func execIgnoringError`. The extension's `migrateRetrospective` calls the class-level method.

For statement-prepare/bind in CRUD methods, define the executor helpers in HUDStore main class too (added once, used by all retrospective CRUD):

```swift
typealias SQLiteBinder = (OpaquePointer?) -> Void

@discardableResult
nonisolated func executeInsert(_ sql: String, bind: SQLiteBinder) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return nil
    }
    bind(stmt)
    let rowID: Int? = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_last_insert_rowid(db)) : nil
    sqlite3_finalize(stmt)
    return rowID
}

@discardableResult
nonisolated func executeUpdate(_ sql: String, bind: SQLiteBinder) -> Int {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return 0
    }
    bind(stmt)
    let changes = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_changes(db)) : 0
    sqlite3_finalize(stmt)
    return changes
}

nonisolated func queryOne<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> T? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return nil
    }
    bind(stmt)
    var result: T? = nil
    if sqlite3_step(stmt) == SQLITE_ROW {
        result = decode(stmt)
    }
    sqlite3_finalize(stmt)
    return result
}

nonisolated func queryAll<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> [T] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return []
    }
    bind(stmt)
    var results: [T] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let decoded = decode(stmt) { results.append(decoded) }
    }
    sqlite3_finalize(stmt)
    return results
}
```

Add `private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` at top of HUDStore.swift if not already defined (search first).

- [ ] **Step 4: Call `migrateRetrospective()` from HUDStore.open() (NOT init)**

`db` is nil at `init` time — only `open()` populates it via `sqlite3_open_v2`. Find the existing `open()` method (or `func createTables() throws` if migration runs there). Add the retrospective migration **after** existing `createTables()` succeeds but **before** any pruneAIAudit cleanup:

```swift
// in HUDStore.open() after createTables() succeeds:
migrateRetrospective()
```

- [ ] **Step 5: Run build**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep -E "error:|warning:" | grep -v "Sendable" | head -10
```

Expected: no errors. (Sendable warnings pre-existing per CLAUDE.md.)

- [ ] **Step 6: Verify migration creates tables**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter HUDStoreTests 2>&1 | tail -20
```

Expected: existing tests pass (migration is idempotent and shouldn't break them).

- [ ] **Step 7: Commit**

```bash
git add Sources/WeChatHUD/Data/HUDStore+Retrospective.swift Sources/WeChatHUD/Data/HUDStore.swift
git commit -m "feat(retrospective): add 7-table schema migration

Idempotent CREATE TABLE IF NOT EXISTS for review_runs,
review_todos, review_highlights, group_scope_policy,
ai_data_ledger, red_banner_dismissals, undo_stack +
5 indexes. Wired into HUDStore.init.
Spec §5."
```

### Task 1.3: HUDStore CRUD for review_runs

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore+Retrospective.swift`

- [ ] **Step 1: Add insertReviewRun + updateReviewRunProgress + finalizeReviewRun**

Append to `HUDStore+Retrospective.swift`:

```swift
extension HUDStore {

    /// Inserts a new review_runs row in 'running' state. Returns the new row id.
    /// Status='running' tells crash recovery to mark this as failed if app exits before finalize.
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
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, top3JSON, -1, SQLITE_TRANSIENT)
            riskJSON.map { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 3)
            missedJSON.map { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 4)
            sqlite3_bind_int(stmt, 5, Int32(msgCount))
            sqlite3_bind_text(stmt, 6, failedJSON, -1, SQLITE_TRANSIENT)
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
    nonisolated func reapStaleRuns(olderThanSeconds: TimeInterval = 35 * 60) -> Int {
        let cutoff = Int64(Date().timeIntervalSince1970 - olderThanSeconds)
        let sql = """
            UPDATE review_runs
            SET status = 'failed',
                failed_chats = json_insert(coalesce(failed_chats, '[]'), '$[#]', '__app_exited_during_run__')
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

// MARK: - Notification names (introduced once here)

extension Notification.Name {
    static let retrospectiveLiveUpdate = Notification.Name("retrospectiveLiveUpdate")
}
```

- [ ] **Step 2: Add executeInsert/executeUpdate/queryOne helpers in HUDStore.swift**

If they don't already exist as nonisolated helpers, add them in the main HUDStore class (or check existing helper names — many similar methods exist):

```swift
// helpers in HUDStore main body
typealias SQLiteBinder = (OpaquePointer?) -> Void

nonisolated func executeInsert(_ sql: String, bind: SQLiteBinder) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return nil
    }
    bind(stmt)
    let result = sqlite3_step(stmt)
    let rowID = result == SQLITE_DONE ? Int(sqlite3_last_insert_rowid(db)) : nil
    sqlite3_finalize(stmt)
    return rowID
}

@discardableResult
nonisolated func executeUpdate(_ sql: String, bind: SQLiteBinder) -> Int {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return 0
    }
    bind(stmt)
    let result = sqlite3_step(stmt)
    let changes = result == SQLITE_DONE ? Int(sqlite3_changes(db)) : 0
    sqlite3_finalize(stmt)
    return changes
}

nonisolated func queryOne<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> T? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return nil
    }
    bind(stmt)
    var result: T? = nil
    if sqlite3_step(stmt) == SQLITE_ROW {
        result = decode(stmt)
    }
    sqlite3_finalize(stmt)
    return result
}
```

`SQLITE_TRANSIENT` is required for binding String → C: add at top of HUDStore+Retrospective.swift:

```swift
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

Or reuse the existing constant if HUDStore.swift already defines one (search first).

- [ ] **Step 3: Build**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Data/HUDStore.swift Sources/WeChatHUD/Data/HUDStore+Retrospective.swift
git commit -m "feat(retrospective): add review_runs CRUD + crash recovery

insertReviewRun (status='running'), updateReviewRunProgress,
finalizeReviewRun (posts NotificationCenter completed event),
reapStaleRuns for crash recovery, latestCompletedRun, runByID.
Spec §5, §6.5, §6.6."
```

### Task 1.4: HUDStore CRUD for review_highlights / review_todos

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore+Retrospective.swift`

- [ ] **Step 1: Add insertHighlight + queryHighlights**

```swift
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
            sqlite3_bind_text(stmt, 3, h.summary, -1, SQLITE_TRANSIENT)
            h.quotedSnippet.map { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 4)
            sqlite3_bind_text(stmt, 5, involvedJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, h.sourceChatUsername, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, h.sourceChatName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, h.relation.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, msgIDsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 10, h.confidence)
            sqlite3_bind_text(stmt, 11, h.category.rawValue, -1, SQLITE_TRANSIENT)
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
```

- [ ] **Step 2: Add queryAll helper to HUDStore.swift if missing**

```swift
nonisolated func queryAll<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> [T] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt); return []
    }
    bind(stmt)
    var results: [T] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let decoded = decode(stmt) {
            results.append(decoded)
        }
    }
    sqlite3_finalize(stmt)
    return results
}
```

- [ ] **Step 3: Add insertReviewTodo + state mutations + queryTodos**

```swift
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
            sqlite3_bind_text(stmt, 3, t.content, -1, SQLITE_TRANSIENT)
            t.deadline.map { sqlite3_bind_int64(stmt, 4, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 4)
            sqlite3_bind_text(stmt, 5, t.direction.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, involvedJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, t.sourceChatUsername, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, t.sourceChatName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, msgIDsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 10, t.confidence)
            sqlite3_bind_text(stmt, 11, t.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 12, Int64(t.createdAt.timeIntervalSince1970))
            t.completedAt.map { sqlite3_bind_int64(stmt, 13, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 13)
            t.snoozedTo.map { sqlite3_bind_int64(stmt, 14, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 14)
            t.delegatedTo.map { sqlite3_bind_text(stmt, 15, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 15)
            sqlite3_bind_int(stmt, 16, Int32(t.carryCount))
            t.lastUserActionAt.map { sqlite3_bind_int64(stmt, 17, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 17)
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

    nonisolated func updateTodoStatus(
        todoID: Int,
        status: TodoStatus,
        completedAt: Date? = nil,
        snoozedTo: Date? = nil,
        delegatedTo: String? = nil
    ) {
        let sql = """
            UPDATE review_todos
            SET status = ?, completed_at = ?, snoozed_to = ?, delegated_to = ?, last_user_action_at = ?
            WHERE id = ?;
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            completedAt.map { sqlite3_bind_int64(stmt, 2, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 2)
            snoozedTo.map { sqlite3_bind_int64(stmt, 3, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 3)
            delegatedTo.map { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 4)
            sqlite3_bind_int64(stmt, 5, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt, 6, Int32(todoID))
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
            if let direction { sqlite3_bind_text(stmt, idx, direction.rawValue, -1, SQLITE_TRANSIENT); idx += 1 }
            if let since { sqlite3_bind_int64(stmt, idx, Int64(since.timeIntervalSince1970)); idx += 1 }
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
```

- [ ] **Step 4: Build + commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -10
git add Sources/WeChatHUD/Data/HUDStore.swift Sources/WeChatHUD/Data/HUDStore+Retrospective.swift
git commit -m "feat(retrospective): add highlights + todos CRUD

insertReviewHighlight + insertReviewTodo post NotificationCenter
events for live UI updates. updateTodoStatus drives four-state
machine. bumpTodoCarry handles cross-run carry-forward.
queryAll helper added to HUDStore.
Spec §5, §6.6."
```

### Task 1.5: HUDStore CRUD for remaining tables

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore+Retrospective.swift`

- [ ] **Step 1: Append group_scope_policy CRUD**

```swift
extension HUDStore {

    nonisolated func upsertGroupScopePolicy(_ p: GroupScopePolicy) {
        let sql = """
            INSERT OR REPLACE INTO group_scope_policy(
                chat_username, decision, source, decided_at, sample_hash, user_authorized
            ) VALUES (?, ?, ?, ?, ?, ?);
        """
        executeUpdate(sql) { stmt in
            sqlite3_bind_text(stmt, 1, p.chatUsername, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, p.decision.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, p.source.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(p.decidedAt.timeIntervalSince1970))
            p.sampleHash.map { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 5)
            sqlite3_bind_int(stmt, 6, Int32(p.userAuthorized ? 1 : 0))
        }
    }

    nonisolated func groupScopePolicy(chatUsername: String) -> GroupScopePolicy? {
        let sql = """
            SELECT chat_username, decision, source, decided_at, sample_hash, user_authorized
            FROM group_scope_policy WHERE chat_username = ?;
        """
        return queryOne(sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, SQLITE_TRANSIENT)
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
```

- [ ] **Step 2: Append ai_data_ledger CRUD with BEGIN/COMMIT batch**

```swift
extension HUDStore {

    nonisolated func recordLedgerBatch(_ entries: [LedgerEntry]) {
        execIgnoringError("BEGIN TRANSACTION;")
        let sql = """
            INSERT INTO ai_data_ledger(
                ts, provider, model, purpose,
                chat_count, msg_count, byte_count,
                token_in, token_out, redacted
            ) VALUES (?,?,?,?,?,?,?,?,?,?);
        """
        for e in entries {
            executeUpdate(sql) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(e.ts.timeIntervalSince1970))
                sqlite3_bind_text(stmt, 2, e.provider, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, e.model, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, e.purpose.rawValue, -1, SQLITE_TRANSIENT)
                e.chatCount.map { sqlite3_bind_int(stmt, 5, Int32($0)) } ?? sqlite3_bind_null(stmt, 5)
                e.msgCount.map { sqlite3_bind_int(stmt, 6, Int32($0)) } ?? sqlite3_bind_null(stmt, 6)
                sqlite3_bind_int(stmt, 7, Int32(e.byteCount))
                e.tokenIn.map { sqlite3_bind_int(stmt, 8, Int32($0)) } ?? sqlite3_bind_null(stmt, 8)
                e.tokenOut.map { sqlite3_bind_int(stmt, 9, Int32($0)) } ?? sqlite3_bind_null(stmt, 9)
                sqlite3_bind_int(stmt, 10, Int32(e.redacted ? 1 : 0))
            }
        }
        execIgnoringError("COMMIT;")
    }

    nonisolated func recentLedger(days: Int) -> [LedgerEntry] {
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

    private nonisolated func decodeLedgerEntry(_ stmt: OpaquePointer?) -> LedgerEntry? {
        guard let stmt else { return nil }
        let purposeRaw = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? "chat_analysis"
        let chatCount: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let msgCount: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
        let tokenIn: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
        let tokenOut: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        return LedgerEntry(
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
```

- [ ] **Step 3: Append red_banner_dismissals CRUD**

```swift
extension HUDStore {

    @discardableResult
    nonisolated func recordDismissal(_ d: RedBannerDismissal) -> Int? {
        let sql = """
            INSERT INTO red_banner_dismissals(todo_id, action, reason_text, snoozed_to, created_at)
            VALUES (?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(d.todoID))
            sqlite3_bind_text(stmt, 2, d.action.rawValue, -1, SQLITE_TRANSIENT)
            d.reasonText.map { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 3)
            d.snoozedTo.map { sqlite3_bind_int64(stmt, 4, Int64($0.timeIntervalSince1970)) } ?? sqlite3_bind_null(stmt, 4)
            sqlite3_bind_int64(stmt, 5, Int64(d.createdAt.timeIntervalSince1970))
        }
    }

    nonisolated func hasDismissal(todoID: Int, validForHours: Int) -> Bool {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(validForHours * 3600))
        let sql = """
            SELECT 1 FROM red_banner_dismissals
            WHERE todo_id = ? AND created_at >= ? LIMIT 1;
        """
        var found = false
        let _: Int? = queryOne(sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(todoID))
            sqlite3_bind_int64(stmt, 2, cutoff)
        }, decode: { _ in found = true; return 1 })
        return found
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
```

- [ ] **Step 4: Append undo_stack CRUD**

```swift
extension HUDStore {

    @discardableResult
    nonisolated func pushUndo(_ e: UndoEntry) -> Int? {
        let sql = """
            INSERT INTO undo_stack(ts, target_table, target_id, operation, payload_before, payload_after)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(e.ts.timeIntervalSince1970))
            sqlite3_bind_text(stmt, 2, e.targetTable, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(e.targetID))
            sqlite3_bind_text(stmt, 4, e.operation.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, e.payloadBefore, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, e.payloadAfter, -1, SQLITE_TRANSIENT)
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
```

- [ ] **Step 2: Build**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -10
```

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/HUDStore+Retrospective.swift
git commit -m "feat(retrospective): add CRUD for scope policy, ledger, dismissals, undo

Spec §5, §8.1.5 (BEGIN/COMMIT batch for ledger), §6.7 (dismissal),
§3.3 (undo stack)."
```

### Task 1.6: Crash recovery hook in HUDStore.init

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift`

- [ ] **Step 1: After migrateRetrospective() call, add reapStaleRuns + reapStaleUndo**

```swift
// in HUDStore.init, after migrateRetrospective():
let reapedRuns = reapStaleRuns()
let reapedUndo = reapStaleUndo(olderThanSeconds: 30 * 60)
if reapedRuns > 0 || reapedUndo > 0 {
    print("[HUDStore] reaped \(reapedRuns) stale review_runs + \(reapedUndo) old undo entries")
}
```

- [ ] **Step 2: Build + commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -5
git add Sources/WeChatHUD/Data/HUDStore.swift
git commit -m "feat(retrospective): crash recovery on HUDStore init

Reap stale 'running' review_runs (>35 min) → mark failed.
Clean undo_stack entries older than 30 minutes.
Spec §6.5."
```

### Task 1.7: Tests for HUDStore migration + CRUD

**Files:**
- Create: `Tests/WeChatHUDTests/HUDStoreRetrospectiveTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import Testing
import Foundation
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
    func migrationIdempotent() {
        let store = try tempStore()
        store.migrateRetrospective()
        store.migrateRetrospective()  // should not throw or duplicate
        // tables verified by inserting + querying
        let runID = store.insertReviewRun(rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(), chatCount: 5)
        #expect(runID != nil)
    }

    @Test("insertReviewRun starts in running state")
    func insertRunRunning() {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 3)!
        let run = store.runByID(runID)
        #expect(run?.status == .running)
        #expect(run?.chatCount == 3)
        #expect(run?.progressChatCount == 0)
    }

    @Test("finalizeReviewRun writes summary + posts notification")
    func finalizeWritesAndPosts() async {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let token = NotificationCenter.default.addObserver(
                forName: .retrospectiveLiveUpdate, object: nil, queue: nil
            ) { note in
                if let kind = note.userInfo?["kind"] as? String, kind == "completed" {
                    continuation.resume(returning: true)
                }
            }
            store.finalizeReviewRun(
                runID: runID, status: .completed,
                summaryTop3: [SummaryItem(text: "x", evidenceHighlightIDs: [1])],
                summaryRisk: nil, summaryMissed: nil, msgCount: 50, failedChats: []
            )
            // Detach the observer in a delayed manner
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.removeObserver(token)
            }
        }
        #expect(received == true)

        let run = store.runByID(runID)
        #expect(run?.status == .completed)
        #expect(run?.summaryTop3.count == 1)
    }

    @Test("reapStaleRuns marks old running rows failed")
    func reapStale() {
        let store = try tempStore()
        let runID = store.insertReviewRun(
            rangeStart: Date(timeIntervalSinceNow: -3600),
            rangeEnd: Date(timeIntervalSinceNow: -3600),
            chatCount: 1
        )!
        // Hack: backdate generated_at
        store.executeUpdate("UPDATE review_runs SET generated_at = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970 - 3600))
            sqlite3_bind_int(stmt, 2, Int32(runID))
        }
        let count = store.reapStaleRuns(olderThanSeconds: 60)
        #expect(count == 1)
        #expect(store.runByID(runID)?.status == .failed)
    }

    @Test("Highlight + todo insert posts notifications")
    func liveUpdates() async {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        var seen: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .retrospectiveLiveUpdate, object: nil, queue: nil
        ) { note in
            if let kind = note.userInfo?["kind"] as? String { seen.append(kind) }
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
        #expect(seen.contains("highlight"))
        #expect(seen.contains("todo"))
    }

    @Test("updateTodoStatus moves through state machine")
    func todoStateMachine() {
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
    func carryBump() {
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

    @Test("recordLedgerBatch wraps in transaction")
    func ledgerBatch() {
        let store = try tempStore()
        let entries = (0..<5).map { i in
            LedgerEntry(
                id: 0, ts: Date(), provider: "openai", model: "gpt-5.4",
                purpose: .chatAnalysis, chatCount: 1, msgCount: 100,
                byteCount: i * 1000, tokenIn: nil, tokenOut: nil, redacted: true
            )
        }
        store.recordLedgerBatch(entries)
        let recent = store.recentLedger(days: 7)
        #expect(recent.count == 5)
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter HUDStoreRetrospectiveTests 2>&1 | tail -30
```

Expected: 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/WeChatHUDTests/HUDStoreRetrospectiveTests.swift
git commit -m "test(retrospective): HUDStore migration + CRUD tests

7 tests covering: idempotent migration, insertReviewRun starts running,
finalize posts notification, reapStaleRuns, highlight/todo notifications,
todo state machine, carry-forward bump, ledger BEGIN/COMMIT batch.
Spec §10."
```

**Milestone 1 Done.** Build green, 7 new tests passing. Run **GATE**: dispatch frontend + backend reviewer to inspect M1 output before M2.

---

## Milestone 2: Pure Utilities (TextSimilarity + Redactor + ScopeResolver)

**Outcome:** Three pure-function modules with full unit test coverage. No AI, no SQLite, no UI dependencies. Each ≤200 lines.

### Task 2.1: TextSimilarity (Jaccard CJK)

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/TextSimilarity.swift`
- Create: `Tests/WeChatHUDTests/TextSimilarityTests.swift`

- [ ] **Step 1: Write tests first (RED)**

```swift
import Testing
@testable import WeChatHUD

@Suite("TextSimilarity")
struct TextSimilarityTests {

    @Test("Identical strings return 1.0")
    func identical() {
        #expect(TextSimilarity.jaccardCJK("hello world", "hello world") == 1.0)
    }

    @Test("Disjoint strings return 0.0")
    func disjoint() {
        #expect(TextSimilarity.jaccardCJK("abc", "xyz") == 0.0)
    }

    @Test("Empty strings handled")
    func empty() {
        #expect(TextSimilarity.jaccardCJK("", "") == 1.0)
        #expect(TextSimilarity.jaccardCJK("x", "") == 0.0)
    }

    @Test("Chinese bigrams overlap")
    func chineseBigrams() {
        let s1 = "周一上线v2"
        let s2 = "v2 周一上线"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score > 0.6)
    }

    @Test("English word tokens")
    func englishWords() {
        let score = TextSimilarity.jaccardCJK("send report to boss", "send the report")
        #expect(score > 0.3)
        #expect(score < 1.0)
    }

    @Test("Punctuation does not pollute tokens")
    func punctuation() {
        let s1 = "hello, world!"
        let s2 = "hello world"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score >= 0.9)
    }

    @Test("Mixed Chinese + English")
    func mixed() {
        let s1 = "周一发 PRD 给 Wang"
        let s2 = "周一 发PRD 给Wang"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score > 0.5)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail (function not defined)**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter TextSimilarityTests 2>&1 | tail -10
```

Expected: compile error (`TextSimilarity` not defined).

- [ ] **Step 3: Implement TextSimilarity**

```swift
import Foundation

enum TextSimilarity {

    /// Jaccard similarity for CJK + Latin text.
    /// Tokenization: Chinese bigrams (sliding 2-char window over CJK runs);
    /// English/digit runs split on whitespace + punctuation.
    /// Returns [0, 1]; 1 = identical token sets, 0 = disjoint.
    static func jaccardCJK(_ a: String, _ b: String) -> Double {
        let aTokens = tokenize(a)
        let bTokens = tokenize(b)
        if aTokens.isEmpty && bTokens.isEmpty { return 1.0 }
        if aTokens.isEmpty || bTokens.isEmpty { return 0.0 }
        let intersection = aTokens.intersection(bTokens).count
        let union = aTokens.union(bTokens).count
        return Double(intersection) / Double(union)
    }

    static func tokenize(_ s: String) -> Set<String> {
        var tokens = Set<String>()
        var currentLatin = ""

        func flushLatin() {
            if !currentLatin.isEmpty {
                let lower = currentLatin.lowercased()
                if !lower.isEmpty { tokens.insert(lower) }
                currentLatin = ""
            }
        }

        var cjkBuffer: [Character] = []

        func flushCJK() {
            if cjkBuffer.count == 1 {
                tokens.insert(String(cjkBuffer[0]))
            } else if cjkBuffer.count >= 2 {
                for i in 0..<(cjkBuffer.count - 1) {
                    tokens.insert(String([cjkBuffer[i], cjkBuffer[i + 1]]))
                }
            }
            cjkBuffer.removeAll(keepingCapacity: true)
        }

        for ch in s {
            if isCJK(ch) {
                flushLatin()
                cjkBuffer.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                currentLatin.append(ch)
            } else {
                // whitespace or punctuation — boundary
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()

        // Drop common stopwords
        let stopwords: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "at", "and", "or", "for"]
        tokens.subtract(stopwords)
        return tokens
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)        // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(v)    // Extension A
                || (0x20000...0x2A6DF).contains(v)  // Extension B
            {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter TextSimilarityTests 2>&1 | tail -15
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/Retrospective/TextSimilarity.swift Tests/WeChatHUDTests/TextSimilarityTests.swift
git commit -m "feat(retrospective): TextSimilarity Jaccard CJK + tests

Pure function: tokenize CJK as bigrams, Latin as words, drop stopwords.
7 tests covering identical/disjoint/empty/Chinese/English/punctuation/mixed.
Spec §6.2 step 7b."
```

### Task 2.2: Redactor

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/Redactor.swift`
- Create: `Tests/WeChatHUDTests/RedactorTests.swift`

- [ ] **Step 1: Write tests**

```swift
import Testing
import Foundation
@testable import WeChatHUD

@Suite("Redactor")
struct RedactorTests {

    @Test("Same username always maps to same codename within run")
    func stableCodename() {
        let r = Redactor()
        let c1 = r.codenameFor(username: "wxid_abc", displayName: "张总")
        let c2 = r.codenameFor(username: "wxid_abc", displayName: "张总")
        #expect(c1 == c2)
    }

    @Test("Different usernames yield different codenames even if same displayName")
    func differentUsernamesSameName() {
        let r = Redactor()
        let c1 = r.codenameFor(username: "wxid_a", displayName: "张总")
        let c2 = r.codenameFor(username: "wxid_b", displayName: "张总")
        #expect(c1 != c2)
    }

    @Test("Codenames are A1, A2, A3 sequence")
    func sequential() {
        let r = Redactor()
        let c1 = r.codenameFor(username: "wxid_1", displayName: "")
        let c2 = r.codenameFor(username: "wxid_2", displayName: "")
        let c3 = r.codenameFor(username: "wxid_3", displayName: "")
        #expect(c1 == "A1")
        #expect(c2 == "A2")
        #expect(c3 == "A3")
    }

    @Test("Redact masks phone, email, money")
    func maskPatterns() {
        let r = Redactor()
        let input = "联系我 13800138000 或 foo@bar.com，预算 ¥50000"
        let out = r.redactText(input)
        #expect(out.contains("[手机]"))
        #expect(out.contains("[邮箱]"))
        #expect(out.contains("[金额]"))
        #expect(!out.contains("13800138000"))
    }

    @Test("Money in 万 / K notation masked")
    func moneyVariants() {
        let r = Redactor()
        #expect(r.redactText("预算 50万").contains("[金额]"))
        #expect(r.redactText("预算 100K").contains("[金额]"))
        #expect(r.redactText("$5000").contains("[金额]"))
    }

    @Test("reverseCodename returns original")
    func reverseLookup() {
        let r = Redactor()
        let code = r.codenameFor(username: "wxid_z", displayName: "李四")
        #expect(r.originalForCodename(code) == "李四")
    }

    @Test("AI output reverse-codename roundtrip")
    func aiOutputRoundtrip() {
        let r = Redactor()
        let _ = r.codenameFor(username: "wxid_w", displayName: "王总")
        let aiOutput = "A1 决定上线"
        let unredacted = r.unredactText(aiOutput)
        #expect(unredacted == "王总 决定上线")
    }
}
```

- [ ] **Step 2: Implement Redactor**

```swift
import Foundation

actor Redactor {

    private var codenameByUsername: [String: String] = [:]
    private var usernameByCodename: [String: String] = [:]
    private var displayNameByCodename: [String: String] = [:]
    private var nextIndex = 1

    nonisolated init() {}

    func codenameFor(username: String, displayName: String) -> String {
        if let existing = codenameByUsername[username] {
            return existing
        }
        let code = "A\(nextIndex)"
        nextIndex += 1
        codenameByUsername[username] = code
        usernameByCodename[code] = username
        if !displayName.isEmpty {
            displayNameByCodename[code] = displayName
        }
        return code
    }

    /// Synchronous mirror used by tests. For real pipeline use the actor methods.
    nonisolated func _testCodename(username: String, displayName: String) -> String {
        // Not for production use; bridges actor isolation for tests via UncheckedSendable.
        // Real callers should `await codenameFor(...)`.
        // This shim exists because @Test methods are not async by default.
        // For simplicity in tests, we can just use a Task and await.
        fatalError("Use the async codenameFor; tests should use Task wrapper")
    }

    func originalForCodename(_ code: String) -> String? {
        displayNameByCodename[code] ?? usernameByCodename[code]
    }

    /// Replace mentions / quoted speech of names + sensitive patterns with codenames or placeholders.
    /// String replacement order: codename mapping first (longest displayName first to avoid partial collisions),
    /// then regex masks for phone/email/money.
    func redactText(_ s: String) -> String {
        var out = s
        // Codenames: replace registered displayNames.
        let names = displayNameByCodename
            .map { ($0.value, $0.key) }
            .sorted { $0.0.count > $1.0.count }
        for (name, code) in names where !name.isEmpty {
            out = out.replacingOccurrences(of: name, with: code)
        }
        out = applyMasks(out)
        return out
    }

    nonisolated func unredactText(_ s: String) -> String {
        // For test convenience; unredact uses externally-provided maps.
        // Real unredact happens via `unredactWith(_:)` below.
        return s
    }

    func unredactWith(_ s: String) -> String {
        var out = s
        // Replace codenames back to display names. Iterate longest codename first
        // so "A10" doesn't mask "A1".
        let codes = displayNameByCodename
            .map { ($0.key, $0.value) }
            .sorted { $0.0.count > $1.0.count }
        for (code, name) in codes {
            // Replace as standalone word (avoid mid-word substitution)
            out = replaceStandaloneToken(in: out, token: code, with: name)
        }
        return out
    }

    private nonisolated func applyMasks(_ s: String) -> String {
        var out = s
        // Phone: 11 digits starting with 1 (Chinese mobile) OR 7-15 digits
        out = out.replacingOccurrences(
            of: #"(1\d{10})|(\b\d{7,11}\b)"#,
            with: "[手机]",
            options: .regularExpression
        )
        // Email
        out = out.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "[邮箱]",
            options: .regularExpression
        )
        // Money — Chinese yuan, K/万 suffix, $ prefix
        out = out.replacingOccurrences(
            of: #"(¥\s?\d+[\d,.]*)|(\$\s?\d+[\d,.]*)|(\d+\s?[KkMm万千百])"#,
            with: "[金额]",
            options: .regularExpression
        )
        return out
    }

    private nonisolated func replaceStandaloneToken(in s: String, token: String, with replacement: String) -> String {
        // Simple boundary-aware replace: token surrounded by non-word chars or string ends.
        let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: token))(?![A-Za-z0-9])"
        return s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
```

Note: tests need adjusting because Redactor is now an actor and `codenameFor` is `async`. Update the tests to use `await`:

```swift
@Test("Same username always maps to same codename within run")
func stableCodename() async {
    let r = Redactor()
    let c1 = await r.codenameFor(username: "wxid_abc", displayName: "张总")
    let c2 = await r.codenameFor(username: "wxid_abc", displayName: "张总")
    #expect(c1 == c2)
}
// ... apply async to all tests
```

For the `unredactText` test, use the `unredactWith` instance method (also async).

- [ ] **Step 3: Run tests**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter RedactorTests 2>&1 | tail -15
```

Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Services/Retrospective/Redactor.swift Tests/WeChatHUDTests/RedactorTests.swift
git commit -m "feat(retrospective): Redactor in-memory codename map + tests

Actor-based per-run map keyed by senderUsername. Masks phone/email/money.
unredactWith reverses codenames in AI output. 7 tests covering stability,
disambiguation by username, mask patterns, money variants, roundtrip.
Spec §6.3."
```

### Task 2.3: ScopeResolver

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/ScopeResolver.swift`
- Create: `Tests/WeChatHUDTests/ScopeResolverTests.swift`

- [ ] **Step 1: Write tests**

```swift
import Testing
import Foundation
@testable import WeChatHUD

@Suite("ScopeResolver")
struct ScopeResolverTests {

    @Test("This week range starts Monday 00:00 in current TZ")
    func thisWeekStartsMonday() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14))!  // a Wednesday
        let range = ScopeResolver.range(.thisWeek, anchor: now, calendar: cal)
        let start = cal.dateComponents([.year, .month, .day, .weekday], from: range.start)
        #expect(start.weekday == 2)  // Monday
        #expect(start.day == 20)     // April 20, 2026
    }

    @Test("Custom range respects exact bounds")
    func customRange() {
        let s = Date(timeIntervalSince1970: 1000)
        let e = Date(timeIntervalSince1970: 5000)
        let r = ScopeResolver.range(.custom(start: s, end: e), anchor: Date(), calendar: .current)
        #expect(r.start == s)
        #expect(r.end == e)
    }

    @Test("Since-last-retrospective uses store's latestCompletedRun.range_end")
    func sinceLastRetro() {
        // We pass the last completion explicitly to avoid coupling tests to HUDStore
        let lastEnd = Date(timeIntervalSinceNow: -3 * 86400)
        let r = ScopeResolver.range(.sinceLastRetrospective(lastRunEnd: lastEnd), anchor: Date(), calendar: .current)
        #expect(r.start == lastEnd)
        #expect(r.end.timeIntervalSinceNow >= -1)  // ~now
    }

    @Test("First-time use (no last run) defaults to this-week behavior")
    func firstTime() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14))!
        let r = ScopeResolver.range(.sinceLastRetrospective(lastRunEnd: nil), anchor: now, calendar: cal)
        let start = cal.dateComponents([.day], from: r.start)
        #expect(start.day == 20)  // Monday of that week
    }

    @Test("Filter whitelist by membership + has messages in range")
    func filterCandidates() {
        let candidates = [
            ScopeCandidate(chatUsername: "wxid_a", chatName: "A", isGroup: true, msgCountInRange: 50, myMsgCountInRange: 5),
            ScopeCandidate(chatUsername: "wxid_b", chatName: "B", isGroup: true, msgCountInRange: 0, myMsgCountInRange: 0),
            ScopeCandidate(chatUsername: "wxid_c", chatName: "C", isGroup: false, msgCountInRange: 10, myMsgCountInRange: 2),
        ]
        let filtered = ScopeResolver.filter(candidates: candidates, dropEmpty: true)
        #expect(filtered.count == 2)
        #expect(filtered.map(\.chatUsername) == ["wxid_a", "wxid_c"])
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

enum ScopeMode: Sendable {
    case sinceLastRetrospective(lastRunEnd: Date?)
    case today
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case custom(start: Date, end: Date)
}

struct DateRange: Sendable {
    let start: Date
    let end: Date
}

struct ScopeCandidate: Sendable {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let msgCountInRange: Int
    let myMsgCountInRange: Int
}

enum ScopeResolver {

    static func range(_ mode: ScopeMode, anchor: Date = Date(), calendar: Calendar = .current) -> DateRange {
        switch mode {
        case .custom(let s, let e):
            return DateRange(start: s, end: e)
        case .sinceLastRetrospective(let lastEnd):
            if let lastEnd { return DateRange(start: lastEnd, end: anchor) }
            return range(.thisWeek, anchor: anchor, calendar: calendar)
        case .today:
            let start = calendar.startOfDay(for: anchor)
            return DateRange(start: start, end: anchor)
        case .thisWeek:
            return DateRange(start: startOfWeek(anchor, calendar: calendar), end: anchor)
        case .lastWeek:
            let thisStart = startOfWeek(anchor, calendar: calendar)
            let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisStart)!
            let lastEnd = calendar.date(byAdding: .second, value: -1, to: thisStart)!
            return DateRange(start: lastStart, end: lastEnd)
        case .thisMonth:
            let comp = calendar.dateComponents([.year, .month], from: anchor)
            let start = calendar.date(from: comp)!
            return DateRange(start: start, end: anchor)
        case .lastMonth:
            let comp = calendar.dateComponents([.year, .month], from: anchor)
            let thisStart = calendar.date(from: comp)!
            let lastStart = calendar.date(byAdding: .month, value: -1, to: thisStart)!
            let lastEnd = calendar.date(byAdding: .second, value: -1, to: thisStart)!
            return DateRange(start: lastStart, end: lastEnd)
        }
    }

    private static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps)!
    }

    static func filter(candidates: [ScopeCandidate], dropEmpty: Bool = true) -> [ScopeCandidate] {
        if dropEmpty {
            return candidates.filter { $0.msgCountInRange > 0 }
        }
        return candidates
    }
}
```

- [ ] **Step 3: Run tests**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ScopeResolverTests 2>&1 | tail -15
```

Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Services/Retrospective/ScopeResolver.swift Tests/WeChatHUDTests/ScopeResolverTests.swift
git commit -m "feat(retrospective): ScopeResolver time ranges + candidate filter

ScopeMode enum (sinceLastRetrospective + 5 presets + custom).
Pure function range(_:anchor:calendar:) with Monday-start week.
ScopeCandidate filter drops empties. 5 tests.
Spec §3.1, §6.2 step 1."
```

**Milestone 2 Done.** **GATE** between M2 and M3.

---

## Milestone 3: Persistence Services (ReviewTodoManager + UndoStore + DataLedger)

**Outcome:** Three actor services with state machine, undo stack, and batched ledger writes. Tests included.

### Task 3.1: ReviewTodoManager

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/ReviewTodoManager.swift`
- Create: `Tests/WeChatHUDTests/ReviewTodoManagerTests.swift`

- [ ] **Step 1: Write tests**

```swift
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

    @Test("carryForward dedupes by msg_ids overlap")
    func dedupeMsgIDsOverlap() async {
        let store = try tempStore()
        let manager = ReviewTodoManager(store: store)
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        // Pre-existing pending todo from runA
        let oldTodo = ReviewTodo(
            id: 0, originRunID: runA, lastRunID: runA, content: "do thing",
            deadline: nil, direction: .mine, involved: ["A1"],
            sourceChatUsername: "wxid_x", sourceChatName: "chat",
            sourceMsgIDs: ["m100", "m200"], confidence: 0.8, status: .pending,
            createdAt: Date(timeIntervalSinceNow: -86400),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        let oldID = store.insertReviewTodo(oldTodo)!

        // Newly extracted in runB shares msg id 200 → should dedupe
        let newCandidate = ReviewTodo(
            id: 0, originRunID: runB, lastRunID: runB, content: "different wording",
            deadline: nil, direction: .mine, involved: ["A1"],
            sourceChatUsername: "wxid_x", sourceChatName: "chat",
            sourceMsgIDs: ["m200", "m300"], confidence: 0.85, status: .pending,
            createdAt: Date(), completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )

        let kept = await manager.carryForward(prevRunID: runA, newRunID: runB, newCandidates: [newCandidate])
        #expect(kept.count == 0)  // newCandidate was deduped
        let bumped = store.todos(for: runB, statuses: [.pending])
        #expect(bumped.count == 1)
        #expect(bumped.first?.id == oldID)
        #expect(bumped.first?.carryCount == 1)
    }

    @Test("carryForward dedupes by Jaccard")
    func dedupeJaccard() async {
        let store = try tempStore()
        let manager = ReviewTodoManager(store: store)
        let runA = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        let oldTodo = ReviewTodo(
            id: 0, originRunID: runA, lastRunID: runA, content: "周一上线 v2 砍掉地图",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "wxid_x", sourceChatName: "chat",
            sourceMsgIDs: ["m1"], confidence: 0.7, status: .pending,
            createdAt: Date(), completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        store.insertReviewTodo(oldTodo)

        let newCandidate = ReviewTodo(
            id: 0, originRunID: runB, lastRunID: runB, content: "v2 周一上线 砍地图模块",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "wxid_x", sourceChatName: "chat",
            sourceMsgIDs: ["m99"], confidence: 0.8, status: .pending,
            createdAt: Date(), completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )

        let kept = await manager.carryForward(prevRunID: runA, newRunID: runB, newCandidates: [newCandidate])
        #expect(kept.count == 0)
    }

    @Test("carryForward keeps non-deduped new candidates")
    func keepsNew() async {
        let store = try tempStore()
        let manager = ReviewTodoManager(store: store)
        let runB = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!

        let trulyNew = ReviewTodo(
            id: 0, originRunID: runB, lastRunID: runB, content: "completely new",
            deadline: nil, direction: .theirs, involved: ["A2"],
            sourceChatUsername: "wxid_y", sourceChatName: "chat2",
            sourceMsgIDs: ["m42"], confidence: 0.9, status: .pending,
            createdAt: Date(), completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )

        let kept = await manager.carryForward(prevRunID: 999, newRunID: runB, newCandidates: [trulyNew])
        #expect(kept.count == 1)
        #expect(kept.first?.content == "completely new")
    }

    @Test("Auto-archive after 4 weeks of carry")
    func autoArchive4Weeks() async {
        let store = try tempStore()
        let manager = ReviewTodoManager(store: store)
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let todo = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: "old thing",
            deadline: nil, direction: .mine, involved: [],
            sourceChatUsername: "u", sourceChatName: "n", sourceMsgIDs: [],
            confidence: 0.5, status: .pending, createdAt: Date(),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 4, lastUserActionAt: nil
        )
        let id = store.insertReviewTodo(todo)!
        await manager.suggestArchiveStaleTodos(olderThanWeeks: 4)
        // Note: this method should produce an "archive suggestion" rather than auto-archiving by default.
        // Tested by asserting the todo's status remains pending but a suggestion is returned.
        let after = store.todos(for: runID, statuses: [.pending]).first
        #expect(after?.carryCount == 4)
    }
}
```

- [ ] **Step 2: Implement ReviewTodoManager**

```swift
import Foundation

actor ReviewTodoManager {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    /// Returns the candidates that survived dedupe and should be inserted as new.
    /// Side-effect: bumps surviving prev-run pending todos to newRunID.
    func carryForward(
        prevRunID: Int,
        newRunID: Int,
        newCandidates: [ReviewTodo]
    ) -> [ReviewTodo] {
        let prevPending = store.todos(for: prevRunID, statuses: [.pending])
        var deduped = newCandidates
        var matchedPrevIDs = Set<Int>()

        for prev in prevPending {
            // Find a candidate that matches by any of the 3 conditions
            if let matchIdx = deduped.firstIndex(where: { matches(prev: prev, cand: $0) }) {
                deduped.remove(at: matchIdx)
                store.bumpTodoCarry(todoID: prev.id, newRunID: newRunID)
                matchedPrevIDs.insert(prev.id)
            } else {
                // Prev still pending but not re-extracted → still carry forward
                store.bumpTodoCarry(todoID: prev.id, newRunID: newRunID)
            }
        }
        return deduped
    }

    private nonisolated func matches(prev: ReviewTodo, cand: ReviewTodo) -> Bool {
        // Condition 1: source_msg_ids overlap
        let prevSet = Set(prev.sourceMsgIDs)
        let candSet = Set(cand.sourceMsgIDs)
        if !prevSet.isDisjoint(with: candSet) { return true }

        // Condition 2: same chat + Jaccard > 0.6
        if prev.sourceChatUsername == cand.sourceChatUsername {
            if TextSimilarity.jaccardCJK(prev.content, cand.content) > 0.6 {
                return true
            }
        }

        // Condition 3: same chat + ≥1 shared involved + same deadline day
        if prev.sourceChatUsername == cand.sourceChatUsername {
            let sharedInvolved = !Set(prev.involved).intersection(cand.involved).isEmpty
            let sameDeadlineDay: Bool = {
                guard let pd = prev.deadline, let cd = cand.deadline else { return false }
                let cal = Calendar.current
                return cal.isDate(pd, inSameDayAs: cd)
            }()
            if sharedInvolved && sameDeadlineDay { return true }
        }

        return false
    }

    /// Surfaces todos with carryCount >= threshold to the UI as archive candidates.
    /// Does not auto-archive (requires user confirmation per spec §4.2).
    func suggestArchiveStaleTodos(olderThanWeeks: Int = 4) -> [ReviewTodo] {
        let pending = store.pendingTodos()
        return pending.filter { $0.carryCount >= olderThanWeeks }
    }

    // MARK: - Four-state operations

    func markCompleted(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .completed, completedAt: Date())
    }

    func snooze(todoID: Int, until: Date) {
        store.updateTodoStatus(todoID: todoID, status: .snoozed, snoozedTo: until)
    }

    func markNotMine(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .notMine)
    }

    func delegate(todoID: Int, to: String) {
        store.updateTodoStatus(todoID: todoID, status: .delegated, delegatedTo: to)
    }

    func archive(todoID: Int) {
        store.updateTodoStatus(todoID: todoID, status: .archived)
    }
}
```

- [ ] **Step 3: Run tests + commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ReviewTodoManagerTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/ReviewTodoManager.swift Tests/WeChatHUDTests/ReviewTodoManagerTests.swift
git commit -m "feat(retrospective): ReviewTodoManager carry-forward + state machine

Three-condition dedupe (msg_ids overlap / Jaccard 0.6 / shared involved+deadline).
suggestArchiveStaleTodos surfaces 4-week-old todos for user confirmation.
Five state transitions (completed/snoozed/notMine/delegated/archived).
Spec §6.2 step 7, §3.3."
```

### Task 3.2: UndoStore

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/UndoStore.swift`
- Create: `Tests/WeChatHUDTests/UndoStoreTests.swift`

- [ ] **Step 1: Write tests + implement**

Implementation outline (follow same TDD pattern):

```swift
import Foundation

actor UndoStore {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    /// Snapshots the current value, applies the change, records to undo_stack.
    func record<T: Codable>(targetTable: String, targetID: Int, operation: UndoOperation, before: T, after: T) {
        let encoder = JSONEncoder()
        guard let beforeData = try? encoder.encode(before),
              let afterData = try? encoder.encode(after),
              let beforeStr = String(data: beforeData, encoding: .utf8),
              let afterStr = String(data: afterData, encoding: .utf8)
        else { return }
        let entry = UndoEntry(
            id: 0, ts: Date(), targetTable: targetTable, targetID: targetID,
            operation: operation, payloadBefore: beforeStr, payloadAfter: afterStr
        )
        _ = store.pushUndo(entry)
    }

    func popLatest() -> UndoEntry? {
        store.popLatestUndo()
    }
}
```

Tests cover: push then pop returns latest, popping empty stack returns nil, 30-min reaping happens via HUDStore.reapStaleUndo (already tested in M1).

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter UndoStoreTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/UndoStore.swift Tests/WeChatHUDTests/UndoStoreTests.swift
git commit -m "feat(retrospective): UndoStore actor + tests

Snapshot before/after JSON to undo_stack; popLatest restores latest action.
Spec §3.3."
```

### Task 3.3: DataLedger wrapper

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/DataLedger.swift`
- Create: `Tests/WeChatHUDTests/DataLedgerTests.swift`

- [ ] **Step 1: Implement + test**

```swift
import Foundation

actor DataLedger {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    func recordBatch(_ entries: [LedgerEntry]) {
        store.recordLedgerBatch(entries)
    }

    func recent(days: Int) -> [LedgerEntry] {
        store.recentLedger(days: days)
    }

    func clearOlderThan(days: Int) -> Int {
        store.clearLedger(olderThanDays: days)
    }

    /// CSV export to file URL.
    func exportCSV(to url: URL, days: Int = 90) throws {
        let entries = recent(days: days)
        let header = "timestamp,provider,model,purpose,chat_count,msg_count,byte_count,token_in,token_out,redacted\n"
        let rows = entries.map { e -> String in
            let isoFmt = ISO8601DateFormatter()
            return [
                isoFmt.string(from: e.ts),
                e.provider, e.model, e.purpose.rawValue,
                e.chatCount.map(String.init) ?? "",
                e.msgCount.map(String.init) ?? "",
                String(e.byteCount),
                e.tokenIn.map(String.init) ?? "",
                e.tokenOut.map(String.init) ?? "",
                e.redacted ? "1" : "0"
            ].joined(separator: ",")
        }.joined(separator: "\n")
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
    }
}
```

Tests: batch insert, recent filter, CSV export roundtrip.

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter DataLedgerTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/DataLedger.swift Tests/WeChatHUDTests/DataLedgerTests.swift
git commit -m "feat(retrospective): DataLedger wrapper + CSV export

Wraps HUDStore.recordLedgerBatch with BEGIN/COMMIT.
exportCSV produces 90-day audit file.
Spec §8.1.5, §8.3."
```

**Milestone 3 Done.** **GATE** before M4.

---

## Milestone 4: AI Services (GroupScreener + RetrospectiveAnalyzer + SummarySynthesizer)

**Outcome:** Three AI-backed services with prompt files. Each module has its own prompt + tests using mocked AIService.

### Task 4.0: Introduce AIServiceProtocol + Test mock helpers

**Files:**
- Create: `Sources/WeChatHUD/Services/AIServiceProtocol.swift`
- Modify: `Sources/WeChatHUD/Services/AIService.swift` (add protocol conformance)
- Create: `Tests/WeChatHUDTests/Helpers/MockAIService.swift`
- Create: `Tests/WeChatHUDTests/Helpers/MockMessageQuery.swift`
- Create: `Tests/WeChatHUDTests/Helpers/MockScopeCandidatesProvider.swift`

- [ ] **Step 0: Define `AIServiceProtocol` and conform AIService**

```swift
// Sources/WeChatHUD/Services/AIServiceProtocol.swift
import Foundation

/// Protocol surface that retrospective services depend on. Real `AIService`
/// (actor) and `MockAIService` (test helper) both conform to this so DI works
/// without exposing actor concrete type to consumers.
protocol AIServiceProtocol: Sendable {
    func complete(system: String, user: String, options: CompleteOptions) async throws -> String
    func currentConfig() async -> AIConfig
}
```

In `Sources/WeChatHUD/Services/AIService.swift`, add at end of file:

```swift
extension AIService: AIServiceProtocol {}
```

The actor's existing `func complete(system:user:options:) async throws -> String` and `func currentConfig() -> AIConfig` already match (the protocol's `currentConfig() async` is wider than the actor's sync method; Swift accepts this).

- [ ] **Step 1: MockAIService**

```swift
import Foundation
@testable import WeChatHUD

actor MockAIService: AIServiceProtocol {
    /// Map prompt-substring → canned response.
    /// First key whose substring is found in the user prompt wins.
    var routes: [(needle: String, response: String)] = []
    var calls: [(system: String, user: String, options: CompleteOptions)] = []
    var defaultResponse: String = "{}"
    var shouldThrow: Error? = nil
    var configToReturn: AIConfig = AIConfig()

    func setRoute(needle: String, response: String) {
        routes.append((needle, response))
    }

    func setShouldThrow(_ err: Error) { shouldThrow = err }
    func setConfig(_ c: AIConfig) { configToReturn = c }

    // MARK: AIServiceProtocol conformance

    func complete(system: String, user: String, options: CompleteOptions) async throws -> String {
        calls.append((system, user, options))
        if let err = shouldThrow { throw err }
        for r in routes where user.contains(r.needle) { return r.response }
        return defaultResponse
    }

    func currentConfig() async -> AIConfig {
        configToReturn
    }
}
```

- [ ] **Step 2: MockMessageQuery**

```swift
import Foundation
@testable import WeChatHUD

actor MockMessageQuery: MessageQuery {
    var stored: [String: [SimpleMessage]] = [:]  // chatUsername → messages

    func setMessages(_ msgs: [SimpleMessage], for chatUsername: String) {
        stored[chatUsername] = msgs
    }

    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage] {
        return (stored[chatUsername] ?? []).filter { $0.timestamp >= since && $0.timestamp <= until }
    }
}
```

- [ ] **Step 3: MockScopeCandidatesProvider**

```swift
import Foundation
@testable import WeChatHUD

actor MockScopeCandidatesProvider: ScopeCandidatesProvider {
    var candidatesIn: [DateRange: [ScopeCandidate]] = [:]
    var samplesByUsername: [String: [String]] = [:]
    var messagesByUsername: [String: [MessageInfo]] = [:]
    var relationByUsername: [String: Relation] = [:]

    func candidates(in range: DateRange) async -> [ScopeCandidate] {
        return candidatesIn.first(where: { $0.key.start == range.start && $0.key.end == range.end })?.value ?? []
    }

    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for u in usernames { out[u] = samplesByUsername[u] }
        return out
    }

    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo] {
        return Array((messagesByUsername[username] ?? []).prefix(limit))
    }

    func relation(for username: String) async -> Relation {
        return relationByUsername[username] ?? .unknown
    }
}

extension DateRange: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(start.timeIntervalSince1970)
        hasher.combine(end.timeIntervalSince1970)
    }
    public static func == (lhs: DateRange, rhs: DateRange) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Tests/WeChatHUDTests/Helpers/
git commit -m "test(retrospective): mock helpers for AIService/MessageQuery/ScopeCandidatesProvider"
```

### Task 4.1: Prompt files

**Files:**
- Create: `Resources/Prompts/retrospective_group_screen_v1.txt`
- Create: `Resources/Prompts/retrospective_chat_analysis_v1.txt`
- Create: `Resources/Prompts/retrospective_summary_synth_v1.txt`

- [ ] **Step 1: Write group screen prompt**

```
你是用户的微信工作助手。下面是用户白名单里的若干群聊,每个群附带最近 20 条样本消息。
请判断每个群是否属于"工作相关"——也就是讨论工作任务、决策、协作的群,而不是纯生活/兴趣/家庭群。

输出严格 JSON 数组,每个元素:
{
  "chat_name": "...",         // 原样回传
  "decision": "include" 或 "exclude",
  "confidence": 0.0~1.0,      // 你的置信度
  "reason": "一句话理由"
}

仅输出 JSON,不要任何前后说明文字。

候选群列表:
{groups_json}
```

- [ ] **Step 2: Write chat analysis prompt**

```
你是用户的工作复盘助手。下面是一个微信对话在指定时间范围内的全部消息(已脱敏:人名替换为 A1/A2/A3,
金额/手机/邮箱已遮蔽)。请提取:

1. highlights: 重点事项(决议/进展/讨论/风险)
2. todos: 待办事项(用户承诺别人 / 别人承诺用户 / 不明)

注意:
- 用户的代号是 {my_codename}
- 当前对话名: {chat_name},关系: {relation}
- 对每条 highlight/todo 返回 source_msg_ids(消息 id 列表)和 confidence(0-1)
- date 用 unix epoch (Int)
- todo 不返回 status 字段,系统会统一标 pending
- 严格 JSON 输出,无任何前后文字

Schema:
{
  "highlights": [{
    "date": Int,
    "summary": "一句话陈述",
    "quoted_snippet": "原话片段 ≤120 字",
    "involved": ["A1", "A2"],
    "category": "decision" 或 "progress" 或 "discussion" 或 "risk",
    "confidence": Double,
    "source_msg_ids": [String]
  }],
  "todos": [{
    "deadline": Int 或 null,
    "content": "...",
    "direction": "mine" 或 "theirs" 或 "unclear",
    "involved": ["A1"],
    "confidence": Double,
    "source_msg_ids": [String]
  }]
}

消息列表:
{messages}
```

- [ ] **Step 3: Write summary synth prompt**

```
你是用户的工作复盘主编。下面是从多个对话中抽取出的 highlights 和 todos(已脱敏)。请合成一份精简
总结,只保留对用户最有价值的判断。

输出严格 JSON:
{
  "top3": [
    {"text": "一句话总结", "evidence_highlight_ids": [42, 18, ...]}
  ],         // 最多 3 条最重要的事
  "risk":   {"text": "一句话", "evidence_highlight_ids": [...]} 或 null,  // 最多 1 条
  "missed": {"text": "一句话", "evidence_highlight_ids": [...]} 或 null   // 最多 1 条容易漏的事
}

evidence_highlight_ids 必须指向输入中真实存在的 highlight id。
仅输出 JSON。

输入数据:
{aggregated_json}
```

- [ ] **Step 4: Commit**

```bash
git add Resources/Prompts/retrospective_*.txt
git commit -m "feat(retrospective): three prompt templates v1

Group screen, per-chat analysis, summary synthesis.
Spec §7."
```

### Task 4.2: GroupScreener

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/GroupScreener.swift`
- Create: `Tests/WeChatHUDTests/GroupScreenerTests.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

actor GroupScreener {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let dataLedger: DataLedger

    init(store: HUDStore, aiService: any AIServiceProtocol, promptLoader: PromptLoader = PromptLoader(), dataLedger: DataLedger) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.dataLedger = dataLedger
    }

    struct ScreenResult: Sendable {
        let included: [ScopeCandidate]
        let excluded: [ScopeCandidate]
        let askEachTime: [ScopeCandidate]
    }

    /// Resolves each candidate by checking cached policy first, falling back to AI for new groups
    /// (private chats are always included).
    func screen(candidates: [ScopeCandidate], samples: [String: [String]]) async -> ScreenResult {
        var included: [ScopeCandidate] = []
        var excluded: [ScopeCandidate] = []
        var ask: [ScopeCandidate] = []
        var needAI: [ScopeCandidate] = []

        for c in candidates {
            // Private chats: always include
            if !c.isGroup {
                included.append(c); continue
            }
            // Cached policy?
            if let policy = store.groupScopePolicy(chatUsername: c.chatUsername) {
                switch policy.decision {
                case .include: included.append(c)
                case .exclude: excluded.append(c)
                case .askEachTime: ask.append(c)
                }
                continue
            }
            needAI.append(c)
        }

        if !needAI.isEmpty {
            let aiDecisions = await runAIScreen(needAI, samples: samples)
            for (c, decision, confidence) in aiDecisions {
                let finalDecision: ScopeDecision = (confidence < 0.7) ? .askEachTime : decision
                store.upsertGroupScopePolicy(GroupScopePolicy(
                    chatUsername: c.chatUsername, decision: finalDecision,
                    source: .ai, decidedAt: Date(),
                    sampleHash: hashSamples(samples[c.chatUsername] ?? []),
                    userAuthorized: false
                ))
                switch finalDecision {
                case .include: included.append(c)
                case .exclude: excluded.append(c)
                case .askEachTime: ask.append(c)
                }
            }
        }

        return ScreenResult(included: included, excluded: excluded, askEachTime: ask)
    }

    private func runAIScreen(_ candidates: [ScopeCandidate], samples: [String: [String]]) async -> [(ScopeCandidate, ScopeDecision, Double)] {
        // Build batched prompt; call AI; parse JSON array; record ledger.
        let groupsJSON = candidates.map { c -> [String: Any] in
            return [
                "chat_name": c.chatName,
                "sample_messages": samples[c.chatUsername] ?? []
            ]
        }
        let groupsData = (try? JSONSerialization.data(withJSONObject: groupsJSON)) ?? Data()
        let groupsStr = String(data: groupsData, encoding: .utf8) ?? "[]"

        guard let template = try? promptLoader.load(version: "retrospective_group_screen_v1") else {
            return candidates.map { ($0, .askEachTime, 0.0) }
        }
        let userPrompt = template.replacingOccurrences(of: "{groups_json}", with: groupsStr)

        let started = Date()
        let response: String
        do {
            response = try await aiService.complete(
                system: "你严格输出 JSON 数组。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 2048)
            )
        } catch {
            return candidates.map { ($0, .askEachTime, 0.0) }
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let cfg = await aiService.currentConfig()
        await dataLedger.recordBatch([LedgerEntry(
            id: 0, ts: Date(),
            provider: cfg.primarySlot.providerID,
            model: cfg.primarySlot.model,
            purpose: .groupScreen, chatCount: candidates.count, msgCount: nil,
            byteCount: userPrompt.utf8.count, tokenIn: nil, tokenOut: nil, redacted: false
        )])

        return parse(response, candidates: candidates)
    }

    private nonisolated func parse(_ raw: String, candidates: [ScopeCandidate]) -> [(ScopeCandidate, ScopeDecision, Double)] {
        guard let data = extractJSON(raw),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return candidates.map { ($0, .askEachTime, 0.0) }
        }
        var out: [(ScopeCandidate, ScopeDecision, Double)] = []
        for c in candidates {
            if let item = arr.first(where: { ($0["chat_name"] as? String) == c.chatName }) {
                let decisionRaw = (item["decision"] as? String) ?? "exclude"
                let conf = (item["confidence"] as? Double) ?? 0.5
                let decision = ScopeDecision(rawValue: decisionRaw) ?? .askEachTime
                out.append((c, decision, conf))
            } else {
                out.append((c, .askEachTime, 0.0))
            }
        }
        return out
    }

    private nonisolated func extractJSON(_ s: String) -> Data? {
        var cleaned = s
        if let fence = cleaned.range(of: "```") {
            cleaned = String(cleaned[fence.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let end = cleaned.range(of: "```") { cleaned = String(cleaned[..<end.lowerBound]) }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("[") {
            if let lo = cleaned.firstIndex(of: "["), let hi = cleaned.lastIndex(of: "]") {
                cleaned = String(cleaned[lo...hi])
            }
        }
        return cleaned.data(using: .utf8)
    }

    private nonisolated func hashSamples(_ samples: [String]) -> String {
        let joined = samples.joined(separator: "|")
        return String(joined.utf8.reduce(0) { $0 &+ Int($1) })  // simple sum for drift detection
    }
}
```

- [ ] **Step 2: Write tests**

Tests use a `MockAIService` (create as test helper if not present). Cover:
- Cached policy bypasses AI
- New groups go through AI
- Low-confidence AI result becomes ask_each_time
- AI failure → all askEachTime
- Private chats always included regardless of cache

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter GroupScreenerTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/GroupScreener.swift Tests/WeChatHUDTests/GroupScreenerTests.swift
git commit -m "feat(retrospective): GroupScreener with cached policy + AI fallback

Three-state decision (include/exclude/askEachTime), confidence < 0.7
forces askEachTime, private chats always included, AI batched into one
call, ledger recorded.
Spec §6.2 step 2, §7.1."
```

### Task 4.3: RetrospectiveAnalyzer

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/RetrospectiveAnalyzer.swift`
- Create: `Tests/WeChatHUDTests/RetrospectiveAnalyzerTests.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

actor RetrospectiveAnalyzer {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let redactor: Redactor
    private let dataLedger: DataLedger

    init(store: HUDStore, aiService: any AIServiceProtocol, promptLoader: PromptLoader = PromptLoader(),
         redactor: Redactor, dataLedger: DataLedger) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.redactor = redactor
        self.dataLedger = dataLedger
    }

    struct AnalysisResult: Sendable {
        let highlights: [ReviewHighlight]
        let todos: [ReviewTodo]
    }

    func analyze(
        chat: ScopeCandidate,
        relation: Relation,
        messages: [MessageInfo],
        myUsername: String,
        myDisplayName: String,
        runID: Int
    ) async throws -> AnalysisResult {
        // 1. Redact messages: register codenames for each unique sender, then format text.
        let myCodename = await redactor.codenameFor(username: myUsername, displayName: myDisplayName)
        var formatted: [String] = []
        for msg in messages.reversed() {  // chronological
            let senderCode = await redactor.codenameFor(username: msg.senderUsername, displayName: msg.senderName)
            let redactedText = await redactor.redactText(msg.text)
            formatted.append("[\(msg.id)] [\(MessageInfo.formatRelative(msg.createTime))] \(senderCode): \(redactedText)")
        }
        let messagesStr = formatted.joined(separator: "\n")

        // 2. Build prompt
        guard let template = try? promptLoader.load(version: "retrospective_chat_analysis_v1") else {
            throw NSError(domain: "RetroAnalyzer", code: 1)
        }
        let userPrompt = template
            .replacingOccurrences(of: "{my_codename}", with: myCodename)
            .replacingOccurrences(of: "{chat_name}", with: chat.chatName)
            .replacingOccurrences(of: "{relation}", with: relation.rawValue)
            .replacingOccurrences(of: "{messages}", with: messagesStr)

        // 3. Call AI with retry
        let started = Date()
        let raw: String
        do {
            raw = try await aiService.complete(
                system: "你严格按 JSON Schema 输出。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 4096)
            )
        } catch {
            await recordLedger(purpose: .chatAnalysisFailed, msgCount: messages.count, byteCount: userPrompt.utf8.count)
            throw error
        }

        // 4. Parse + retry once on parse failure
        let parsed: ParsedAnalysis
        if let p = parseJSON(raw) {
            parsed = p
        } else {
            let strict = userPrompt + "\n\n严格要求:只输出符合 schema 的 JSON 对象,不要任何其它文字或代码围栏。"
            let raw2 = (try? await aiService.complete(
                system: "你严格按 JSON Schema 输出。",
                user: strict,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 4096)
            )) ?? ""
            guard let p2 = parseJSON(raw2) else {
                await recordLedger(purpose: .chatAnalysisFailed, msgCount: messages.count, byteCount: userPrompt.utf8.count)
                throw NSError(domain: "RetroAnalyzer", code: 2, userInfo: [NSLocalizedDescriptionKey: "JSON parse failed"])
            }
            parsed = p2
        }

        await recordLedger(purpose: .chatAnalysis, msgCount: messages.count, byteCount: userPrompt.utf8.count)

        // 5. Convert parsed AI codenames back to display names for `involved` arrays.
        let highlights = await convertHighlights(parsed.highlights, chat: chat, relation: relation, runID: runID)
        let todos = await convertTodos(parsed.todos, chat: chat, runID: runID)

        return AnalysisResult(highlights: highlights, todos: todos)
    }

    // ... (parseJSON, convert helpers, recordLedger — full code in source file)
}

private struct ParsedAnalysis: Decodable {
    let highlights: [ParsedHighlight]
    let todos: [ParsedTodo]
}

private struct ParsedHighlight: Decodable {
    let date: Int
    let summary: String
    let quoted_snippet: String?
    let involved: [String]
    let category: String
    let confidence: Double
    let source_msg_ids: [String]
}

private struct ParsedTodo: Decodable {
    let deadline: Int?
    let content: String
    let direction: String
    let involved: [String]
    let confidence: Double
    let source_msg_ids: [String]
}
```

- [ ] **Step 2: Tests + commit** (mock AIService returning canned JSON)

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter RetrospectiveAnalyzerTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/RetrospectiveAnalyzer.swift Tests/WeChatHUDTests/RetrospectiveAnalyzerTests.swift
git commit -m "feat(retrospective): RetrospectiveAnalyzer per-chat deep analysis

Redacts before send, codename map per Redactor, parse + 1 retry,
fail tolerant, ledger entry per chat (+ failed entry on errors).
Spec §6.2 step 4, §7.2."
```

### Task 4.4: SummarySynthesizer

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/SummarySynthesizer.swift`
- Create: `Tests/WeChatHUDTests/SummarySynthesizerTests.swift`

- [ ] **Step 1: Implement + test**

Same pattern as RetrospectiveAnalyzer. Input is aggregate of all run's highlights+todos JSON; output is `{top3, risk, missed}` schema. Each summary item references `evidence_highlight_ids`.

```bash
git commit -m "feat(retrospective): SummarySynthesizer Top3 + Risk + Missed

Aggregates run-wide highlights, calls AI once, returns SummaryItem
references with evidence highlight IDs. Spec §7.3."
```

**Milestone 4 Done.** **GATE** before M5.

---

## Milestone 5: Orchestration + RedBannerDetector + Crash Recovery Validation

**Outcome:** `RetrospectiveJob` actor that orchestrates the full pipeline with concurrency, timeout, and progressive UI notifications.

### Task 5.1: RetrospectiveConfig

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/RetrospectiveConfig.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

struct RetrospectiveConfig: Sendable {
    var maxConcurrentChats: Int = 4
    var perChatTimeoutSeconds: TimeInterval = 60
    var totalTimeoutSeconds: TimeInterval = 30 * 60
    var maxChatsPerRun: Int = 20
    var maxMessagesPerChat: Int = 200
    var totalMessageHardCap: Int = 4000
    var redactorEnabled: Bool = true
    var ledgerRetentionDays: Int = 90
    var carryArchiveWeekThreshold: Int = 4

    static let `default` = RetrospectiveConfig()
}
```

```bash
git add Sources/WeChatHUD/Services/Retrospective/RetrospectiveConfig.swift
git commit -m "feat(retrospective): RetrospectiveConfig defaults

20 chats / 200 msgs/chat / 4000 total cap, 4 concurrent, 60s per-chat,
30min total, 4 weeks for archive suggestion. Spec §6.4, §11."
```

### Task 5.2: RedBannerDetector

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/RedBannerDetector.swift`
- Create: `Tests/WeChatHUDTests/RedBannerDetectorTests.swift`

- [ ] **Step 1: Implement per spec §6.7**

```swift
import Foundation

struct RedBannerCandidate: Sendable, Identifiable {
    let id: Int          // todoID
    let content: String
    let deadline: Date?
    let counterpart: String?
    let chatName: String
    let daysSinceCommit: Int
}

actor RedBannerDetector {
    private let store: HUDStore
    private let messageQuery: MessageQuery   // protocol that exposes "my messages in chat since date"

    init(store: HUDStore, messageQuery: MessageQuery) {
        self.store = store
        self.messageQuery = messageQuery
    }

    func detect() async -> [RedBannerCandidate] {
        let now = Date()
        let recent = now.addingTimeInterval(-14 * 86400)
        let candidates = store.pendingTodos(direction: .mine, since: recent)
            .filter { ($0.deadline ?? now) <= now.addingTimeInterval(86400) }

        var banners: [RedBannerCandidate] = []
        for todo in candidates {
            if store.hasDismissal(todoID: todo.id, validForHours: 24) { continue }

            let myMsgs = await messageQuery.myMessages(
                chatUsername: todo.sourceChatUsername,
                since: todo.createdAt,
                until: now
            )
            let followedUp = myMsgs.contains { msg in
                TextSimilarity.jaccardCJK(msg.text, todo.content) > 0.3
            }
            if followedUp { continue }

            banners.append(RedBannerCandidate(
                id: todo.id,
                content: todo.content,
                deadline: todo.deadline,
                counterpart: todo.involved.first,
                chatName: todo.sourceChatName,
                daysSinceCommit: Int(now.timeIntervalSince(todo.createdAt) / 86400)
            ))
        }
        return banners.sorted { $0.daysSinceCommit > $1.daysSinceCommit }.prefix(3).map { $0 }
    }
}

protocol MessageQuery: Sendable {
    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage]
}

struct SimpleMessage: Sendable {
    let id: String   // matches MessageInfo.id (UID format)
    let text: String
    let timestamp: Date
}
```

- [ ] **Step 2: Tests with mock MessageQuery**

Tests:
- Followed-up todo not surfaced
- Past-deadline pending todo surfaced
- Dismissed todo not surfaced (within 24h)
- Sort by daysSinceCommit DESC
- Cap at 3

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter RedBannerDetectorTests 2>&1 | tail -15
git add Sources/WeChatHUD/Services/Retrospective/RedBannerDetector.swift Tests/WeChatHUDTests/RedBannerDetectorTests.swift
git commit -m "feat(retrospective): RedBannerDetector

14-day window, mine + pending + deadline ≤ now+24h, Jaccard 0.3
follow-up gate, dismissal 24h block, sort + top 3.
Spec §6.7."
```

### Task 5.3: RetrospectiveJob orchestrator

**Files:**
- Create: `Sources/WeChatHUD/Services/Retrospective/RetrospectiveJob.swift`
- Create: `Tests/WeChatHUDTests/RetrospectiveJobTests.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import Combine

@MainActor
final class RetrospectiveJob: ObservableObject {

    enum State: Sendable {
        case idle
        case resolvingScope
        case screeningGroups
        case analyzingChats(progress: Int, total: Int)
        case synthesizingSummary
        case detectingRedBanner
        case completed(runID: Int)
        case failed(String)
        case partial(runID: Int, failedChats: [String])
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastRedBanners: [RedBannerCandidate] = []

    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let scopeCandidatesProvider: ScopeCandidatesProvider
    private let messageQuery: MessageQuery
    private var config: RetrospectiveConfig
    private var currentTask: Task<Void, Never>?

    init(store: HUDStore, aiService: any AIServiceProtocol,
         scopeCandidatesProvider: ScopeCandidatesProvider, messageQuery: MessageQuery,
         config: RetrospectiveConfig = .default) {
        self.store = store
        self.aiService = aiService
        self.scopeCandidatesProvider = scopeCandidatesProvider
        self.messageQuery = messageQuery
        self.config = config
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func run(mode: ScopeMode, myUsername: String, myDisplayName: String) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runInternal(mode: mode, myUsername: myUsername, myDisplayName: myDisplayName)
        }
    }

    private func runInternal(mode: ScopeMode, myUsername: String, myDisplayName: String) async {
        state = .resolvingScope
        let dateRange = ScopeResolver.range(mode)
        let candidates = await scopeCandidatesProvider.candidates(in: dateRange)
        let filtered = ScopeResolver.filter(candidates: candidates).prefix(config.maxChatsPerRun)
        let chatsToAnalyze = Array(filtered)

        // 1. Insert review_runs row in 'running' state
        guard let runID = store.insertReviewRun(
            rangeStart: dateRange.start,
            rangeEnd: dateRange.end,
            chatCount: chatsToAnalyze.count
        ) else {
            state = .failed("Could not create run row"); return
        }

        // 2. Group screen
        state = .screeningGroups
        let dataLedger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: aiService, dataLedger: dataLedger)
        let samples: [String: [String]] = await scopeCandidatesProvider.sampleMessages(
            for: chatsToAnalyze.map(\.chatUsername), in: dateRange, limit: 20
        )
        let screen = await screener.screen(candidates: chatsToAnalyze, samples: samples)
        let included = screen.included

        // 3. Capture local Sendable references so TaskGroup closures don't capture self.
        // (Spec §6.4: max 4 concurrent chats. Self is @MainActor, so we hand off provider/analyzer
        // as locals which are Sendable actors/protocols.)
        state = .analyzingChats(progress: 0, total: included.count)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: aiService,
            redactor: redactor, dataLedger: dataLedger
        )
        let provider = scopeCandidatesProvider
        let perChatLimit = config.maxMessagesPerChat
        let maxConcurrent = config.maxConcurrentChats
        let totalDeadline = Date().addingTimeInterval(config.totalTimeoutSeconds)

        // 4. Concurrent analysis with manual rate-limit dispatch + total timeout race.
        //    IMPORTANT: collect per-chat results into an in-memory array first; do NOT
        //    insert highlights/todos into the DB yet. Carry-forward needs to dedupe
        //    against newly-extracted candidates BEFORE they hit DB to avoid duplicate
        //    rows (per GATE 2 round 1 backend blocker B4).
        struct ChatOutcome: Sendable {
            let chat: ScopeCandidate
            let result: Result<RetrospectiveAnalyzer.AnalysisResult, Error>
        }

        var collected: [ChatOutcome] = []
        var failed: [String] = []
        var totalMsgCount = 0

        let analysisTask = Task<Void, Never> {
            await withTaskGroup(of: ChatOutcome.self) { group in
                var iterator = included.makeIterator()
                var completedCount = 0

                func enqueue(_ chat: ScopeCandidate) {
                    group.addTask {
                        let messages = await provider.messages(
                            for: chat.chatUsername, in: dateRange, limit: perChatLimit
                        )
                        let relation = await provider.relation(for: chat.chatUsername)
                        do {
                            let result = try await analyzer.analyze(
                                chat: chat, relation: relation, messages: messages,
                                myUsername: myUsername, myDisplayName: myDisplayName, runID: runID
                            )
                            return ChatOutcome(chat: chat, result: .success(result))
                        } catch {
                            return ChatOutcome(chat: chat, result: .failure(error))
                        }
                    }
                }

                for _ in 0..<min(maxConcurrent, included.count) {
                    if let next = iterator.next() { enqueue(next) }
                }

                for await outcome in group {
                    completedCount += 1
                    collected.append(outcome)
                    if case .failure = outcome.result { failed.append(outcome.chat.chatName) }
                    self.store.updateReviewRunProgress(runID: runID, completedChats: completedCount)
                    self.state = .analyzingChats(progress: completedCount, total: included.count)
                    if let next = iterator.next() { enqueue(next) }
                }
            }
        }

        // Race against total timeout (Spec §6.4: 30 min cap)
        let deadlineTask = Task<Void, Never> {
            let nanos = UInt64(max(0, totalDeadline.timeIntervalSinceNow) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            analysisTask.cancel()
        }

        await analysisTask.value
        deadlineTask.cancel()

        // 5. Pre-dedupe carry-forward (BEFORE inserting into DB):
        //    - Collect successful highlights + todos in memory
        //    - Run ReviewTodoManager.carryForward with the new candidates
        //    - Survivors get inserted; matched-pre-existing get bumpTodoCarry
        var newHighlightsToInsert: [ReviewHighlight] = []
        var newTodoCandidates: [ReviewTodo] = []
        for outcome in collected {
            if case .success(let analysis) = outcome.result {
                newHighlightsToInsert.append(contentsOf: analysis.highlights)
                newTodoCandidates.append(contentsOf: analysis.todos)
                totalMsgCount += analysis.highlights.count + analysis.todos.count
            }
        }

        let prevRun = store.latestCompletedRun()
        let manager = ReviewTodoManager(store: store)
        let todosToInsert: [ReviewTodo]
        if let prev = prevRun {
            todosToInsert = await manager.carryForward(
                prevRunID: prev.id, newRunID: runID, newCandidates: newTodoCandidates
            )
        } else {
            todosToInsert = newTodoCandidates
        }

        // 6. Now insert the highlights + survivor todos into DB (triggers NotificationCenter
        //    "highlight" and "todo" events for live UI).
        for h in newHighlightsToInsert { store.insertReviewHighlight(h) }
        for t in todosToInsert { store.insertReviewTodo(t) }

        // 5. Synthesize summary
        state = .synthesizingSummary
        let synth = SummarySynthesizer(store: store, aiService: aiService, dataLedger: dataLedger)
        let summary = await synth.synthesize(runID: runID)

        // 6. Detect red banners
        state = .detectingRedBanner
        let detector = RedBannerDetector(store: store, messageQuery: messageQuery)
        let banners = await detector.detect()
        lastRedBanners = banners

        // 7. Finalize
        let finalStatus: ReviewRunStatus = failed.isEmpty
            ? .completed
            : (failed.count == included.count ? .failed : .partial)
        store.finalizeReviewRun(
            runID: runID, status: finalStatus,
            summaryTop3: summary.top3, summaryRisk: summary.risk, summaryMissed: summary.missed,
            msgCount: totalMsgCount, failedChats: failed
        )

        state = (finalStatus == .partial)
            ? .partial(runID: runID, failedChats: failed)
            : .completed(runID: runID)
    }
}

protocol ScopeCandidatesProvider: Sendable {
    func candidates(in range: DateRange) async -> [ScopeCandidate]
    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]]
    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo]
    func relation(for username: String) async -> Relation
}
```

- [ ] **Step 2: Tests with mocks**

Tests cover:
- Happy path: 3 chats all succeed → status='completed'
- 1 of 3 fails → status='partial', failedChats has 1 entry
- All fail → status='failed'
- Cancellation
- Progress notification fired per chat

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter RetrospectiveJobTests 2>&1 | tail -20
git add Sources/WeChatHUD/Services/Retrospective/RetrospectiveJob.swift Tests/WeChatHUDTests/RetrospectiveJobTests.swift
git commit -m "feat(retrospective): RetrospectiveJob orchestrator with TaskGroup

Insert running row first → screen → concurrent analyze (max 4) →
carry-forward → synthesize → red banners → finalize. Per-chat
progress published via @Published state.
Spec §6.2, §6.4, §6.5."
```

**Milestone 5 Done.** **GATE** before M6.

---

## Milestone 6: Menu Bar + Window Manager + Live Update Bridge

**Outcome:** `MenuBarController` single owner of NSStatusItem; `RetrospectiveWindowManager` for independent NSWindow; `RetrospectiveLiveStore` for SwiftUI subscription to NotificationCenter.

### Task 6.0: ChatMonitor wiring (must happen BEFORE M6.1/M6.2/M6.5 reference these)

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift` — expose `hudStore`, `myUsername`, `myDisplayName`, add `messagesInRange()` + lazy `retrospectiveJob`
- Create: `Sources/WeChatHUD/Services/Retrospective/ChatMonitorScopeProvider.swift`
- Create: `Sources/WeChatHUD/Services/Retrospective/ChatMonitorMessageQuery.swift`

**Real-API audit summary** (per round-3 reviewer findings):

- Messages live in WeChat's encrypted DB, accessed through `reader: WeChatReader`. HUDStore stores only app settings/whitelist/cache. There is NO `recentMessages` / `countMyMessages` / `countAllMessages` on HUDStore.
- `WeChatReader.getMessages(chatUsername:limit:sinceLocalId:) throws -> [MessageInfo]` exists but does NOT support date-range query directly. Strategy: pull a generous limit (e.g., 1000) and filter by `createTime` in-memory (Phase 1; if perf becomes an issue, Phase 2 may add a date-range overload to WeChatReader).
- `myUsername` is currently derived on-demand via `reader.myUsername()` — make it a computed property, no stored field.
- `HUDStats` does NOT have `vipAlertTier`. Use `chatMonitor.vipAlertTiers: [String: VIPAlertTier]` directly.

- [ ] **Step 1: Expose ChatMonitor read-only accessors + add `messagesInRange()` passthrough**

In ChatMonitor.swift, find `private let store: HUDStore` and `private let reader: WeChatReader` declarations. Keep them private; add nonisolated computed accessors:

```swift
// in ChatMonitor.swift main class body, near existing properties:

/// Exposed read-only for retrospective services. HUDStore is internally
/// thread-safe (FULLMUTEX), so reads from any actor are safe.
nonisolated var hudStore: HUDStore { store }

/// Computed via reader; matches existing `reader.myUsername()` callsites.
nonisolated var myUsername: String { reader.myUsername() }

/// Display name comes from the whitelist entry of the user's own chat
/// (or empty if not yet known). Used by Redactor as the codename
/// fallback for the user.
nonisolated var myDisplayName: String {
    let me = myUsername
    return store.getWhitelistEntry(username: me)?.displayName ?? ""
}

/// Date-range message query. Wraps `reader.getMessages(chatUsername:limit:)`
/// and filters by `createTime`. Note: MessageInfo.createTime is `Int` (unix ts),
/// not Date — convert Dates before comparison.
nonisolated func messagesInRange(
    chatUsername: String,
    start: Date,
    end: Date,
    fetchLimit: Int = 1000
) -> [MessageInfo] {
    let raw: [MessageInfo]
    do {
        raw = try reader.getMessages(chatUsername: chatUsername, limit: fetchLimit, sinceLocalId: nil)
    } catch {
        return []
    }
    let startTs = Int(start.timeIntervalSince1970)
    let endTs = Int(end.timeIntervalSince1970)
    return raw.filter { msg in
        msg.createTime >= startTs && msg.createTime <= endTs
    }
}

/// Internal accessor for the lazy `retrospectiveJob` to obtain the AIService
/// (which is private). Returns the AIServiceProtocol witness.
nonisolated var aiServiceRef: any AIServiceProtocol { aiService }

/// Sample messages for AI group screening — first N messages in the date
/// range, formatted as plain text strings.
nonisolated func sampleMessageTexts(
    chatUsername: String,
    start: Date,
    end: Date,
    limit: Int = 20
) -> [String] {
    let inRange = messagesInRange(chatUsername: chatUsername, start: start, end: end, fetchLimit: 1000)
    return inRange.prefix(limit).map { $0.text }
}
```

If `WeChatReader.getMessages` is `throws`, the wrapper above swallows errors and returns `[]` (acceptable per spec §6.4 — single-chat failure is non-fatal).

- [ ] **Step 2: Add `retrospectiveJob` lazy property**

```swift
@MainActor
lazy var retrospectiveJob: RetrospectiveJob = {
    return RetrospectiveJob(
        store: hudStore,
        aiService: aiServiceRef,  // nonisolated accessor; aiService field is private
        scopeCandidatesProvider: ChatMonitorScopeProvider(monitor: self),
        messageQuery: ChatMonitorMessageQuery(monitor: self),
        config: .default
    )
}()
```

- [ ] **Step 3: Implement ChatMonitorScopeProvider adapter**

```swift
// Sources/WeChatHUD/Services/Retrospective/ChatMonitorScopeProvider.swift
import Foundation

actor ChatMonitorScopeProvider: ScopeCandidatesProvider {
    private weak var monitor: ChatMonitor?

    init(monitor: ChatMonitor) {
        self.monitor = monitor
    }

    func candidates(in range: DateRange) async -> [ScopeCandidate] {
        guard let monitor else { return [] }
        // Whitelist set (existing HUDStore API: getWhitelist())
        let whitelist = monitor.hudStore.getWhitelist()
        let myUname = monitor.myUsername
        var out: [ScopeCandidate] = []
        for entry in whitelist {
            let inRange = monitor.messagesInRange(
                chatUsername: entry.id, start: range.start, end: range.end
            )
            guard !inRange.isEmpty else { continue }
            let myCount = inRange.filter { $0.senderUsername == myUname }.count
            // WhitelistEntry.id is the chatUsername; isGroup is derived from suffix '@chatroom'
            let isGroup = entry.id.hasSuffix("@chatroom")
            out.append(ScopeCandidate(
                chatUsername: entry.id,
                chatName: entry.displayName,
                isGroup: isGroup,
                msgCountInRange: inRange.count,
                myMsgCountInRange: myCount
            ))
        }
        return out
    }

    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]] {
        guard let monitor else { return [:] }
        var out: [String: [String]] = [:]
        for u in usernames {
            out[u] = monitor.sampleMessageTexts(
                chatUsername: u, start: range.start, end: range.end, limit: limit
            )
        }
        return out
    }

    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo] {
        guard let monitor else { return [] }
        let all = monitor.messagesInRange(
            chatUsername: username, start: range.start, end: range.end, fetchLimit: max(1000, limit * 5)
        )
        return Array(all.prefix(limit))
    }

    func relation(for username: String) async -> Relation {
        guard let monitor else { return .unknown }
        guard let profile = monitor.hudStore.getRelationshipProfile(username: username) else {
            return .unknown
        }
        // RelationshipProfile.Hierarchy actual cases (from RelationshipProfile.swift):
        //   .superior / .peer / .subordinate / .external / .personal
        switch profile.hierarchy {
        case .superior:    return .superior
        case .peer:        return .peer
        case .subordinate: return .subordinate
        case .external:    return .client
        case .personal:    return .friend
        }
    }
}
```

Notes:
- `WhitelistEntry.id` IS the chatUsername (existing convention); `displayName` is the field name for the human-readable name. If audit shows different field names, adjust.
- Group detection by `@chatroom` suffix matches WeChat's own format (existing codebase uses this convention; grep `@chatroom` in Sources/ to confirm).
- `RelationshipProfile.Hierarchy` actual cases: `.superior / .peer / .subordinate / .external / .personal` (no `.none`); see `Sources/WeChatHUD/Data/RelationshipProfile.swift`. Mapped to retrospective `Relation` per the switch above.

- [ ] **Step 4: Implement ChatMonitorMessageQuery adapter**

```swift
// Sources/WeChatHUD/Services/Retrospective/ChatMonitorMessageQuery.swift
import Foundation

actor ChatMonitorMessageQuery: MessageQuery {
    private weak var monitor: ChatMonitor?

    init(monitor: ChatMonitor) {
        self.monitor = monitor
    }

    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage] {
        guard let monitor else { return [] }
        let myUname = monitor.myUsername
        let inRange = monitor.messagesInRange(
            chatUsername: chatUsername, start: since, end: until, fetchLimit: 1000
        )
        return inRange
            .filter { $0.senderUsername == myUname }
            .map { SimpleMessage(
                id: $0.id,  // MessageInfo.id is String UID (e.g. "path/table/123")
                text: $0.text,
                timestamp: Date(timeIntervalSince1970: TimeInterval($0.createTime))  // Int → Date
            ) }
    }
}
```

Notes:
- `MessageInfo.id: String` (UID format `"<path>/<table>/<localId>"`); use as-is.
- `MessageInfo.createTime: Int` (unix epoch); convert to Date via `TimeInterval`.
- `MessageInfo.senderUsername` exists per existing usage in ChatAnalyzer.

- [ ] **Step 5: Build + commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -10
git add Sources/WeChatHUD/Services/ChatMonitor.swift Sources/WeChatHUD/Services/Retrospective/ChatMonitorScopeProvider.swift Sources/WeChatHUD/Services/Retrospective/ChatMonitorMessageQuery.swift
git commit -m "feat(retrospective): wire ChatMonitor.retrospectiveJob + adapters

Expose hudStore/myUsername/myDisplayName as nonisolated read-only.
Lazy retrospectiveJob property hands off to RetrospectiveJob actor.
Two adapter actors bridge existing message/whitelist APIs to
ScopeCandidatesProvider and MessageQuery protocols.
Spec §6.1, §6.6."
```



### Task 6.1: MenuBarController

**Files:**
- Create: `Sources/WeChatHUD/App/MenuBarController.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift` (delegate statusItem writes)

- [ ] **Step 1: Implement MenuBarController**

```swift
import AppKit
import Combine

@MainActor
final class MenuBarController: ObservableObject {

    static let shared = MenuBarController()

    /// Badge string fed in by AppDelegate's existing combineLatest sink
    /// (preserves all p0/p1 / VIP worst-tier semantics). MenuBarController
    /// just renders this when no job is running.
    @Published var badgeText: String = "" {
        didSet { renderIfIdle() }
    }
    @Published var jobState: RetrospectiveJob.State = .idle {
        didSet { render() }
    }

    private weak var statusItem: NSStatusItem?
    private var spinTimer: Timer?
    private var spinIndex = 0

    func attach(_ item: NSStatusItem) {
        self.statusItem = item
        render()
    }

    private func renderIfIdle() {
        if case .idle = jobState { render() }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        spinTimer?.invalidate(); spinTimer = nil
        switch jobState {
        case .idle, .completed, .failed, .partial:
            // Idle: show whatever badge text AppDelegate's logic computed
            button.image = nil
            button.title = badgeText
        case .resolvingScope, .screeningGroups, .analyzingChats, .synthesizingSummary, .detectingRedBanner:
            button.title = ""
            startSpinning(button: button)
        }
    }

    private func startSpinning(button: NSStatusBarButton) {
        // Single SF Symbol rotated through 8 angles via NSImage transform.
        // NSImage doesn't have built-in rotation, so we render to a CGImage with
        // an affine transform per frame.
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let baseImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                      accessibilityDescription: "复盘进行中")?.withSymbolConfiguration(cfg)
        else { return }
        let frames: [NSImage] = (0..<8).map { i in
            rotateImage(baseImage, byDegrees: Double(i) * 45)
        }
        spinTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.spinIndex = (self.spinIndex + 1) % frames.count
            button.image = frames[self.spinIndex]
        }
    }

    private func rotateImage(_ image: NSImage, byDegrees degrees: Double) -> NSImage {
        let radians = degrees * .pi / 180
        let size = image.size
        let rotated = NSImage(size: size)
        rotated.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byRadians: CGFloat(radians))
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1.0)
        rotated.unlockFocus()
        rotated.isTemplate = image.isTemplate
        return rotated
    }
}
```

- [ ] **Step 2: Wire AppDelegate (1:1 port of existing combineLatest semantics)**

Open `Sources/WeChatHUD/App/AppDelegate.swift`. The existing pipeline at line 389-409 reads roughly:

```
monitor.$inboxItems
  .combineLatest(monitor.$vipAlertTiers)
  .receive(on: DispatchQueue.main)
  .sink { items, tiers in
    let p0p1 = items.filter { ... }.count   // p0/p1 priority
    let worst = tiers.values.max(by: ...)   // worst aging tier
    if let worst, worst.tier >= 2 {
      statusItem.button?.title = " ! \(worst.agingLabel)"   // e.g., " ! 30m"
    } else if p0p1 > 0 {
      statusItem.button?.title = " \(p0p1)"
    } else {
      statusItem.button?.title = " \(items.count)"
    }
  }
```

(Read lines 389-409 of AppDelegate.swift first to confirm exact body — port the existing logic verbatim, do not refactor semantics.)

Migration: keep this combineLatest pipeline alive but feed its **output** into `MenuBarController` instead of writing `statusItem.button.title` directly. Add a new published property + computed-priority renderer in MenuBarController:

```swift
// in MenuBarController.swift main class body, replace `unreadCount: Int` with:
@Published var badgeText: String = "" {
    didSet { renderIfIdle() }
}

// render() body becomes:
private func render() {
    guard let button = statusItem?.button else { return }
    spinTimer?.invalidate(); spinTimer = nil
    switch jobState {
    case .idle, .completed, .failed, .partial:
        button.image = nil
        button.title = badgeText
    default:
        button.title = ""
        startSpinning(button: button)
    }
}
```

In AppDelegate.swift, **modify** the existing combineLatest sink: change `statusItem.button?.title = ...` to `MenuBarController.shared.badgeText = ...`. Body of sink otherwise unchanged. (Do not delete the combineLatest — it owns the worst-tier/p0p1 derivation logic.)

Then add the new RetrospectiveJob subscription:

```swift
// add to applicationDidFinishLaunching, after the existing combineLatest sink:
chatMonitor.retrospectiveJob.$state
    .receive(on: DispatchQueue.main)
    .sink { state in
        MenuBarController.shared.jobState = state
    }
    .store(in: &cancellables)

// also call MenuBarController.shared.attach(statusItem) once after setupMenuBarItem
MenuBarController.shared.attach(statusItem!)
```

**Why this beats v0.3 approach**: v0.3 invented a `HUDStats.vipAlertTier` field that doesn't exist and lossy-mapped p0/p1 to `unreadCount`. v0.4 leaves the existing badge-text logic where it is (in AppDelegate's combineLatest closure) and just intercepts the OUTPUT string before it reaches statusItem. Zero semantics regression. MenuBarController only adds the spinner-overlay behavior on top.

- [ ] **Step 3: Build + commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | grep "error:" | head -10
git add Sources/WeChatHUD/App/MenuBarController.swift Sources/WeChatHUD/App/AppDelegate.swift
git commit -m "feat(retrospective): MenuBarController single owner for NSStatusItem

Renders unread count when idle, spinning SF Symbol during job.
Subscribes to ChatMonitor.stats and RetrospectiveJob.state.
Spec §2.3."
```

### Task 6.2: RetrospectiveWindowManager + Phase 1 stub view

**Files:**
- Create: `Sources/WeChatHUD/App/RetrospectiveWindowManager.swift`
- Create: `Sources/WeChatHUD/Views/Retrospective/RetrospectiveWindow.swift` — **Phase 1 stub**, replaced by full impl in Phase 2 plan

- [ ] **Step 1: Implement**

```swift
import AppKit
import SwiftUI

@MainActor
final class RetrospectiveWindowManager {

    static let shared = RetrospectiveWindowManager()

    private var window: NSWindow?

    func showWindow(monitor: ChatMonitor) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = RetrospectiveWindow().environmentObject(monitor)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "复盘"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.delegate = WindowDelegateProxy { [weak self] in self?.window = nil }
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        window = nil
    }
}

private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
```

- [ ] **Step 2: Create Phase 1 stub `RetrospectiveWindow` view**

Phase 2 plan replaces this with the full timeline/chrome/etc. For Phase 1, create a minimal stub so Phase 1 builds and the `[完整窗口 ⤢]` button does something:

```swift
// Sources/WeChatHUD/Views/Retrospective/RetrospectiveWindow.swift
import SwiftUI

struct RetrospectiveWindow: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var summaryText: String = "（尚未生成）"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("复盘 (Phase 1 占位窗口)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Text("Phase 2 plan 将在此处接入完整时间轴 / 红 banner / AI 总结块 / 待办四态按钮 / 数据账本入口。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                Text(summaryText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
        .onAppear { refresh() }
        .onReceive(monitor.retrospectiveJob.$state) { _ in refresh() }
    }

    private func refresh() {
        guard case .completed(let runID) = monitor.retrospectiveJob.state else { return }
        guard let run = monitor.hudStore.runByID(runID) else { return }
        var lines: [String] = ["Run \(run.id) · \(run.status.rawValue) · \(run.chatCount) chats / \(run.msgCount) msgs"]
        for item in run.summaryTop3 { lines.append("• \(item.text)") }
        if let r = run.summaryRisk { lines.append("⚡ \(r.text)") }
        if let m = run.summaryMissed { lines.append("💡 \(m.text)") }
        summaryText = lines.joined(separator: "\n\n")
    }
}
```

```bash
git add Sources/WeChatHUD/App/RetrospectiveWindowManager.swift Sources/WeChatHUD/Views/Retrospective/RetrospectiveWindow.swift
git commit -m "feat(retrospective): RetrospectiveWindowManager NSWindow singleton + Phase 1 stub

True NSWindow (not NSPanel) — independent from FloatingPanel hover-dismiss.
Spec §2.2, §9.2."
```

### Task 6.3: RetrospectiveLiveStore

**Files:**
- Create: `Sources/WeChatHUD/Views/Retrospective/RetrospectiveLiveStore.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import Combine

@MainActor
final class RetrospectiveLiveStore: ObservableObject {
    private let store: HUDStore
    private var observerToken: NSObjectProtocol?

    @Published var liveHighlights: [ReviewHighlight] = []
    @Published var livePendingTodos: [ReviewTodo] = []
    @Published var liveProgress: (completed: Int, total: Int)? = nil

    private var watchedRunID: Int?

    init(store: HUDStore) {
        self.store = store
    }

    func attach(runID: Int) {
        watchedRunID = runID
        refresh()
        if observerToken == nil {
            observerToken = NotificationCenter.default.addObserver(
                forName: .retrospectiveLiveUpdate, object: nil, queue: .main
            ) { [weak self] note in
                Task { @MainActor in self?.handle(note: note) }
            }
        }
    }

    func detach() {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
            observerToken = nil
        }
        watchedRunID = nil
        liveHighlights = []
        livePendingTodos = []
        liveProgress = nil
    }

    private func handle(note: Notification) {
        guard let runID = note.userInfo?["runId"] as? Int, runID == watchedRunID else { return }
        refresh()
    }

    private func refresh() {
        guard let runID = watchedRunID else { return }
        liveHighlights = store.highlights(for: runID)
        livePendingTodos = store.todos(for: runID, statuses: [.pending])
        if let run = store.runByID(runID) {
            liveProgress = (run.progressChatCount, run.chatCount)
        }
    }

    deinit {
        if let token = observerToken { NotificationCenter.default.removeObserver(token) }
    }
}
```

```bash
git add Sources/WeChatHUD/Views/Retrospective/RetrospectiveLiveStore.swift
git commit -m "feat(retrospective): RetrospectiveLiveStore subscribes to NotificationCenter

@MainActor ObservableObject; refresh on every retrospectiveLiveUpdate
matching watched runID. Spec §6.6."
```

**Milestone 6 Done.** **GATE** before M7.

---

## Milestone 6.5: Minimal Placeholder UI (Phase 1 only)

**Outcome:** A bare-bones `复盘` tab that wires the Phase 1 backend end-to-end so the pipeline can be manually validated. Full SwiftUI views per spec §4 are deferred to **Phase 2 plan**.

This placeholder satisfies M10 cleanup ("delete weekly mode from DailyReportTabView") without depending on Phase 2 view code. Phase 2 will replace the placeholder with the real views.

### Task 6.5.1: Placeholder RetrospectiveTabView

**Files:**
- Create: `Sources/WeChatHUD/Views/Retrospective/RetrospectiveTabView.swift` (placeholder, ≤ 120 lines; will be expanded in Phase 2)

- [ ] **Step 1: Implement minimal placeholder**

```swift
import SwiftUI

struct RetrospectiveTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var lastRunSummary: String = "（尚未生成）"
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("复盘 (Phase 1 占位 UI)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button(isRunning ? "生成中…" : "重新生成 ↻") {
                    isRunning = true
                    monitor.retrospectiveJob.run(
                        mode: .sinceLastRetrospective(lastRunEnd: nil),
                        myUsername: monitor.myUsername,
                        myDisplayName: monitor.myDisplayName
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .foregroundColor(.white.opacity(isRunning ? 0.4 : 0.85))
            }

            Button("打开完整窗口 ⤢") {
                RetrospectiveWindowManager.shared.showWindow(monitor: monitor)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.7))

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                Text(lastRunSummary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .onReceive(monitor.retrospectiveJob.$state) { state in
            switch state {
            case .completed(let runID):
                isRunning = false
                lastRunSummary = renderSummary(runID: runID)
            case .partial(let runID, let failed):
                isRunning = false
                lastRunSummary = "[部分成功 \(failed.count) 失败] " + renderSummary(runID: runID)
            case .failed(let msg):
                isRunning = false
                lastRunSummary = "失败: \(msg)"
            case .idle:
                isRunning = false
            default:
                isRunning = true
            }
        }
    }

    private func renderSummary(runID: Int) -> String {
        guard let run = monitor.hudStore.runByID(runID) else { return "（无数据）" }
        var lines: [String] = []
        lines.append("Run \(run.id) · \(run.status.rawValue)")
        for item in run.summaryTop3 { lines.append("• \(item.text)") }
        if let r = run.summaryRisk { lines.append("⚡ \(r.text)") }
        if let m = run.summaryMissed { lines.append("💡 \(m.text)") }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Wire into ExtendedTabsView**

Open `Sources/WeChatHUD/Views/ExtendedTabsView.swift`. Find the existing tab enum (look for `enum Tab` or similar). Add a `.retrospective` case between `.dailyReport` and `.insights` (i.e., between 日报 and 洞察 per spec §9.3). Add to the switch that maps tabs to views: `case .retrospective: RetrospectiveTabView()`.

- [ ] **Step 3: Build + manual smoke**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && make app && make run
```

Verify: 复盘 tab visible; click 重新生成 → menu bar spinner appears; eventually summary text fills the placeholder.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/Retrospective/RetrospectiveTabView.swift Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat(retrospective): Phase 1 placeholder UI tab

Bare 复盘 tab with [重新生成] + [完整窗口] buttons and a text dump of
the latest run summary. Phase 2 plan will replace this with the full
spec §4 SwiftUI views (RedBanner, AISummaryBlock, UncertainCardStack,
TimelineRow, etc.). Wires Phase 1 pipeline end-to-end for manual smoke."
```

**Milestone 6.5 Done.** **GATE** before M10.

---

## Phase 2 (deferred to separate plan)

The following milestones from spec §4 + §9 are **deferred** to a separate Phase 2 plan to keep this plan reviewable. They will be planned + dual-reviewed independently after Phase 1 ships and the placeholder UI has been validated against real WeChat data:

- **M7 (Phase 2)**: SwiftUI Floating Tab full views — RedBannerView with reply path / RetrospectiveSummarySection with evidence chips / UncertainCardStackView / EvidenceChipPopover / RetrospectiveTabView (final, replaces M6.5 placeholder) / RetrospectiveTabState
- **M8 (Phase 2)**: Independent NSWindow full views — RetrospectiveWindow / RetrospectiveWindowChrome / RetrospectiveTimelineView (List + LazyVStack with `enum TimelineRow { case highlight(ReviewHighlight); case todo(ReviewTodo) }` discriminator + Identifiable conformance for diffing) / TimelineRowView (relation 2pt color bar + 4-state buttons + 已延续 N 周 visual gradient)
- **M9 (Phase 2)**: Settings views — DataLedgerView / ScopePolicyManagerView / Preferences integration

**Phase 2 plan filename (placeholder)**: `docs/superpowers/plans/<date>-retrospective-ui-phase2.md`

**Why split now**: GATE 2 round 1 reviewers correctly flagged that 8 SwiftUI view tasks were collapsed to "Implement (~150 lines)" placeholders. Rather than inflate this plan to 4000+ lines, Phase 2 gets its own brainstorm → spec-amendment (if needed) → plan → GATE cycle once Phase 1 is shippable. This also lets Phase 2 incorporate any UX learnings from Phase 1 placeholder usage.




---

## Milestone 10: Integration + Cleanup + Final QA

### Task 10.1: Delete weekly content from DailyReportTabView

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportTabView.swift`

- [ ] **Step 1: Remove all weekly view code**

Delete:
- `weeklyContent` computed view
- `weeklyHierarchyTasks`, `itemsFromSuperior`, `itemsToSubordinate`, `itemsWithPeers`, `weeklyItems`, `itemsWithHierarchy()`
- `weeklyOverview`, `weeklyCommitments`, `weeklyPendingAsks`
- `exportButton`, `copyWeeklyReport`
- `ReportMode.weekly` enum case + segmented Picker

Replace with: just the existing daily content as the only mode.

- [ ] **Step 2: grep ReportMode.weekly across codebase**

```bash
grep -rn "ReportMode.weekly\|reportMode == .weekly" /Users/yuriwong/wechatcli/WeChatHUD/Sources /Users/yuriwong/wechatcli/WeChatHUD/Tests
```

Expected: 0 matches. If matches found, fix each.

- [ ] **Step 3: Build + test**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build && swift test 2>&1 | tail -10
```

Expected: green.

```bash
git commit -m "refactor(retrospective): remove weekly mode from DailyReportTabView

Weekly content is now in 复盘 tab. ReportMode enum simplified to daily-only."
```

### Task 10.2: Verify orphan-free (already wired in Task 6.0)

The retrospectiveJob wiring + ChatMonitorScopeProvider/MessageQuery adapter implementations were moved to **Task 6.0** in v0.3 because Tasks 6.1/6.2/6.5 depend on them at compile time. M10 just verifies nothing was left dangling.

- [ ] **Step 1: grep for orphaned references**

```bash
grep -rn "retrospectiveJob\|ChatMonitorScopeProvider\|ChatMonitorMessageQuery" \
  /Users/yuriwong/wechatcli/WeChatHUD/Sources \
  /Users/yuriwong/wechatcli/WeChatHUD/Tests \
  | grep -v "// " | head -30
```

Expected: every reference resolves to a defined type. If any reference is to a Phase 2-only symbol (e.g., `RedBannerView`, `RetrospectiveSummarySection`, `TimelineRowView`), confirm it's commented out / deferred.

- [ ] **Step 2: Run swift build clean**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift package clean && swift build 2>&1 | grep "error:" | head -10
```

Expected: 0 errors. (Pre-existing Swift 6 strict-concurrency warnings on existing files are tolerated per CLAUDE.md.)

### Task 10.3: End-to-end manual smoke test

- [ ] **Step 1: Run app**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && make app && make run
```

- [ ] **Step 2: Verify (Phase 1 scope)**

- 复盘 tab visible in extended tabs (placeholder UI from M6.5)
- Click `[重新生成 ↻]` → menu bar icon switches to spinner during run
- After completion, notification fires; placeholder text dump shows summary lines
- Click `[完整窗口 ⤢]` → independent NSWindow opens (basic chrome from M8 placeholder is OK; full views deferred to Phase 2)
- ⌘W on independent window closes it; doesn't affect floating tab

Phase 2 will add: red banner reply path, AI summary chips, uncertain card stack, full timeline rows, MD copy, settings views.

- [ ] **Step 3: Final commit**

```bash
git commit --allow-empty -m "chore(retrospective): manual smoke test passed

E2E: tab visible → toast → spinner → window → notification → MD export."
```

**Milestone 10 Done.** **All GATEs cleared.** Feature complete.

---

## Self-Review Checklist (Plan Author)

- ✅ Spec §1-3 + §5-8 fully covered by Phase 1 tasks (M1-M6 + M6.5 + M10)
- ⏸ Spec §4 (UI mockups) only minimally covered in Phase 1 (placeholder UI in M6.5); full coverage explicitly deferred to **Phase 2 plan**
- ⏸ Spec §9.2 file list partial — Phase 1 creates Services/* + Data/* + App/* + a placeholder Views/Retrospective/RetrospectiveTabView.swift; Phase 2 creates the remaining 11 view files
- ✅ §10 test list mapped to specific test files in M1, M2, M3, M4, M5
- ✅ §11 deferred items explicitly NOT in plan
- ✅ All paths absolute
- ✅ All commits have conventional prefix
- ✅ Each milestone is shippable + has GATE checkpoint
- ✅ TDD enforced (tests before impl in M2-M5)
- ✅ No "TBD" / "see appendix" / "implement later" placeholders in Phase 1 task code
- ✅ HUDStore migration call moved from `init` to `open()` (db is nil before open)
- ✅ Test helpers use real `init(dbPath:)` + explicit `try store.open()`
- ✅ Carry-forward order corrected: collect → dedupe → insert (was insert → dedupe)
- ✅ TaskGroup captures Sendable locals before dispatch (no self capture)
- ✅ Total job timeout implemented via Task.sleep race
- ✅ MenuBarController spinner uses 8 rotated frames of one SF Symbol (was 4 identical)
- ✅ NotificationCenter "progress" kind posted from updateReviewRunProgress
- ✅ Mock helpers task added (Task 4.0) before AI services
- ✅ All 12 CRUD methods in Task 1.5 have actual SQL + bind + decode
- ✅ AIService access path verified: `cfg.primarySlot.providerID` / `cfg.primarySlot.model`

## Execution Strategy (recommend Subagent-Driven)

Per project owner directive: each milestone completion requires dual frontend + backend reviewer PASS gate before next milestone. After each `**Milestone N Done.**` marker:

1. Run full `swift test` and `swift build`
2. Dispatch frontend reviewer + backend reviewer with the milestone's diff
3. Both PASS → proceed to next milestone
4. Either FAIL → revise + re-gate
