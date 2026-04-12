# WeChatHUD AI Co-Pilot 全面重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform WeChatHUD from a notification mirror into an AI-powered decision co-pilot with four-tier contact management (VIP/whitelist/greylist/stranger), eight AI analysis roles, smart context windowing, recall capture, commitment tracking, and a redesigned three-layer HUD (compact pill → notification → extended decision panel).

**Architecture:** Six phases, each independently shippable. Phase 1 (Data Foundation) adds the new DB schema, contact level/role model, and CRUD. Phase 2 (Algorithm Layer) builds conversation segmentation, feature extraction, and context window assembly. Phase 3 (AI Roles) implements the eight AI actors with versioned prompts. Phase 4 (ChatMonitor Redesign) rewires the scan loop for four-tier routing, VIP trace capture, recall detection, and commitment detection. Phase 5 (UI Redesign) rebuilds the compact pill, notification banner, and extended panel with new tabs. Phase 6 (Settings & Refresh) adds algorithm tuning UI and one-click rule refresh.

**Tech Stack:** Swift 5.9+, macOS 14+, SwiftUI + AppKit, SQLite3 C API, SPM resource bundles, OpenAI-compatible local LLM (omlx), FSEvents, Accessibility API

---

## Phase 1: Data Foundation

**Goal:** New DB schema + model types for four-tier contacts, VIP traces, recalled messages, commitments, and enhanced pending_asks. Everything else builds on this.

### Task 1.1: Contact Level & Role Model Types

**Files:**
- Modify: `Sources/WeChatHUD/Data/Models.swift`

- [ ] **Step 1: Write the failing test**

Create test file first:

```swift
// Tests/WeChatHUDTests/ContactLevelTests.swift
import XCTest
@testable import WeChatHUD

final class ContactLevelTests: XCTestCase {

    func testAttentionLevelOrdering() {
        let levels: [AttentionLevel] = [.stranger, .greylist, .whitelist, .vip]
        XCTAssertEqual(levels.sorted(by: { $0.rank < $1.rank }),
                       [.vip, .whitelist, .greylist, .stranger])
    }

    func testContactRoleDefaultReplyWindow() {
        XCTAssertEqual(ContactRole.boss.defaultReplyWindowMinutes, 30)
        XCTAssertEqual(ContactRole.keyClient.defaultReplyWindowMinutes, 60)
        XCTAssertEqual(ContactRole.colleague.defaultReplyWindowMinutes, 240)
        XCTAssertEqual(ContactRole.family.defaultReplyWindowMinutes, 120)
        XCTAssertEqual(ContactRole.supplier.defaultReplyWindowMinutes, 480)
        XCTAssertEqual(ContactRole.acquaintance.defaultReplyWindowMinutes, 0) // no tracking
    }

    func testContactRoleNotifyLevel() {
        XCTAssertEqual(ContactRole.boss.defaultNotifyLevel, .strong)
        XCTAssertEqual(ContactRole.colleague.defaultNotifyLevel, .standard)
        XCTAssertEqual(ContactRole.acquaintance.defaultNotifyLevel, .light)
    }

    func testContactRoleReplyTone() {
        XCTAssertEqual(ContactRole.boss.defaultReplyTone, .reporting)
        XCTAssertEqual(ContactRole.keyClient.defaultReplyTone, .professional)
        XCTAssertEqual(ContactRole.friend.defaultReplyTone, .casual)
    }

    func testContactRoleRoleDescription() {
        XCTAssertFalse(ContactRole.boss.roleDescription.isEmpty)
        for role in ContactRole.allCases {
            XCTAssertFalse(role.roleDescription.isEmpty, "\(role) missing description")
        }
    }

    func testContactRoleVIPTrackDimensions() {
        XCTAssertTrue(ContactRole.boss.vipTrackDimensions.contains("decisions"))
        XCTAssertTrue(ContactRole.keyClient.vipTrackDimensions.contains("complaints"))
        XCTAssertTrue(ContactRole.family.vipTrackDimensions.contains("health"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ContactLevelTests 2>&1 | tail -5`
Expected: FAIL — types not defined

- [ ] **Step 3: Implement AttentionLevel, ContactRole, NotifyLevel, ReplyTone**

Add to `Models.swift` after the existing `WhitelistAttentionLevel` section:

```swift
// MARK: - Four-Tier Contact System

/// Four attention levels, controlling how much AI resource a contact receives.
/// Replaces the binary watch/vip model. The old WhitelistAttentionLevel is
/// kept for backward compat; new code uses AttentionLevel.
enum AttentionLevel: String, Codable, CaseIterable {
    case vip        // Full tracking: private + all groups + sentiment
    case whitelist  // Private + @you only
    case greylist   // Rule-filtered private + @you only
    case stranger   // Ignored completely

    var rank: Int {
        switch self {
        case .vip: return 0
        case .whitelist: return 1
        case .greylist: return 2
        case .stranger: return 3
        }
    }

    var label: String {
        switch self {
        case .vip: return "VIP"
        case .whitelist: return "白名单"
        case .greylist: return "灰名单"
        case .stranger: return "陌生人"
        }
    }
}

/// Identity role within an attention level. Determines AI analysis perspective,
/// reply tone, urgency thresholds, and VIP tracking dimensions.
enum ContactRole: String, Codable, CaseIterable {
    // VIP-tier roles
    case boss        // 上级
    case keyClient   = "key_client"  // 核心大客户
    case family      // 家人
    case partner     // 重要合作方

    // Whitelist-tier roles
    case colleague   // 日常协作同事
    case client      // 一般客户
    case friend      // 朋友
    case supplier    // 供应商/服务商

    // Greylist-tier roles
    case acquaintance // 认识但不熟
    case groupOnly   = "group_only"  // 仅在群里见过
    case service     // 快递/外卖/物业

    var label: String {
        switch self {
        case .boss: return "上级"
        case .keyClient: return "核心客户"
        case .family: return "家人"
        case .partner: return "合作方"
        case .colleague: return "同事"
        case .client: return "客户"
        case .friend: return "朋友"
        case .supplier: return "供应商"
        case .acquaintance: return "认识"
        case .groupOnly: return "群友"
        case .service: return "服务"
        }
    }

    var icon: String {
        switch self {
        case .boss: return "👑"
        case .keyClient: return "💎"
        case .family: return "❤️"
        case .partner: return "🤝"
        case .colleague: return "👤"
        case .client: return "💼"
        case .friend: return "😊"
        case .supplier: return "📦"
        case .acquaintance: return "🔅"
        case .groupOnly: return "👥"
        case .service: return "🔧"
        }
    }

    var roleDescription: String {
        switch self {
        case .boss: return "直属或间接上级，反问句算ask，情绪需关注"
        case .keyClient: return "核心大客户，任何疑问句都算ask，不能不理"
        case .family: return "家人，涉及健康/安全/钱自动urgent"
        case .partner: return "重要合作方，关注态度变化和竞争信号"
        case .colleague: return "日常协作同事，只有明确请求才算ask"
        case .client: return "一般客户，疑问句算ask"
        case .friend: return "朋友，宽松判定"
        case .supplier: return "供应商/服务商，过滤节日问候和营销"
        case .acquaintance: return "弱联系，高置信才通知"
        case .groupOnly: return "仅群聊可见，极少处理"
        case .service: return "服务性联系，仅处理需确认的事务"
        }
    }

    var defaultReplyWindowMinutes: Int {
        switch self {
        case .boss: return 30
        case .keyClient: return 60
        case .family: return 120
        case .partner: return 120
        case .colleague: return 240
        case .client: return 120
        case .friend: return 240
        case .supplier: return 480
        case .acquaintance: return 0    // no tracking
        case .groupOnly: return 0
        case .service: return 0
        }
    }

    var defaultNotifyLevel: NotifyLevel {
        switch self {
        case .boss, .keyClient: return .strong
        case .family, .partner, .client: return .standard
        case .colleague, .friend, .supplier: return .standard
        case .acquaintance, .groupOnly, .service: return .light
        }
    }

    var defaultReplyTone: ReplyTone {
        switch self {
        case .boss: return .reporting
        case .keyClient, .client, .partner: return .professional
        case .colleague, .supplier: return .collaborative
        case .family, .friend: return .casual
        case .acquaintance, .groupOnly, .service: return .polite
        }
    }

    /// Dimensions the VIP Aggregator should focus on for this role.
    /// Only meaningful for VIP-tier contacts.
    var vipTrackDimensions: [String] {
        switch self {
        case .boss: return ["decisions", "mood", "dissatisfaction", "directives"]
        case .keyClient: return ["complaints", "needs", "competitor_mentions", "praise"]
        case .family: return ["health", "safety", "life_arrangements", "emotions"]
        case .partner: return ["project_progress", "attitude_shifts", "competitor_activity"]
        default: return []
        }
    }
}

enum NotifyLevel: String, Codable {
    case strong    // Persistent notification, doesn't auto-dismiss
    case standard  // 3-5s auto-dismiss
    case light     // Pill flash only, no banner
    case none      // Silent, only visible in extended panel
}

enum ReplyTone: String, Codable {
    case reporting      // 汇报式 (boss)
    case professional   // 专业服务式 (client)
    case collaborative  // 协作式 (colleague)
    case casual         // 随意亲切 (friend/family)
    case polite         // 礼貌简短 (acquaintance)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ContactLevelTests 2>&1 | tail -5`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Data/Models.swift Tests/WeChatHUDTests/ContactLevelTests.swift
git commit -m "feat: add four-tier AttentionLevel + ContactRole model types"
```

---

### Task 1.2: New DB Tables — contacts, vip_traces, recalled_messages, commitments

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift`
- Create: `Tests/WeChatHUDTests/NewSchemaTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WeChatHUDTests/NewSchemaTests.swift
import XCTest
@testable import WeChatHUD

final class NewSchemaTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_schema_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        super.tearDown()
    }

    // ── contacts table ──

    func testUpsertAndLoadContact() {
        try! store.upsertContact(
            username: "wxid_test1",
            displayName: "张三",
            attentionLevel: .vip,
            role: .boss,
            roleNote: "直属领导",
            replyWindowMinutes: 30
        )
        let contact = store.getContact(username: "wxid_test1")
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact!.attentionLevel, .vip)
        XCTAssertEqual(contact!.role, .boss)
        XCTAssertEqual(contact!.roleNote, "直属领导")
        XCTAssertEqual(contact!.replyWindowMinutes, 30)
    }

    func testLoadContactsByLevel() {
        try! store.upsertContact(username: "a", displayName: "A", attentionLevel: .vip, role: .boss)
        try! store.upsertContact(username: "b", displayName: "B", attentionLevel: .whitelist, role: .colleague)
        try! store.upsertContact(username: "c", displayName: "C", attentionLevel: .greylist, role: .acquaintance)

        let vips = store.loadContacts(level: .vip)
        XCTAssertEqual(vips.count, 1)
        XCTAssertEqual(vips[0].username, "a")

        let all = store.loadContacts(level: nil)
        XCTAssertEqual(all.count, 3)
    }

    func testUpdateContactLevel() {
        try! store.upsertContact(username: "x", displayName: "X", attentionLevel: .greylist, role: .acquaintance)
        try! store.updateContactLevel(username: "x", level: .whitelist, role: .colleague)
        let c = store.getContact(username: "x")!
        XCTAssertEqual(c.attentionLevel, .whitelist)
        XCTAssertEqual(c.role, .colleague)
    }

    // ── vip_traces table ──

    func testInsertAndLoadVIPTrace() {
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "group1", chatName: "产品群",
            msgUID: "msg001", rawText: "这个方案不行",
            msgTime: 1000
        )
        let traces = store.loadVIPTraces(vipUsername: "boss1", since: 0, limit: 10)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].rawText, "这个方案不行")
        XCTAssertEqual(traces[0].chatName, "产品群")
    }

    func testVIPTraceDedup() {
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "group1", chatName: "产品群",
            msgUID: "msg001", rawText: "text1", msgTime: 1000
        )
        // Same msg_uid — should not crash, should be ignored
        try? store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "group1", chatName: "产品群",
            msgUID: "msg001", rawText: "text2", msgTime: 1001
        )
        let traces = store.loadVIPTraces(vipUsername: "boss1", since: 0, limit: 10)
        XCTAssertEqual(traces.count, 1)
    }

    // ── recalled_messages table ──

    func testInsertAndLoadRecalledMessage() {
        try! store.insertRecalledMessage(
            msgUID: "recall001",
            senderUsername: "wxid_boss", senderName: "王总",
            senderLevel: .vip, senderRole: .boss,
            chatUsername: "group1", chatName: "产品群",
            chatType: .group,
            originalText: "人员调整方案先不要发出去",
            sentAt: 1000, recalledAt: 1012
        )
        let msgs = store.loadRecalledMessages(since: 0, limit: 10)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].originalText, "人员调整方案先不要发出去")
        XCTAssertEqual(msgs[0].recallDelaySeconds, 12)
    }

    // ── commitments table ──

    func testInsertAndLoadCommitment() {
        try! store.upsertCommitment(
            msgUID: "commit001",
            chatUsername: "chat1", chatName: "张三",
            content: "明天发报价单",
            commitTo: "张三",
            deadlineAt: Date(timeIntervalSince1970: 2000),
            confidence: 0.9,
            promptVersion: "commitment_v1"
        )
        let items = store.loadCommitments(status: .pending)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content, "明天发报价单")
    }

    func testUpdateCommitmentStatus() {
        try! store.upsertCommitment(
            msgUID: "commit002",
            chatUsername: "chat1", chatName: "张三",
            content: "帮你看文件",
            commitTo: "张三",
            deadlineAt: nil,
            confidence: 0.85,
            promptVersion: "commitment_v1"
        )
        try! store.updateCommitmentStatus(msgUID: "commit002", status: .fulfilled)
        let items = store.loadCommitments(status: .fulfilled)
        XCTAssertEqual(items.count, 1)
    }

    // ── pending_asks enhancement ──

    func testPendingAskWithSenderLevel() {
        try! store.upsertPendingAsk(PendingAsk(
            id: 0,
            msgUID: "ask001",
            chatUsername: "chat1", chatName: "产品群",
            senderName: "王总",
            rawText: "方案定了没",
            summary: "确认Q3方案",
            askType: .review,
            deadlineAt: nil,
            confidence: 0.95,
            bucket: .main,
            status: .pending,
            promptVersion: "classifier_v3",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: .vip,
            senderRole: .boss,
            urgency: .urgent
        ))
        let items = store.loadPendingAsks(bucket: .main, status: .pending)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].senderLevel, .vip)
        XCTAssertEqual(items[0].senderRole, .boss)
        XCTAssertEqual(items[0].urgency, .urgent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter NewSchemaTests 2>&1 | tail -5`
Expected: FAIL — methods and types not defined

- [ ] **Step 3: Add new model types to Models.swift**

Add after the existing `PendingAsk` struct:

```swift
// MARK: - Enhanced Contact (four-tier system)

struct ContactEntry: Identifiable {
    let id: String  // username
    let username: String
    let displayName: String
    let attentionLevel: AttentionLevel
    let role: ContactRole
    let roleNote: String
    let replyWindowMinutes: Int
    let levelChangedAt: Date?
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - VIP Trace

struct VIPTrace: Identifiable {
    let id: Int64
    let vipUsername: String
    let vipName: String
    let chatUsername: String
    let chatName: String
    let msgUID: String
    let rawText: String
    let msgTime: Int
    let batchID: String?
    let createdAt: Date
}

// MARK: - Recalled Message

enum ChatType: String, Codable {
    case privateChat = "private"
    case group
}

struct RecalledMessage: Identifiable {
    let id: Int64
    let msgUID: String
    let senderUsername: String
    let senderName: String
    let senderLevel: AttentionLevel
    let senderRole: ContactRole
    let chatUsername: String
    let chatName: String
    let chatType: ChatType
    let originalText: String
    let sentAt: Int
    let recalledAt: Int
    let recallDelaySeconds: Int
    // AI analysis (filled async)
    let aiReason: String?
    let aiIntelligenceValue: String?
    let aiDetail: String?
    let aiShouldNotify: Bool?
    let aiNotifyLevel: NotifyLevel?
    let aiAnalyzedAt: Date?
    let createdAt: Date
}

// MARK: - Commitment (your promises)

enum CommitmentStatus: String, Codable {
    case pending
    case fulfilled
    case overdue
    case cancelled
}

struct Commitment: Identifiable {
    let id: Int64
    let msgUID: String
    let chatUsername: String
    let chatName: String
    let content: String
    let commitTo: String
    let deadlineAt: Date?
    let confidence: Double
    let status: CommitmentStatus
    let promptVersion: String
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Urgency (used by enhanced Classifier)

enum AskUrgency: String, Codable {
    case routine    // 不急，随时回
    case timely     // 有时间预期，今天内
    case urgent     // 措辞紧急或 boss 催促
}
```

Also add `senderLevel`, `senderRole`, `urgency` fields to `PendingAsk`:

```swift
// Modify PendingAsk to add new fields at the end:
struct PendingAsk: Identifiable {
    let id: Int64
    let msgUID: String
    let chatUsername: String
    let chatName: String
    let senderName: String
    let rawText: String
    let summary: String
    let askType: AskType
    let deadlineAt: Date?
    let confidence: Double
    let bucket: AskBucket
    let status: AskStatus
    let promptVersion: String
    let createdAt: Date
    let updatedAt: Date
    // New fields for four-tier system
    let senderLevel: AttentionLevel?
    let senderRole: ContactRole?
    let urgency: AskUrgency?
}
```

Add new `AskType` cases:

```swift
enum AskType: String, Codable {
    case yesNo    = "yes_no"
    case sendFile = "send_file"
    case review
    case decide
    case info
    case schedule  // new: 需要确认时间/安排
    case action    // new: 需要做具体行动
    case none
    // ... labels ...
}
```

Expand `AIRole` to cover all 8 roles:

```swift
enum AIRole: String, Codable {
    case classifier
    case commitmentTracker = "commitment_tracker"
    case contextAnalyzer   = "context_analyzer"
    case replyGenerator    = "reply_generator"
    case vipAggregator     = "vip_aggregator"
    case groupDigestor     = "group_digestor"
    case retrospector
    case recallAnalyzer    = "recall_analyzer"
    case ranker  // kept for backward compat
}
```

- [ ] **Step 4: Add new tables and CRUD to HUDStore.swift**

Add inside `createTables()`:

```swift
// contacts: four-tier contact registry with role identity
try exec("""
    CREATE TABLE IF NOT EXISTS contacts (
        username            TEXT PRIMARY KEY,
        display_name        TEXT NOT NULL,
        attention_level     TEXT NOT NULL DEFAULT 'stranger',
        role                TEXT NOT NULL DEFAULT '',
        role_note           TEXT NOT NULL DEFAULT '',
        reply_window_minutes INTEGER NOT NULL DEFAULT 120,
        level_changed_at    INTEGER,
        created_at          INTEGER NOT NULL,
        updated_at          INTEGER NOT NULL
    )
""")
try exec("CREATE INDEX IF NOT EXISTS idx_contacts_level ON contacts(attention_level)")

// vip_traces: VIP messages captured from ALL groups
try exec("""
    CREATE TABLE IF NOT EXISTS vip_traces (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        vip_username    TEXT NOT NULL,
        vip_name        TEXT NOT NULL,
        chat_username   TEXT NOT NULL,
        chat_name       TEXT NOT NULL,
        msg_uid         TEXT UNIQUE NOT NULL,
        raw_text        TEXT NOT NULL,
        msg_time        INTEGER NOT NULL,
        batch_id        TEXT,
        created_at      INTEGER NOT NULL
    )
""")
try exec("CREATE INDEX IF NOT EXISTS idx_vip_traces_vip ON vip_traces(vip_username, msg_time)")
try exec("CREATE INDEX IF NOT EXISTS idx_vip_traces_batch ON vip_traces(batch_id)")

// recalled_messages: captured before WeChat erases them (independent storage)
try exec("""
    CREATE TABLE IF NOT EXISTS recalled_messages (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        msg_uid               TEXT UNIQUE NOT NULL,
        sender_username       TEXT NOT NULL,
        sender_name           TEXT NOT NULL,
        sender_level          TEXT NOT NULL,
        sender_role           TEXT NOT NULL,
        chat_username         TEXT NOT NULL,
        chat_name             TEXT NOT NULL,
        chat_type             TEXT NOT NULL,
        original_text         TEXT NOT NULL,
        sent_at               INTEGER NOT NULL,
        recalled_at           INTEGER NOT NULL,
        recall_delay_seconds  INTEGER NOT NULL,
        ai_reason             TEXT,
        ai_intelligence_value TEXT,
        ai_detail             TEXT,
        ai_should_notify      INTEGER,
        ai_notify_level       TEXT,
        ai_analyzed_at        INTEGER,
        created_at            INTEGER NOT NULL
    )
""")
try exec("CREATE INDEX IF NOT EXISTS idx_recalled_sender ON recalled_messages(sender_username, recalled_at)")
try exec("CREATE INDEX IF NOT EXISTS idx_recalled_time ON recalled_messages(recalled_at)")

// commitments: promises YOU made to others
try exec("""
    CREATE TABLE IF NOT EXISTS commitments (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        msg_uid         TEXT UNIQUE NOT NULL,
        chat_username   TEXT NOT NULL,
        chat_name       TEXT NOT NULL,
        content         TEXT NOT NULL,
        commit_to       TEXT NOT NULL,
        deadline_at     INTEGER,
        confidence      REAL NOT NULL,
        status          TEXT NOT NULL DEFAULT 'pending',
        prompt_version  TEXT NOT NULL,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
    )
""")
try exec("CREATE INDEX IF NOT EXISTS idx_commitments_status ON commitments(status, deadline_at)")
```

Add migration for pending_asks new columns (after existing table creation):

```swift
// Migration: add sender_level, sender_role, urgency to pending_asks
_ = try? exec("ALTER TABLE pending_asks ADD COLUMN sender_level TEXT")
_ = try? exec("ALTER TABLE pending_asks ADD COLUMN sender_role TEXT")
_ = try? exec("ALTER TABLE pending_asks ADD COLUMN urgency TEXT")
```

Add CRUD methods after the existing pending_asks section:

```swift
// MARK: - Contacts (four-tier)

func upsertContact(
    username: String,
    displayName: String,
    attentionLevel: AttentionLevel,
    role: ContactRole,
    roleNote: String = "",
    replyWindowMinutes: Int? = nil
) throws {
    let now = Int(Date().timeIntervalSince1970)
    let window = replyWindowMinutes ?? role.defaultReplyWindowMinutes
    try exec("""
        INSERT INTO contacts(username, display_name, attention_level, role, role_note,
                             reply_window_minutes, level_changed_at, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(username) DO UPDATE SET
            display_name = excluded.display_name,
            attention_level = excluded.attention_level,
            role = excluded.role,
            role_note = excluded.role_note,
            reply_window_minutes = excluded.reply_window_minutes,
            level_changed_at = excluded.level_changed_at,
            updated_at = excluded.updated_at
    """, params: [username, displayName, attentionLevel.rawValue, role.rawValue,
                  roleNote, "\(window)", "\(now)", "\(now)", "\(now)"])
}

func getContact(username: String) -> ContactEntry? {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT username, display_name, attention_level, role, role_note,
               reply_window_minutes, level_changed_at, created_at, updated_at
        FROM contacts WHERE username=? LIMIT 1
    """, -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return readContactRow(stmt)
}

func loadContacts(level: AttentionLevel?) -> [ContactEntry] {
    var results: [ContactEntry] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql: String
    if let level = level {
        sql = "SELECT username, display_name, attention_level, role, role_note, reply_window_minutes, level_changed_at, created_at, updated_at FROM contacts WHERE attention_level=? ORDER BY role, display_name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, level.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
        sql = "SELECT username, display_name, attention_level, role, role_note, reply_window_minutes, level_changed_at, created_at, updated_at FROM contacts ORDER BY attention_level, role, display_name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    }
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(readContactRow(stmt))
    }
    return results
}

func updateContactLevel(username: String, level: AttentionLevel, role: ContactRole) throws {
    let now = Int(Date().timeIntervalSince1970)
    try exec("""
        UPDATE contacts SET attention_level=?, role=?, reply_window_minutes=?,
               level_changed_at=?, updated_at=?
        WHERE username=?
    """, params: [level.rawValue, role.rawValue, "\(role.defaultReplyWindowMinutes)",
                  "\(now)", "\(now)", username])
}

func loadVIPUsernames() -> Set<String> {
    var result = Set<String>()
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT username FROM contacts WHERE attention_level='vip'", -1, &stmt, nil) == SQLITE_OK else { return result }
    while sqlite3_step(stmt) == SQLITE_ROW {
        result.insert(String(cString: sqlite3_column_text(stmt, 0)))
    }
    return result
}

private func readContactRow(_ stmt: OpaquePointer?) -> ContactEntry {
    ContactEntry(
        id: String(cString: sqlite3_column_text(stmt, 0)),
        username: String(cString: sqlite3_column_text(stmt, 0)),
        displayName: String(cString: sqlite3_column_text(stmt, 1)),
        attentionLevel: AttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .stranger,
        role: ContactRole(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .acquaintance,
        roleNote: String(cString: sqlite3_column_text(stmt, 4)),
        replyWindowMinutes: Int(sqlite3_column_int(stmt, 5)),
        levelChangedAt: sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6))) : nil,
        createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7))),
        updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)))
    )
}

// MARK: - VIP Traces

func insertVIPTrace(
    vipUsername: String, vipName: String,
    chatUsername: String, chatName: String,
    msgUID: String, rawText: String,
    msgTime: Int
) throws {
    let now = Int(Date().timeIntervalSince1970)
    try exec("""
        INSERT OR IGNORE INTO vip_traces(
            vip_username, vip_name, chat_username, chat_name,
            msg_uid, raw_text, msg_time, created_at
        ) VALUES(?,?,?,?,?,?,?,?)
    """, params: [vipUsername, vipName, chatUsername, chatName,
                  msgUID, rawText, "\(msgTime)", "\(now)"])
}

func loadVIPTraces(vipUsername: String, since: Int, limit: Int = 100) -> [VIPTrace] {
    var results: [VIPTrace] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT id, vip_username, vip_name, chat_username, chat_name,
               msg_uid, raw_text, msg_time, batch_id, created_at
        FROM vip_traces
        WHERE vip_username=? AND msg_time>?
        ORDER BY msg_time DESC
        LIMIT ?
    """, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_text(stmt, 1, vipUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int64(stmt, 2, Int64(since))
    sqlite3_bind_int64(stmt, 3, Int64(limit))
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(VIPTrace(
            id: sqlite3_column_int64(stmt, 0),
            vipUsername: String(cString: sqlite3_column_text(stmt, 1)),
            vipName: String(cString: sqlite3_column_text(stmt, 2)),
            chatUsername: String(cString: sqlite3_column_text(stmt, 3)),
            chatName: String(cString: sqlite3_column_text(stmt, 4)),
            msgUID: String(cString: sqlite3_column_text(stmt, 5)),
            rawText: String(cString: sqlite3_column_text(stmt, 6)),
            msgTime: Int(sqlite3_column_int64(stmt, 7)),
            batchID: sqlite3_column_type(stmt, 8) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 8)) : nil,
            createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9)))
        ))
    }
    return results
}

func loadUnbatchedVIPTraces(vipUsername: String, limit: Int = 100) -> [VIPTrace] {
    var results: [VIPTrace] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT id, vip_username, vip_name, chat_username, chat_name,
               msg_uid, raw_text, msg_time, batch_id, created_at
        FROM vip_traces
        WHERE vip_username=? AND batch_id IS NULL
        ORDER BY msg_time ASC
        LIMIT ?
    """, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_text(stmt, 1, vipUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int64(stmt, 2, Int64(limit))
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(VIPTrace(
            id: sqlite3_column_int64(stmt, 0),
            vipUsername: String(cString: sqlite3_column_text(stmt, 1)),
            vipName: String(cString: sqlite3_column_text(stmt, 2)),
            chatUsername: String(cString: sqlite3_column_text(stmt, 3)),
            chatName: String(cString: sqlite3_column_text(stmt, 4)),
            msgUID: String(cString: sqlite3_column_text(stmt, 5)),
            rawText: String(cString: sqlite3_column_text(stmt, 6)),
            msgTime: Int(sqlite3_column_int64(stmt, 7)),
            batchID: sqlite3_column_type(stmt, 8) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 8)) : nil,
            createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9)))
        ))
    }
    return results
}

func markVIPTracesBatched(ids: [Int64], batchID: String) throws {
    guard !ids.isEmpty else { return }
    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
    let sql = "UPDATE vip_traces SET batch_id=? WHERE id IN (\(placeholders))"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    sqlite3_bind_text(stmt, 1, batchID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    for (i, id) in ids.enumerated() {
        sqlite3_bind_int64(stmt, Int32(i + 2), id)
    }
    sqlite3_step(stmt)
}

// MARK: - Recalled Messages

func insertRecalledMessage(
    msgUID: String,
    senderUsername: String, senderName: String,
    senderLevel: AttentionLevel, senderRole: ContactRole,
    chatUsername: String, chatName: String,
    chatType: ChatType,
    originalText: String,
    sentAt: Int, recalledAt: Int
) throws {
    let now = Int(Date().timeIntervalSince1970)
    let delay = recalledAt - sentAt
    try exec("""
        INSERT OR IGNORE INTO recalled_messages(
            msg_uid, sender_username, sender_name, sender_level, sender_role,
            chat_username, chat_name, chat_type, original_text,
            sent_at, recalled_at, recall_delay_seconds, created_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
    """, params: [msgUID, senderUsername, senderName,
                  senderLevel.rawValue, senderRole.rawValue,
                  chatUsername, chatName, chatType.rawValue,
                  originalText, "\(sentAt)", "\(recalledAt)", "\(delay)", "\(now)"])
}

func loadRecalledMessages(since: Int, limit: Int = 50) -> [RecalledMessage] {
    var results: [RecalledMessage] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT id, msg_uid, sender_username, sender_name, sender_level, sender_role,
               chat_username, chat_name, chat_type, original_text,
               sent_at, recalled_at, recall_delay_seconds,
               ai_reason, ai_intelligence_value, ai_detail,
               ai_should_notify, ai_notify_level, ai_analyzed_at, created_at
        FROM recalled_messages WHERE recalled_at >= ? ORDER BY recalled_at DESC LIMIT ?
    """, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int64(stmt, 1, Int64(since))
    sqlite3_bind_int64(stmt, 2, Int64(limit))
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(readRecalledRow(stmt))
    }
    return results
}

func updateRecallAnalysis(
    msgUID: String, reason: String, value: String,
    detail: String?, shouldNotify: Bool, notifyLevel: NotifyLevel?
) throws {
    let now = Int(Date().timeIntervalSince1970)
    try exec("""
        UPDATE recalled_messages SET
            ai_reason=?, ai_intelligence_value=?, ai_detail=?,
            ai_should_notify=?, ai_notify_level=?, ai_analyzed_at=?
        WHERE msg_uid=?
    """, params: [reason, value, detail ?? "",
                  shouldNotify ? "1" : "0", notifyLevel?.rawValue ?? "",
                  "\(now)", msgUID])
}

private func readRecalledRow(_ stmt: OpaquePointer?) -> RecalledMessage {
    RecalledMessage(
        id: sqlite3_column_int64(stmt, 0),
        msgUID: String(cString: sqlite3_column_text(stmt, 1)),
        senderUsername: String(cString: sqlite3_column_text(stmt, 2)),
        senderName: String(cString: sqlite3_column_text(stmt, 3)),
        senderLevel: AttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .stranger,
        senderRole: ContactRole(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .acquaintance,
        chatUsername: String(cString: sqlite3_column_text(stmt, 6)),
        chatName: String(cString: sqlite3_column_text(stmt, 7)),
        chatType: ChatType(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .privateChat,
        originalText: String(cString: sqlite3_column_text(stmt, 9)),
        sentAt: Int(sqlite3_column_int64(stmt, 10)),
        recalledAt: Int(sqlite3_column_int64(stmt, 11)),
        recallDelaySeconds: Int(sqlite3_column_int64(stmt, 12)),
        aiReason: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 13)) : nil,
        aiIntelligenceValue: sqlite3_column_type(stmt, 14) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 14)) : nil,
        aiDetail: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 15)) : nil,
        aiShouldNotify: sqlite3_column_type(stmt, 16) != SQLITE_NULL ? sqlite3_column_int(stmt, 16) != 0 : nil,
        aiNotifyLevel: sqlite3_column_type(stmt, 17) != SQLITE_NULL ? NotifyLevel(rawValue: String(cString: sqlite3_column_text(stmt, 17))) : nil,
        aiAnalyzedAt: sqlite3_column_type(stmt, 18) != SQLITE_NULL ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 18))) : nil,
        createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 19)))
    )
}

// MARK: - Commitments

func upsertCommitment(
    msgUID: String,
    chatUsername: String, chatName: String,
    content: String, commitTo: String,
    deadlineAt: Date?, confidence: Double,
    promptVersion: String
) throws {
    let now = Int(Date().timeIntervalSince1970)
    let deadline = deadlineAt.map { Int($0.timeIntervalSince1970) }
    try exec("""
        INSERT INTO commitments(
            msg_uid, chat_username, chat_name, content, commit_to,
            deadline_at, confidence, status, prompt_version, created_at, updated_at
        ) VALUES(?,?,?,?,?,?,?,'pending',?,?,?)
        ON CONFLICT(msg_uid) DO UPDATE SET
            content = excluded.content,
            deadline_at = excluded.deadline_at,
            updated_at = excluded.updated_at
    """, params: [msgUID, chatUsername, chatName, content, commitTo,
                  deadline.map { "\($0)" } ?? "", "\(confidence)",
                  promptVersion, "\(now)", "\(now)"])
}

func loadCommitments(status: CommitmentStatus) -> [Commitment] {
    var results: [Commitment] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT id, msg_uid, chat_username, chat_name, content, commit_to,
               deadline_at, confidence, status, prompt_version, created_at, updated_at
        FROM commitments WHERE status=?
        ORDER BY COALESCE(deadline_at, 9999999999) ASC
    """, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_text(stmt, 1, status.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(readCommitmentRow(stmt))
    }
    return results
}

func updateCommitmentStatus(msgUID: String, status: CommitmentStatus) throws {
    let now = Int(Date().timeIntervalSince1970)
    try exec("UPDATE commitments SET status=?, updated_at=? WHERE msg_uid=?",
             params: [status.rawValue, "\(now)", msgUID])
}

private func readCommitmentRow(_ stmt: OpaquePointer?) -> Commitment {
    Commitment(
        id: sqlite3_column_int64(stmt, 0),
        msgUID: String(cString: sqlite3_column_text(stmt, 1)),
        chatUsername: String(cString: sqlite3_column_text(stmt, 2)),
        chatName: String(cString: sqlite3_column_text(stmt, 3)),
        content: String(cString: sqlite3_column_text(stmt, 4)),
        commitTo: String(cString: sqlite3_column_text(stmt, 5)),
        deadlineAt: sqlite3_column_type(stmt, 6) != SQLITE_NULL && sqlite3_column_int64(stmt, 6) > 0
            ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6))) : nil,
        confidence: sqlite3_column_double(stmt, 7),
        status: CommitmentStatus(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .pending,
        promptVersion: String(cString: sqlite3_column_text(stmt, 9)),
        createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10))),
        updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11)))
    )
}
```

- [ ] **Step 5: Update existing upsertPendingAsk to handle new fields**

Modify the existing `upsertPendingAsk` method to include `sender_level`, `sender_role`, `urgency` columns in the INSERT and the read-back query `loadPendingAsks`. The new columns are nullable so old rows work without migration.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter NewSchemaTests 2>&1 | tail -10`
Expected: All 9 tests PASS

- [ ] **Step 7: Run full test suite to check no regressions**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test 2>&1 | tail -5`
Expected: All existing tests still pass

- [ ] **Step 8: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Data/Models.swift Sources/WeChatHUD/Data/HUDStore.swift Tests/WeChatHUDTests/NewSchemaTests.swift
git commit -m "feat: add contacts/vip_traces/recalled_messages/commitments tables + CRUD"
```

---

### Task 1.3: Seed Default Role Configs in Settings

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift`

- [ ] **Step 1: Write the failing test**

Add to `NewSchemaTests.swift`:

```swift
func testSeedRoleConfigs() {
    // seedAISettingsIfMissing is called in open(), which ran in setUp
    let json = store.getSetting("role_configs")
    XCTAssertNotNil(json, "role_configs should be seeded on open()")

    let configs = store.getSettingJSON("role_configs", as: [String: RoleConfig].self)
    XCTAssertNotNil(configs)
    XCTAssertNotNil(configs?["boss"])
    XCTAssertEqual(configs?["boss"]?.replyWindow, 30)
    XCTAssertEqual(configs?["key_client"]?.replyWindow, 60)
}
```

- [ ] **Step 2: Run test — fails because RoleConfig doesn't exist**

- [ ] **Step 3: Add RoleConfig model and seed logic**

In `Models.swift`:

```swift
/// Per-role default configuration, stored as JSON in settings["role_configs"].
/// Users can override per-role defaults here; per-contact overrides live in
/// the contacts table's reply_window_minutes field.
struct RoleConfig: Codable {
    var replyWindow: Int
    var notifyLevel: String
    var classifierStrictness: String  // "normal" or "high"
    var replyTone: String
    var vipTrackDimensions: [String]
}
```

In `HUDStore.seedAISettingsIfMissing()`, add:

```swift
if getSetting("role_configs") == nil {
    let configs: [String: RoleConfig] = [
        "boss": RoleConfig(replyWindow: 30, notifyLevel: "strong", classifierStrictness: "high", replyTone: "reporting", vipTrackDimensions: ["decisions", "mood", "dissatisfaction", "directives"]),
        "key_client": RoleConfig(replyWindow: 60, notifyLevel: "strong", classifierStrictness: "high", replyTone: "professional", vipTrackDimensions: ["complaints", "needs", "competitor_mentions", "praise"]),
        "family": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "casual", vipTrackDimensions: ["health", "safety", "life_arrangements", "emotions"]),
        "partner": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "professional", vipTrackDimensions: ["project_progress", "attitude_shifts", "competitor_activity"]),
        "colleague": RoleConfig(replyWindow: 240, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "collaborative", vipTrackDimensions: []),
        "client": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "high", replyTone: "professional", vipTrackDimensions: []),
        "friend": RoleConfig(replyWindow: 240, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "casual", vipTrackDimensions: []),
        "supplier": RoleConfig(replyWindow: 480, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "collaborative", vipTrackDimensions: []),
        "acquaintance": RoleConfig(replyWindow: 0, notifyLevel: "light", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
        "group_only": RoleConfig(replyWindow: 0, notifyLevel: "light", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
        "service": RoleConfig(replyWindow: 0, notifyLevel: "none", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
    ]
    try? setSettingJSON("role_configs", value: configs)
}
```

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Data/Models.swift Sources/WeChatHUD/Data/HUDStore.swift Tests/WeChatHUDTests/NewSchemaTests.swift
git commit -m "feat: seed role_configs defaults in settings"
```

---

### Task 1.4: Whitelist ↔ Contacts Migration Bridge

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift`

The existing `whitelist` table has `attention_level` (watch/vip). The new `contacts` table has `attention_level` (vip/whitelist/greylist/stranger) + `role`. We need a migration that copies whitelist entries into contacts without losing data.

- [ ] **Step 1: Write the failing test**

```swift
func testWhitelistMigrationToContacts() {
    // Add some whitelist entries the old way
    try! store.addToWhitelist(username: "boss1", displayName: "王总", isGroup: false,
                              category: .work, attentionLevel: .vip)
    try! store.addToWhitelist(username: "coworker1", displayName: "李四", isGroup: false,
                              category: .work, attentionLevel: .watch)

    // Run migration
    store.migrateWhitelistToContacts()

    // Check contacts table
    let boss = store.getContact(username: "boss1")
    XCTAssertNotNil(boss)
    XCTAssertEqual(boss?.attentionLevel, .vip)
    // Role should be .colleague by default (auto-migration can't guess boss)
    // User will manually set roles after migration

    let coworker = store.getContact(username: "coworker1")
    XCTAssertNotNil(coworker)
    XCTAssertEqual(coworker?.attentionLevel, .whitelist)
}
```

- [ ] **Step 2: Implement migration**

```swift
/// One-time migration: copy whitelist entries into the new contacts table.
/// Maps old watch → whitelist, old vip → vip. Role defaults to .colleague
/// for work, .friend for life, .acquaintance for other. Users refine roles
/// manually or via AI Categorizer suggestions.
func migrateWhitelistToContacts() {
    let entries = getWhitelist()
    for entry in entries {
        let newLevel: AttentionLevel = entry.attentionLevel == .vip ? .vip : .whitelist
        let defaultRole: ContactRole
        switch entry.category {
        case .work: defaultRole = .colleague
        case .life: defaultRole = .friend
        case .other: defaultRole = .acquaintance
        }
        // Only insert if not already in contacts (idempotent)
        if getContact(username: entry.id) == nil {
            try? upsertContact(
                username: entry.id,
                displayName: entry.displayName,
                attentionLevel: newLevel,
                role: defaultRole
            )
        }
    }
}
```

Call `migrateWhitelistToContacts()` at the end of `open()`, after `seedAISettingsIfMissing()`.

- [ ] **Step 3: Run test — passes**

- [ ] **Step 4: Run full suite**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Data/HUDStore.swift Tests/WeChatHUDTests/NewSchemaTests.swift
git commit -m "feat: whitelist → contacts migration bridge"
```

---

## Phase 2: Algorithm Layer

**Goal:** Conversation segmentation, message feature extraction, context window builder. These are the preprocessing algorithms that feed all AI roles.

### Task 2.1: Conversation Segmenter

**Files:**
- Create: `Sources/WeChatHUD/Services/ConversationSegmenter.swift`
- Create: `Tests/WeChatHUDTests/ConversationSegmenterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WeChatHUDTests/ConversationSegmenterTests.swift
import XCTest
@testable import WeChatHUD

final class ConversationSegmenterTests: XCTestCase {

    func testPrivateChatSplitByTimeGap() {
        let msgs = [
            makeMsg(time: 1000, sender: "A", text: "你好"),
            makeMsg(time: 1060, sender: "B", text: "你好"),
            makeMsg(time: 1120, sender: "A", text: "方案发你了"),
            // 3-hour gap
            makeMsg(time: 11920, sender: "B", text: "看完了"),
            makeMsg(time: 11980, sender: "B", text: "有几个问题"),
        ]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].messages.count, 3)
        XCTAssertEqual(segments[1].messages.count, 2)
    }

    func testGroupChatSplitByDensityDrop() {
        var msgs: [MessageInfo] = []
        // Dense burst: 20 messages in 10 minutes
        for i in 0..<20 {
            msgs.append(makeMsg(time: 1000 + i * 30, sender: "User\(i % 4)", text: "msg\(i)"))
        }
        // Sparse gap: 3 messages in 15 minutes
        msgs.append(makeMsg(time: 2200, sender: "X", text: "sparse1"))
        msgs.append(makeMsg(time: 2600, sender: "X", text: "sparse2"))
        msgs.append(makeMsg(time: 3100, sender: "X", text: "sparse3"))
        // New dense burst with different people
        for i in 0..<10 {
            msgs.append(makeMsg(time: 3200 + i * 30, sender: "New\(i % 3)", text: "new\(i)"))
        }

        let segments = ConversationSegmenter.segment(msgs, chatType: .group)
        XCTAssertGreaterThanOrEqual(segments.count, 2, "Should detect at least 2 topic segments")
    }

    func testSingleMessageBecomesOneSegment() {
        let msgs = [makeMsg(time: 1000, sender: "A", text: "hello")]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].messages.count, 1)
    }

    func testEmptyInputReturnsEmpty() {
        let segments = ConversationSegmenter.segment([], chatType: .privateChat)
        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentProperties() {
        let msgs = [
            makeMsg(time: 1000, sender: "A", text: "hello"),
            makeMsg(time: 1010, sender: "B", text: "hi"),
            makeMsg(time: 1020, sender: "A", text: "how are you"),
        ]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments[0].startTime, 1000)
        XCTAssertEqual(segments[0].endTime, 1020)
        XCTAssertEqual(segments[0].participants, Set(["A", "B"]))
    }

    // MARK: - Helpers

    private func makeMsg(time: Int, sender: String, text: String) -> MessageInfo {
        MessageInfo(
            id: UUID().uuidString,
            chatUsername: "test_chat",
            chatName: "Test",
            senderUsername: sender,
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: time
        )
    }
}
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement ConversationSegmenter**

```swift
// Sources/WeChatHUD/Services/ConversationSegmenter.swift
import Foundation

struct ConversationSegment {
    let startTime: Int
    let endTime: Int
    let messages: [MessageInfo]
    let participants: Set<String>

    var messageCount: Int { messages.count }
    var durationSeconds: Int { max(endTime - startTime, 1) }
    var density: Double { Double(messageCount) / max(Double(durationSeconds) / 60.0, 1.0) }
}

enum ConversationSegmenter {

    /// Default gap threshold for private chats: 2 hours.
    static let privateGapThreshold: Int = 7200

    /// Default gap threshold for group chats: 30 minutes.
    /// Groups also use density-based splitting as a secondary heuristic.
    static let groupGapThreshold: Int = 1800

    /// Split a message list into conversation segments.
    /// Messages MUST be sorted by createTime ascending.
    static func segment(_ messages: [MessageInfo], chatType: ChatType) -> [ConversationSegment] {
        guard !messages.isEmpty else { return [] }

        let gapThreshold = chatType == .privateChat ? privateGapThreshold : groupGapThreshold
        var segments: [ConversationSegment] = []
        var currentBatch: [MessageInfo] = [messages[0]]

        for i in 1..<messages.count {
            let gap = messages[i].createTime - messages[i - 1].createTime
            let shouldSplit: Bool

            if gap >= gapThreshold {
                shouldSplit = true
            } else if chatType == .group && currentBatch.count >= 10 {
                // For groups: also check if participants shifted significantly
                let recentParticipants = Set(currentBatch.suffix(5).map(\.senderUsername))
                let nextParticipants = Set(messages[max(0, i-2)...min(messages.count-1, i+2)]
                    .map(\.senderUsername))
                let overlap = recentParticipants.intersection(nextParticipants).count
                let total = recentParticipants.union(nextParticipants).count
                let overlapRatio = total > 0 ? Double(overlap) / Double(total) : 1.0
                shouldSplit = overlapRatio < 0.3 && gap >= 300 // 5min gap + participant shift
            } else {
                shouldSplit = false
            }

            if shouldSplit {
                segments.append(makeSegment(currentBatch))
                currentBatch = [messages[i]]
            } else {
                currentBatch.append(messages[i])
            }
        }

        if !currentBatch.isEmpty {
            segments.append(makeSegment(currentBatch))
        }

        return segments
    }

    /// Find the segment containing the given message time, or the nearest one.
    static func findSegment(for messageTime: Int, in segments: [ConversationSegment]) -> ConversationSegment? {
        segments.first { $0.startTime <= messageTime && $0.endTime >= messageTime }
            ?? segments.min(by: { abs($0.endTime - messageTime) < abs($1.endTime - messageTime) })
    }

    private static func makeSegment(_ messages: [MessageInfo]) -> ConversationSegment {
        ConversationSegment(
            startTime: messages.first!.createTime,
            endTime: messages.last!.createTime,
            messages: messages,
            participants: Set(messages.map(\.senderUsername))
        )
    }
}
```

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/ConversationSegmenter.swift Tests/WeChatHUDTests/ConversationSegmenterTests.swift
git commit -m "feat: add ConversationSegmenter with time-gap + density splitting"
```

---

### Task 2.2: Message Feature Extractor

**Files:**
- Create: `Sources/WeChatHUD/Services/MessageFeatureExtractor.swift`
- Create: `Tests/WeChatHUDTests/MessageFeatureExtractorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WeChatHUDTests/MessageFeatureExtractorTests.swift
import XCTest
@testable import WeChatHUD

final class MessageFeatureExtractorTests: XCTestCase {

    func testQuestionMarkDetection() {
        let f = MessageFeatureExtractor.extract("你明天有空吗？")
        XCTAssertTrue(f.hasQuestionMark)
    }

    func testSecondPersonDetection() {
        let f1 = MessageFeatureExtractor.extract("你帮我看看")
        XCTAssertTrue(f1.hasSecondPerson)
        let f2 = MessageFeatureExtractor.extract("我已经做完了")
        XCTAssertFalse(f2.hasSecondPerson)
    }

    func testRequestVerbDetection() {
        let f = MessageFeatureExtractor.extract("麻烦帮我发一下文件")
        XCTAssertTrue(f.hasRequestVerb)
    }

    func testTimeReferenceDetection() {
        let f1 = MessageFeatureExtractor.extract("明天给你")
        XCTAssertTrue(f1.hasTimeReference)
        let f2 = MessageFeatureExtractor.extract("下周一之前搞定")
        XCTAssertTrue(f2.hasTimeReference)
    }

    func testUrgencyWordDetection() {
        let f = MessageFeatureExtractor.extract("这个很紧急，尽快处理")
        XCTAssertTrue(f.hasUrgencyWord)
    }

    func testCommitmentSignalDetection() {
        let f1 = MessageFeatureExtractor.extract("好的我明天发你")
        XCTAssertTrue(f1.hasCommitmentSignal)
        let f2 = MessageFeatureExtractor.extract("哈哈好搞笑")
        XCTAssertFalse(f2.hasCommitmentSignal)
    }

    func testMediaTypeText() {
        let f = MessageFeatureExtractor.extract("普通文字消息")
        XCTAssertEqual(f.detectedMediaType, .text)
    }

    func testMediaTypeLink() {
        let f = MessageFeatureExtractor.extract("看这个 https://mp.weixin.qq.com/xxx")
        XCTAssertEqual(f.detectedMediaType, .link)
    }

    func testMessageLength() {
        let f = MessageFeatureExtractor.extract("你好")
        XCTAssertEqual(f.messageLength, 2)
    }
}
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement MessageFeatureExtractor**

```swift
// Sources/WeChatHUD/Services/MessageFeatureExtractor.swift
import Foundation

/// Detected media type from message content.
enum DetectedMediaType: String {
    case text
    case image
    case voice
    case file
    case link
    case sticker
    case system
}

/// Pre-extracted features from a single message. These are algorithm-derived
/// signals passed to AI as "hints" — they add information, never filter data.
struct MessageFeatures {
    let hasQuestionMark: Bool
    let hasSecondPerson: Bool
    let hasRequestVerb: Bool
    let hasTimeReference: Bool
    let hasUrgencyWord: Bool
    let hasCommitmentSignal: Bool
    let detectedMediaType: DetectedMediaType
    let messageLength: Int
}

enum MessageFeatureExtractor {

    private static let questionMarks: Set<Character> = ["?", "？", "❓"]

    private static let secondPersonWords = ["你", "您", "你们"]

    private static let requestVerbs = [
        "帮", "请", "麻烦", "发", "给", "看看", "确认", "回复",
        "处理", "安排", "跟进", "协调", "转发", "审批", "签字"
    ]

    private static let timeWords = [
        "明天", "后天", "下周", "今天", "今天内", "月底", "周五",
        "周一", "周二", "周三", "周四", "周六", "周日", "下个月",
        "尽快", "马上", "立即", "稍后", "一会儿", "等会",
        "今晚", "明早", "上午", "下午", "晚上"
    ]

    private static let urgencyWords = [
        "紧急", "急", "尽快", "ASAP", "马上", "立即",
        "催", "截止", "deadline", "赶紧", "加急", "着急"
    ]

    private static let commitmentSignals = [
        "我去", "我来", "我发", "我问", "我看看", "我处理",
        "我安排", "我跟进", "我确认", "帮你", "给你", "发你",
        "回头", "等我", "好的", "没问题", "可以", "行",
        "OK", "ok", "收到", "了解", "明天给", "下周给"
    ]

    static func extract(_ text: String) -> MessageFeatures {
        MessageFeatures(
            hasQuestionMark: text.contains(where: { questionMarks.contains($0) }),
            hasSecondPerson: secondPersonWords.contains(where: { text.contains($0) }),
            hasRequestVerb: requestVerbs.contains(where: { text.contains($0) }),
            hasTimeReference: timeWords.contains(where: { text.contains($0) }),
            hasUrgencyWord: urgencyWords.contains(where: { text.contains($0) }),
            hasCommitmentSignal: commitmentSignals.contains(where: { text.contains($0) }),
            detectedMediaType: detectMediaType(text),
            messageLength: text.count
        )
    }

    private static func detectMediaType(_ text: String) -> DetectedMediaType {
        if text.hasPrefix("[图片]") || text.hasPrefix("<img") { return .image }
        if text.hasPrefix("[语音]") || text.hasPrefix("[语音消息]") { return .voice }
        if text.hasPrefix("[文件]") { return .file }
        if text.contains("http://") || text.contains("https://") || text.contains("mp.weixin.qq.com") { return .link }
        if text.hasPrefix("[动画表情]") || text.hasPrefix("[表情]") { return .sticker }
        if text.hasPrefix("[系统消息]") || text.contains("拍了拍") || text.contains("撤回了一条消息") { return .system }
        return .text
    }
}
```

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/MessageFeatureExtractor.swift Tests/WeChatHUDTests/MessageFeatureExtractorTests.swift
git commit -m "feat: add MessageFeatureExtractor with signal word detection"
```

---

### Task 2.3: Context Window Builder

**Files:**
- Create: `Sources/WeChatHUD/Services/ContextWindowBuilder.swift`
- Create: `Tests/WeChatHUDTests/ContextWindowBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/WeChatHUDTests/ContextWindowBuilderTests.swift
import XCTest
@testable import WeChatHUD

final class ContextWindowBuilderTests: XCTestCase {

    func testClassifierContextLimit() {
        // 30 messages, classifier should return at most 20
        let msgs = (0..<30).map { i in makeMsg(time: 1000 + i * 60, sender: "A", text: "msg\(i)") }
        let target = msgs[25]
        let result = ContextWindowBuilder.build(
            target: target,
            role: .classifier,
            allMessages: msgs,
            chatType: .privateChat,
            contactLookup: { _ in nil }
        )
        XCTAssertLessThanOrEqual(result.messages.count, 20)
        XCTAssertTrue(result.messages.contains(where: { $0.id == target.id }))
    }

    func testContextAnalyzerGetsMore() {
        let msgs = (0..<60).map { i in makeMsg(time: 1000 + i * 60, sender: "User\(i % 3)", text: "msg\(i)") }
        let target = msgs[50]
        let result = ContextWindowBuilder.build(
            target: target,
            role: .contextAnalyzer,
            allMessages: msgs,
            chatType: .group,
            contactLookup: { _ in nil }
        )
        XCTAssertGreaterThan(result.messages.count, 20, "Context analyzer should get more context than classifier")
        XCTAssertLessThanOrEqual(result.messages.count, 50)
    }

    func testCommitmentTrackerKeepsSmall() {
        let msgs = (0..<20).map { i in makeMsg(time: 1000 + i * 60, sender: "A", text: "msg\(i)") }
        let target = msgs[15]
        let result = ContextWindowBuilder.build(
            target: target,
            role: .commitmentTracker,
            allMessages: msgs,
            chatType: .privateChat,
            contactLookup: { _ in nil }
        )
        XCTAssertLessThanOrEqual(result.messages.count, 8)
    }

    func testAnnotationsIncludeRole() {
        let msgs = [makeMsg(time: 1000, sender: "boss1", text: "方案怎么样了")]
        let result = ContextWindowBuilder.build(
            target: msgs[0],
            role: .classifier,
            allMessages: msgs,
            chatType: .privateChat,
            contactLookup: { username in
                if username == "boss1" { return (.vip, .boss) }
                return nil
            }
        )
        XCTAssertEqual(result.messages[0].senderLevel, .vip)
        XCTAssertEqual(result.messages[0].senderRole, .boss)
    }

    func testSerializeProducesText() {
        let msgs = [makeMsg(time: 1000, sender: "A", text: "你好")]
        let result = ContextWindowBuilder.build(
            target: msgs[0],
            role: .classifier,
            allMessages: msgs,
            chatType: .privateChat,
            contactLookup: { _ in nil }
        )
        let text = result.serialize()
        XCTAssertTrue(text.contains("你好"))
    }

    private func makeMsg(time: Int, sender: String, text: String) -> MessageInfo {
        MessageInfo(
            id: "msg_\(time)_\(sender)",
            chatUsername: "test_chat", chatName: "Test",
            senderUsername: sender, senderName: sender,
            text: text, baseType: 1, subType: 0, createTime: time
        )
    }
}
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement ContextWindowBuilder**

```swift
// Sources/WeChatHUD/Services/ContextWindowBuilder.swift
import Foundation

/// An AI role that determines context window sizing rules.
enum ContextRole {
    case classifier           // max 20
    case commitmentTracker    // max 8
    case contextAnalyzer      // max 50
    case replyGenerator       // inherits contextAnalyzer output
    case vipAggregator        // max 80 (handled separately, per-VIP batch)
    case groupDigestor        // max 200 (full group, handled separately)
    case retrospector         // no raw messages (uses AI outputs)

    var maxMessages: Int {
        switch self {
        case .classifier: return 20
        case .commitmentTracker: return 8
        case .contextAnalyzer: return 50
        case .replyGenerator: return 30
        case .vipAggregator: return 80
        case .groupDigestor: return 200
        case .retrospector: return 0
        }
    }

    /// How many messages before the target to include.
    var lookBehind: Int {
        switch self {
        case .classifier: return 10
        case .commitmentTracker: return 5
        case .contextAnalyzer: return 40
        case .replyGenerator: return 15
        case .vipAggregator: return 3  // per-message context
        case .groupDigestor: return 0  // takes full range
        case .retrospector: return 0
        }
    }

    /// How many messages after the target to include.
    var lookAhead: Int {
        switch self {
        case .classifier: return 2
        case .commitmentTracker: return 0
        case .contextAnalyzer: return 5
        case .replyGenerator: return 2
        case .vipAggregator: return 1
        case .groupDigestor: return 0
        case .retrospector: return 0
        }
    }
}

/// A message annotated with sender role information for prompt injection.
struct AnnotatedMessage: Identifiable {
    let id: String
    let senderUsername: String
    let senderName: String
    let senderLevel: AttentionLevel?
    let senderRole: ContactRole?
    let text: String
    let createTime: Int
    let isTarget: Bool  // the message being analyzed
}

/// The assembled context window ready for prompt injection.
struct ContextWindow {
    let messages: [AnnotatedMessage]
    let chatType: ChatType
    let role: ContextRole

    /// Serialize to a text block suitable for embedding in a prompt.
    func serialize() -> String {
        messages.map { msg in
            let time = MessageInfo.formatRelative(msg.createTime)
            let roleTag: String
            if let level = msg.senderLevel, let role = msg.senderRole {
                roleTag = "[\(level.label)/\(role.label)]"
            } else {
                roleTag = ""
            }
            let marker = msg.isTarget ? " ← 目标消息" : ""
            return "[\(time)] \(roleTag)\(msg.senderName): \(msg.text)\(marker)"
        }.joined(separator: "\n")
    }
}

enum ContextWindowBuilder {

    typealias ContactLookup = (String) -> (AttentionLevel, ContactRole)?

    /// Build a context window centered on the target message.
    /// - Parameters:
    ///   - target: The message being analyzed
    ///   - role: Which AI role needs this context (determines sizing)
    ///   - allMessages: All available messages in this chat, sorted by createTime ascending
    ///   - chatType: Private or group
    ///   - contactLookup: Closure to resolve sender username → (level, role)
    static func build(
        target: MessageInfo,
        role: ContextRole,
        allMessages: [MessageInfo],
        chatType: ChatType,
        contactLookup: ContactLookup
    ) -> ContextWindow {
        guard !allMessages.isEmpty else {
            return ContextWindow(messages: [], chatType: chatType, role: role)
        }

        // Find target index
        let targetIdx = allMessages.firstIndex(where: { $0.id == target.id })
            ?? allMessages.count - 1

        // Calculate range
        let start = max(0, targetIdx - role.lookBehind)
        let end = min(allMessages.count - 1, targetIdx + role.lookAhead)

        // Slice and annotate
        let slice = Array(allMessages[start...end])
        let annotated = slice.map { msg -> AnnotatedMessage in
            let lookup = contactLookup(msg.senderUsername)
            return AnnotatedMessage(
                id: msg.id,
                senderUsername: msg.senderUsername,
                senderName: msg.senderName,
                senderLevel: lookup?.0,
                senderRole: lookup?.1,
                text: msg.text,
                createTime: msg.createTime,
                isTarget: msg.id == target.id
            )
        }

        // Enforce max limit
        let limited: [AnnotatedMessage]
        if annotated.count > role.maxMessages {
            // Keep target message, trim from the start
            let targetPos = annotated.firstIndex(where: { $0.isTarget }) ?? annotated.count - 1
            let keepFromEnd = min(role.maxMessages, annotated.count - targetPos)
            let keepFromStart = role.maxMessages - keepFromEnd
            let startSlice = Array(annotated.prefix(keepFromStart))
            let endSlice = Array(annotated.suffix(keepFromEnd))
            limited = startSlice + endSlice
        } else {
            limited = annotated
        }

        return ContextWindow(messages: limited, chatType: chatType, role: role)
    }

    /// Build context for VIP Aggregator: per-VIP-message with surrounding context.
    /// Returns messages grouped by chat, each VIP message with `lookBehind` context.
    static func buildVIPContext(
        vipMessages: [MessageInfo],
        allMessagesByChat: [String: [MessageInfo]],
        contactLookup: ContactLookup
    ) -> [AnnotatedMessage] {
        var result: [AnnotatedMessage] = []
        for vipMsg in vipMessages {
            guard let chatMsgs = allMessagesByChat[vipMsg.chatUsername] else { continue }
            let window = build(
                target: vipMsg,
                role: .vipAggregator,
                allMessages: chatMsgs,
                chatType: .group,
                contactLookup: contactLookup
            )
            result.append(contentsOf: window.messages)
        }
        return result
    }
}
```

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/ContextWindowBuilder.swift Tests/WeChatHUDTests/ContextWindowBuilderTests.swift
git commit -m "feat: add ContextWindowBuilder with per-role sizing rules"
```

---

## Phase 3: AI Roles (Prompts + Actors)

**Goal:** Implement the 8 AI actors with versioned prompts. Each reads config from DB, uses ContextWindowBuilder for input assembly, writes audit logs.

### Task 3.1: Enhanced Classifier Prompt (v4)

**Files:**
- Create: `Sources/WeChatHUD/Resources/prompts/classifier_v4.txt`

- [ ] **Step 1: Write the new prompt**

```text
你是微信消息分析助手。判断一条消息是否需要用户回应。

## 发送者信息
- 姓名：{sender_name}
- 身份角色：{sender_role}（{role_description}）
- 关注级别：{attention_level}
- 聊天场景：{chat_kind}（{chat_name}）

## 算法预分析（供你参考，以语义理解为准）
- 包含问号：{has_question_mark}
- 包含第二人称：{has_second_person}
- 包含请求动词：{has_request_verb}
- 包含时间要求：{has_time_reference}
- 包含紧急词：{has_urgency_word}
- 消息长度：{message_length}字

## 角色特定规则
{role_rules}

## 上下文（带角色标注）
{context_messages}

## 目标消息
{message_body}

## 判断要求（输出 JSON）
{
  "is_ask": true/false,
  "ask_type": "yes_no|send_file|review|decide|info|schedule|action|none",
  "summary": "一句话概括对方需要你做什么（限20字）",
  "deadline_hint": "从消息提取的时间要求（如有）",
  "urgency": "routine|timely|urgent",
  "confidence": 0.0-1.0,
  "related_pending": "如果与已有待决项相似，填写该项摘要，否则null"
}

## 角色影响判断的规则
- boss: 反问句算ask（"这个没问题吧？"=需要确认）；感叹句看情绪（"辛苦了"≠ask，"怎么还没好！"=ask）
- key_client/client: 任何疑问句都算ask（客户不能不理）
- family: 涉及健康/安全/钱 → urgency=urgent
- colleague: 只有明确请求/问题才算ask
- supplier: 节日问候/营销不算ask
- 如果算法检测到紧急词但你判断不是ask，confidence应降低到review区间让人工确认

## 重要
- 只输出JSON，不要其他文字
- "收到""好的""OK"单独出现不是ask
- 转发的文章/链接不是ask（除非附带提问）
- 群聊中非@用户的讨论，即使有疑问句，如果不是说给用户的也不是ask
```

- [ ] **Step 2: Add to Package.swift resources (already configured)**

The `resources: [.copy("Resources/prompts")]` is already in Package.swift.

- [ ] **Step 3: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Resources/prompts/classifier_v4.txt
git commit -m "feat: classifier_v4 prompt with role context + algorithm hints"
```

---

### Task 3.2: Commitment Tracker

**Files:**
- Create: `Sources/WeChatHUD/Services/CommitmentTracker.swift`
- Create: `Sources/WeChatHUD/Resources/prompts/commitment_v1.txt`
- Create: `Tests/WeChatHUDTests/CommitmentTrackerTests.swift`

- [ ] **Step 1: Write the prompt**

```text
你是承诺识别助手。判断用户发出的消息是否包含对他人的承诺。

## 接收者信息
- 姓名：{recipient_name}
- 身份：{recipient_role}

## 算法预检测的承诺信号
{commitment_signals}

## 对话上下文
{context_messages}

## 用户发出的消息
{user_message}

## 判断要求（输出JSON）
{
  "is_commitment": true/false,
  "content": "你承诺做什么（限15字）",
  "commit_to": "承诺给谁",
  "deadline_extracted": "tomorrow|vague_soon|inherit|none|具体描述",
  "confidence": 0.0-1.0
}

## 是承诺的
- 明确答应做某事："好的我明天发你""我去问问老板"
- 确认了对方的请求："收到"（上文是请求时）
- 给了时间预期："下周一之前给你"

## 不是承诺的
- 纯确认收到信息："收到"（上文只是通知不是请求）
- 社交回应："好的好的""哈哈""辛苦了"
- 反问/讨论："这个要怎么做？"
- 转述他人："老板说明天开会"（不是你的承诺）

只输出JSON。
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/WeChatHUDTests/CommitmentTrackerTests.swift
import XCTest
@testable import WeChatHUD

final class CommitmentTrackerTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_commit_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        super.tearDown()
    }

    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "commitment_v1"))
    }

    func testCommitmentSignalFilter() {
        // Messages WITH commitment signals should pass the pre-filter
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("好的我明天发你"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("收到"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("没问题，我处理"))

        // Messages WITHOUT signals should be filtered out
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("哈哈好搞笑"))
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("这个怎么做"))
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("？"))
    }

    func testCommitmentStoreRoundtrip() {
        try! store.upsertCommitment(
            msgUID: "c1", chatUsername: "chat1", chatName: "张三",
            content: "明天发方案", commitTo: "张三",
            deadlineAt: Date(timeIntervalSince1970: 5000),
            confidence: 0.9, promptVersion: "commitment_v1"
        )
        let pending = store.loadCommitments(status: .pending)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].content, "明天发方案")

        try! store.updateCommitmentStatus(msgUID: "c1", status: .fulfilled)
        let fulfilled = store.loadCommitments(status: .fulfilled)
        XCTAssertEqual(fulfilled.count, 1)
        let stillPending = store.loadCommitments(status: .pending)
        XCTAssertEqual(stillPending.count, 0)
    }
}
```

- [ ] **Step 3: Implement CommitmentTracker actor**

```swift
// Sources/WeChatHUD/Services/CommitmentTracker.swift
import Foundation

/// Scans YOUR outgoing messages for promises/commitments. Only messages
/// that pass the signal-word pre-filter are sent to AI — the pre-filter
/// is additive (marks signals for AI reference), not subtractive.
actor CommitmentTracker {
    private let store: HUDStore
    private let promptLoader: PromptLoader

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.promptLoader = promptLoader
    }

    struct CommitmentResult {
        let isCommitment: Bool
        let content: String
        let commitTo: String
        let deadlineExtracted: String
        let confidence: Double
    }

    /// Quick pre-filter: does this message contain words that MIGHT indicate
    /// a commitment? This is additive — the signal words are passed to AI
    /// as hints. Messages without any signal are still stored, just not
    /// sent to AI (pure noise like "哈哈" from the user).
    static func hasCommitmentSignal(_ text: String) -> Bool {
        let signals = [
            "明天", "下周", "今天内", "稍后", "一会儿", "马上",
            "我去", "我来", "我发", "我问", "我看看", "我处理",
            "我安排", "我跟进", "我确认", "帮你", "给你", "发你",
            "回头", "等我", "好的", "没问题", "可以", "行",
            "OK", "ok", "收到", "了解", "月底前", "周五之前"
        ]
        return signals.contains(where: { text.contains($0) })
    }

    /// Analyze a message you sent. Returns nil if AI is unavailable.
    func analyze(
        yourMessage: MessageInfo,
        contextMessages: [AnnotatedMessage],
        recipientName: String,
        recipientRole: ContactRole
    ) async -> CommitmentResult? {
        let config = store.loadClassifierConfig()
        guard !config.baseURL.isEmpty else { return nil }

        let template: String
        do {
            template = try promptLoader.load(version: "commitment_v1")
        } catch {
            print("[WCHUD] CommitmentTracker: prompt load failed: \(error)")
            return nil
        }

        let features = MessageFeatureExtractor.extract(yourMessage.text)
        let signals = CommitmentTracker.hasCommitmentSignal(yourMessage.text)
            ? "算法检测到承诺信号词" : "算法未检测到明显信号词"

        let contextText = contextMessages.map { msg in
            "[\(MessageInfo.formatRelative(msg.createTime))] \(msg.senderName): \(msg.text)"
        }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{recipient_name}", with: recipientName)
            .replacingOccurrences(of: "{recipient_role}", with: recipientRole.label)
            .replacingOccurrences(of: "{commitment_signals}", with: signals)
            .replacingOccurrences(of: "{context_messages}", with: contextText)
            .replacingOccurrences(of: "{user_message}", with: yourMessage.text)

        let started = Date()
        let response = await callModel(prompt: prompt, config: config)
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        guard let body = response else {
            store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: "no response"
            ))
            return nil
        }

        guard let result = parseResult(body) else {
            store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: body,
                latencyMs: latency, status: .parseError, errorMessage: "JSON parse failed"
            ))
            return nil
        }

        store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .commitmentTracker,
            model: config.model, promptVersion: "commitment_v1",
            inputText: yourMessage.text, outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        return result
    }

    // MARK: - Private

    private func callModel(prompt: String, config: AIClassifierConfig) async -> String? {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "max_tokens": 256
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private func parseResult(_ text: String) -> CommitmentResult? {
        let cleaned = cleanJSON(text)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let isCommitment = json["is_commitment"] as? Bool else { return nil }
        return CommitmentResult(
            isCommitment: isCommitment,
            content: json["content"] as? String ?? "",
            commitTo: json["commit_to"] as? String ?? "",
            deadlineExtracted: json["deadline_extracted"] as? String ?? "none",
            confidence: json["confidence"] as? Double ?? 0.5
        )
    }

    private func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip <think>...</think>
        while let range = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") {
                s.removeSubrange(range.lowerBound...end.upperBound)
            } else { break }
        }
        // Strip ```json fences
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Find JSON boundaries
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
            s = String(s[start...end])
        }
        return s
    }
}
```

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/CommitmentTracker.swift Sources/WeChatHUD/Resources/prompts/commitment_v1.txt Tests/WeChatHUDTests/CommitmentTrackerTests.swift
git commit -m "feat: add CommitmentTracker actor with signal pre-filter + prompt"
```

---

### Task 3.3: VIP Aggregator

**Files:**
- Create: `Sources/WeChatHUD/Services/VIPAggregator.swift`
- Create: `Sources/WeChatHUD/Resources/prompts/vip_aggregator_v1.txt`
- Create: `Tests/WeChatHUDTests/VIPAggregatorTests.swift`

- [ ] **Step 1: Write the prompt file**

```text
你是 VIP 动态分析师。分析 [{vip_name}]（{role_label}）最近在各群的活动。

## 此人档案
- 身份：{role_label}（{role_description}）
- 近期情绪历史：{mood_history}
- 用户与此人的关系状态：
  - 上次直接互动：{last_interaction}
  - 用户对此人有 {commitment_count} 个未兑现承诺

## 此人在各群的发言（★ 标记为此人发言，带前后上下文）
{activity_by_group}

## 算法预检测
- 疑似提到用户的位置：{user_mentioned_in}
- 语气信号：{tone_signals}
- 决策信号：{decision_signals}
（以上为算法初步检测，请以语义理解为准）

## 分析维度（{role_label}）
{role_dimensions}

## 输出 JSON
{
  "summary": "此人最近在忙什么（限50字）",
  "involves_user": true/false,
  "involve_detail": "怎么涉及用户的（限30字）",
  "involve_source": "哪个群的哪条消息",
  "mood": "positive|neutral|impatient|upset|angry",
  "mood_evidence": "判断依据（引用原文）",
  "mood_trend_analysis": "结合历史的趋势判断（限50字）",
  "key_decisions": [{"decision": "", "group": "", "implication_for_user": ""}],
  "cross_group_pattern": "跨群行为模式（限50字）",
  "urgency": "routine|heads_up|urgent",
  "urgency_reason": "判断理由",
  "recommended_action": "建议用户怎么做（限30字）",
  "action_timing": "now|today|this_week|no_action",
  "key_topics": ["话题1", "话题2"]
}

只输出JSON。
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/WeChatHUDTests/VIPAggregatorTests.swift
import XCTest
@testable import WeChatHUD

final class VIPAggregatorTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_vipagg_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close(); super.tearDown() }

    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "vip_aggregator_v1"))
    }

    func testVIPTraceCapture() {
        // Insert traces
        for i in 0..<5 {
            try! store.insertVIPTrace(
                vipUsername: "boss1", vipName: "王总",
                chatUsername: "group\(i % 2)", chatName: "群\(i % 2)",
                msgUID: "msg\(i)", rawText: "text\(i)", msgTime: 1000 + i * 60
            )
        }
        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        XCTAssertEqual(unbatched.count, 5)
    }

    func testBatchMarking() {
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g1", chatName: "群1",
            msgUID: "m1", rawText: "t1", msgTime: 1000
        )
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g2", chatName: "群2",
            msgUID: "m2", rawText: "t2", msgTime: 1060
        )
        let traces = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        try! store.markVIPTracesBatched(ids: traces.map(\.id), batchID: "batch_001")
        let remaining = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        XCTAssertEqual(remaining.count, 0)
    }
}
```

- [ ] **Step 3: Implement VIPAggregator actor**

```swift
// Sources/WeChatHUD/Services/VIPAggregator.swift
import Foundation

/// Periodically aggregates VIP messages from all groups and produces
/// an intelligence summary. Batches unbatched traces, sends them to AI
/// with surrounding context, and stores the analysis.
actor VIPAggregator {
    private let store: HUDStore
    private let promptLoader: PromptLoader

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.promptLoader = promptLoader
    }

    struct AggregateResult: Codable {
        let summary: String
        let involvesUser: Bool
        let involveDetail: String?
        let mood: String
        let moodEvidence: String
        let moodTrendAnalysis: String
        let urgency: String
        let urgencyReason: String
        let recommendedAction: String
        let actionTiming: String
        let keyTopics: [String]

        enum CodingKeys: String, CodingKey {
            case summary
            case involvesUser = "involves_user"
            case involveDetail = "involve_detail"
            case mood
            case moodEvidence = "mood_evidence"
            case moodTrendAnalysis = "mood_trend_analysis"
            case urgency
            case urgencyReason = "urgency_reason"
            case recommendedAction = "recommended_action"
            case actionTiming = "action_timing"
            case keyTopics = "key_topics"
        }
    }

    /// Run aggregation for a single VIP. Collects unbatched traces,
    /// builds context, calls AI, marks traces as batched.
    func aggregate(
        vipUsername: String,
        vipName: String,
        vipRole: ContactRole,
        userNameVariants: [String],
        recentMoodHistory: String,
        lastInteraction: String,
        commitmentCount: Int
    ) async -> AggregateResult? {
        let traces = store.loadUnbatchedVIPTraces(vipUsername: vipUsername)
        guard !traces.isEmpty else { return nil }

        let config = store.loadClassifierConfig()
        guard !config.baseURL.isEmpty else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "vip_aggregator_v1") }
        catch { return nil }

        // Group traces by chat
        let grouped = Dictionary(grouping: traces, by: \.chatName)
        var activityText = ""
        for (chatName, msgs) in grouped.sorted(by: { $0.key < $1.key }) {
            activityText += "\n[\(chatName)] (\(msgs.count)条):\n"
            for msg in msgs.sorted(by: { $0.msgTime < $1.msgTime }) {
                activityText += "  [\(MessageInfo.formatRelative(msg.msgTime))] ★\(vipName): \(msg.rawText)\n"
            }
        }

        // Detect user mentions
        let userMentions = traces.filter { trace in
            userNameVariants.contains(where: { trace.rawText.contains($0) })
        }
        let mentionText = userMentions.isEmpty ? "无"
            : userMentions.map { "\($0.chatName): \"\($0.rawText)\"" }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{vip_name}", with: vipName)
            .replacingOccurrences(of: "{role_label}", with: vipRole.label)
            .replacingOccurrences(of: "{role_description}", with: vipRole.roleDescription)
            .replacingOccurrences(of: "{mood_history}", with: recentMoodHistory)
            .replacingOccurrences(of: "{last_interaction}", with: lastInteraction)
            .replacingOccurrences(of: "{commitment_count}", with: "\(commitmentCount)")
            .replacingOccurrences(of: "{activity_by_group}", with: activityText)
            .replacingOccurrences(of: "{user_mentioned_in}", with: mentionText)
            .replacingOccurrences(of: "{tone_signals}", with: "（由AI直接判断）")
            .replacingOccurrences(of: "{decision_signals}", with: "（由AI直接判断）")
            .replacingOccurrences(of: "{role_dimensions}", with: vipRole.vipTrackDimensions.joined(separator: ", "))

        let started = Date()
        guard let response = await callModel(prompt: prompt, config: config) else { return nil }
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        // Audit
        store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .vipAggregator,
            model: config.model, promptVersion: "vip_aggregator_v1",
            inputText: "\(vipName): \(traces.count) traces",
            outputText: response, latencyMs: latency,
            status: .ok, errorMessage: nil
        ))

        // Mark batched
        let batchID = "batch_\(Int(Date().timeIntervalSince1970))_\(vipUsername)"
        try? store.markVIPTracesBatched(ids: traces.map(\.id), batchID: batchID)

        // Parse
        guard let data = cleanJSON(response).data(using: .utf8),
              let result = try? JSONDecoder().decode(AggregateResult.self, from: data) else { return nil }
        return result
    }

    private func callModel(prompt: String, config: AIClassifierConfig) async -> String? {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.2,
            "max_tokens": 1024
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") {
                s.removeSubrange(range.lowerBound...end.upperBound)
            } else { break }
        }
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
            s = String(s[start...end])
        }
        return s
    }
}
```

- [ ] **Step 4: Run tests — passes**

- [ ] **Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/VIPAggregator.swift Sources/WeChatHUD/Resources/prompts/vip_aggregator_v1.txt Tests/WeChatHUDTests/VIPAggregatorTests.swift
git commit -m "feat: add VIPAggregator actor with batch trace analysis"
```

---

### Task 3.4: Recall Analyzer

**Files:**
- Create: `Sources/WeChatHUD/Services/RecallAnalyzer.swift`
- Create: `Sources/WeChatHUD/Resources/prompts/recall_analyzer_v1.txt`

- [ ] **Step 1: Write the prompt**

```text
此人撤回了一条消息，请分析。

## 撤回信息
- 发送者：{sender_name}（{sender_role}）
- 原文："{original_text}"
- 发出 {delay_seconds} 秒后撤回
- 聊天类型：{chat_type}（{chat_name}）

## 撤回前后上下文
{context}

## 分析（输出JSON）
{
  "likely_reason": "wrong_chat|said_too_much|changed_mind|typo|emotional|premature",
  "intelligence_value": "high|medium|low|none",
  "detail": "情报内容（限30字，仅value>=medium时提供）",
  "should_notify": true/false,
  "notify_level": "strong|standard|light"
}

## 判断依据
- 发出<5秒撤回+重发了类似内容 → typo
- 发出<10秒撤回+没重发 → premature或wrong_chat
- 包含敏感信息(人名/金额/决策) → said_too_much, value=high
- 情绪化措辞后撤回 → emotional
- 无敏感内容+短消息 → 大概率typo, value=none

只输出JSON。
```

- [ ] **Step 2: Write RecallAnalyzer actor**

```swift
// Sources/WeChatHUD/Services/RecallAnalyzer.swift
import Foundation

/// Analyzes recalled messages for intelligence value. Called asynchronously
/// after a recall is detected and captured.
actor RecallAnalyzer {
    private let store: HUDStore
    private let promptLoader: PromptLoader

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.promptLoader = promptLoader
    }

    struct AnalysisResult {
        let reason: String
        let intelligenceValue: String
        let detail: String?
        let shouldNotify: Bool
        let notifyLevel: NotifyLevel?
    }

    func analyze(recalled: RecalledMessage, context: [MessageInfo]) async -> AnalysisResult? {
        let config = store.loadClassifierConfig()
        guard !config.baseURL.isEmpty else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "recall_analyzer_v1") }
        catch { return nil }

        let contextText = context.map {
            "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \($0.text)"
        }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{sender_name}", with: recalled.senderName)
            .replacingOccurrences(of: "{sender_role}", with: recalled.senderRole.label)
            .replacingOccurrences(of: "{original_text}", with: recalled.originalText)
            .replacingOccurrences(of: "{delay_seconds}", with: "\(recalled.recallDelaySeconds)")
            .replacingOccurrences(of: "{chat_type}", with: recalled.chatType.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: recalled.chatName)
            .replacingOccurrences(of: "{context}", with: contextText.isEmpty ? "（无上下文）" : contextText)

        guard let response = await callModel(prompt: prompt, config: config) else { return nil }
        guard let data = cleanJSON(response).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let result = AnalysisResult(
            reason: json["likely_reason"] as? String ?? "unknown",
            intelligenceValue: json["intelligence_value"] as? String ?? "none",
            detail: json["detail"] as? String,
            shouldNotify: json["should_notify"] as? Bool ?? false,
            notifyLevel: (json["notify_level"] as? String).flatMap { NotifyLevel(rawValue: $0) }
        )

        // Write analysis back to recalled_messages table
        try? store.updateRecallAnalysis(
            msgUID: recalled.msgUID,
            reason: result.reason,
            value: result.intelligenceValue,
            detail: result.detail,
            shouldNotify: result.shouldNotify,
            notifyLevel: result.notifyLevel
        )

        return result
    }

    private func callModel(prompt: String, config: AIClassifierConfig) async -> String? {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1, "max_tokens": 256
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") { s.removeSubrange(range.lowerBound...end.upperBound) } else { break }
        }
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") { s = String(s[start...end]) }
        return s
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/RecallAnalyzer.swift Sources/WeChatHUD/Resources/prompts/recall_analyzer_v1.txt
git commit -m "feat: add RecallAnalyzer actor for recalled message intelligence"
```

---

### Task 3.5: Context Analyzer

**Files:**
- Create: `Sources/WeChatHUD/Services/ContextAnalyzer.swift`
- Create: `Sources/WeChatHUD/Resources/prompts/context_analyzer_v1.txt`

- [ ] **Step 1: Write prompt** (content as designed in architecture discussion — event dossier format with background, what_they_want, hidden_context, stakeholder_map, your_position, suggested_action, suggested_timing, risk_if_ignore)

- [ ] **Step 2: Implement ContextAnalyzer actor** — takes an EventDossier (assembled by ChatMonitor when user expands a pending ask), calls AI, returns structured analysis. Reuses the same HTTP + JSON cleanup pattern as other actors.

- [ ] **Step 3: Test + Commit**

---

### Task 3.6: Enhanced Retrospector Prompt

**Files:**
- Create: `Sources/WeChatHUD/Resources/prompts/daily_retrospect_v2.txt`

Update the daily retrospector to accept the full DailyPackage (ask summary, commitment summary, VIP summaries, group summaries, relationship health, recall records) and output the enhanced format with by-role sections, unfulfilled commitments, tomorrow priorities, VIP intelligence, relationship alerts, and copyable WeChat daily report.

- [ ] **Step 1: Write updated prompt**
- [ ] **Step 2: Commit**

---

## Phase 4: ChatMonitor Redesign

**Goal:** Rewire the scan loop for four-tier contact routing, VIP trace capture, recall detection, and commitment scanning.

### Task 4.1: Four-Tier Message Router

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add contact lookup helper**

```swift
/// Look up a sender's attention level and role from the contacts table.
/// Falls back to whitelist table for backward compat.
private func lookupContact(_ username: String) -> (AttentionLevel, ContactRole)? {
    if let contact = store.getContact(username: username) {
        return (contact.attentionLevel, contact.role)
    }
    // Fallback: check old whitelist
    if let entry = store.getWhitelistEntry(username: username) {
        let level: AttentionLevel = entry.attentionLevel == .vip ? .vip : .whitelist
        return (level, .colleague) // default role for unmigrated entries
    }
    return nil
}
```

- [ ] **Step 2: Implement processMessage routing**

Add a `processMessage` method that implements the four-tier switch from the architecture:

```swift
private func processMessage(
    _ msg: MessageInfo,
    senderLevel: AttentionLevel,
    senderRole: ContactRole,
    chatType: ChatType,
    mentionsUser: Bool,
    mentionsUserName: Bool
) async {
    switch (senderLevel, chatType, mentionsUser) {
    case (.stranger, _, _):
        return // completely ignored

    case (.vip, .privateChat, _):
        await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: true)

    case (.vip, .group, _):
        captureVIPTrace(msg)
        if mentionsUser || mentionsUserName {
            await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: true)
        }

    case (.whitelist, .privateChat, _):
        await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: false)

    case (.whitelist, .group, true):
        await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: true)

    case (.whitelist, .group, false) where mentionsUserName:
        // Lightweight heads-up notification
        await notifyHeadsUp(msg)

    case (.whitelist, .group, false):
        return // whitelist non-@ group messages ignored

    case (.greylist, .group, true):
        await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: true)

    case (.greylist, .privateChat, _):
        await classifyAndEnqueue(msg, level: senderLevel, role: senderRole, withContext: false)

    case (.greylist, .group, false):
        return

    default:
        return
    }
}
```

- [ ] **Step 3: Add VIP trace capture in scan loop**

```swift
private func captureVIPTrace(_ msg: MessageInfo) {
    try? store.insertVIPTrace(
        vipUsername: msg.senderUsername,
        vipName: msg.senderName,
        chatUsername: msg.chatUsername,
        chatName: msg.chatName,
        msgUID: msg.id,
        rawText: msg.text,
        msgTime: msg.createTime
    )
}
```

- [ ] **Step 4: Add commitment detection for outgoing messages**

In the scan loop, after processing incoming messages, check YOUR outgoing messages:

```swift
// Detect your commitments in outgoing messages
if msg.senderUsername == myUsername && CommitmentTracker.hasCommitmentSignal(msg.text) {
    Task {
        let context = ContextWindowBuilder.build(
            target: msg, role: .commitmentTracker,
            allMessages: chatMessages, chatType: chatType,
            contactLookup: { self.lookupContact($0) }
        )
        if let result = await commitmentTracker.analyze(
            yourMessage: msg,
            contextMessages: context.messages,
            recipientName: recipientName,
            recipientRole: recipientRole
        ), result.isCommitment {
            try? store.upsertCommitment(
                msgUID: msg.id,
                chatUsername: msg.chatUsername,
                chatName: msg.chatName,
                content: result.content,
                commitTo: result.commitTo,
                deadlineAt: resolveDeadline(result.deadlineExtracted),
                confidence: result.confidence,
                promptVersion: "commitment_v1"
            )
        }
    }
}
```

- [ ] **Step 5: Test routing logic, commit**

```bash
git commit -m "feat: four-tier message routing + VIP capture + commitment detection"
```

---

### Task 4.2: Recall Detection

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add message snapshot mechanism**

During each scan, snapshot message UIDs for VIP/whitelist contacts. On next scan, if a UID disappears or has revoke type, capture the original from snapshot.

```swift
/// Message snapshot for recall detection. Stored in memory only.
private var messageSnapshots: [String: String] = [:] // msgUID → rawText

private func detectRecalls(currentMessages: [MessageInfo], chatUsername: String, chatName: String) {
    let currentUIDs = Set(currentMessages.map(\.id))

    // Check for messages that were in snapshot but disappeared
    for (uid, text) in messageSnapshots {
        if !currentUIDs.contains(uid) {
            // Message was recalled — look up sender info
            // Insert into recalled_messages
        }
    }

    // Also check for WeChat's "[已撤回]" system messages
    for msg in currentMessages where msg.text.contains("撤回了一条消息") {
        // Try to find the original from snapshot
    }

    // Update snapshot
    for msg in currentMessages {
        messageSnapshots[msg.id] = msg.text
    }
}
```

- [ ] **Step 2: Wire recall detection into scan loop**

- [ ] **Step 3: Trigger RecallAnalyzer asynchronously after capture**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: recall detection with snapshot comparison"
```

---

### Task 4.3: VIP Aggregator Scheduling

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add periodic VIP aggregation trigger**

After each scan, check if any VIP has accumulated unbatched traces. If count >= 10 or time since last aggregation >= 15 minutes, trigger aggregation.

```swift
private var lastAggregationTime: [String: Date] = [:]

private func maybeAggregateVIPs() async {
    let vipUsernames = store.loadVIPUsernames()
    for username in vipUsernames {
        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: username)
        let timeSinceLastAgg = Date().timeIntervalSince(lastAggregationTime[username] ?? .distantPast)

        if unbatched.count >= 10 || (unbatched.count > 0 && timeSinceLastAgg >= 900) {
            guard let contact = store.getContact(username: username) else { continue }
            let result = await vipAggregator.aggregate(
                vipUsername: username,
                vipName: contact.displayName,
                vipRole: contact.role,
                userNameVariants: loadUserNameVariants(),
                recentMoodHistory: "（待实现）",
                lastInteraction: "（待实现）",
                commitmentCount: store.loadCommitments(status: .pending).filter { $0.commitTo == contact.displayName }.count
            )
            lastAggregationTime[username] = Date()

            // Handle notification based on urgency
            if let result = result, result.urgency == "urgent" || result.involvesUser {
                // Trigger notification
            }
        }
    }
}
```

- [ ] **Step 2: Call from scan loop**
- [ ] **Step 3: Commit**

```bash
git commit -m "feat: periodic VIP aggregation scheduling"
```

---

## Phase 5: UI Redesign

**Goal:** Rebuild the HUD's three layers with AI-first content.

### Task 5.1: Redesigned Compact Pill

**Files:**
- Modify: `Sources/WeChatHUD/App/CompactBarView.swift`

Replace unread count with "N 件事等你决定" + health color + VIP dots + urgency headline.

### Task 5.2: Redesigned Notification Banner

**Files:**
- Modify: `Sources/WeChatHUD/App/NotificationBannerView.swift`

Show AI-analyzed ask summary instead of raw message. Add inline quick-action buttons ([智能回复] [延后] [不是找我]).

### Task 5.3: Redesigned Extended Panel — 待决 Tab

**Files:**
- Modify: `Sources/WeChatHUD/App/ExtendedTabsView.swift`

New tab structure: 待决 | 群动态 | VIP 雷达 | 今日面板. 待决 tab sorted by VIP超时 → VIP未超时 → 白名单超时 → 白名单未超时 → 灰名单 → 低置信度(折叠). Include commitment section "你答应了但还没做".

### Task 5.4: VIP Radar Tab

**Files:**
- Create: `Sources/WeChatHUD/App/VIPRadarView.swift`

Per-VIP cards showing: active groups, key topics, mood + trend, involves_user flag, action buttons.

### Task 5.5: Today Panel Tab

**Files:**
- Create: `Sources/WeChatHUD/App/TodayPanelView.swift`

Stats bar (received/filtered/handled/pending), AI daily report draft with copy button, relationship alerts, AI accuracy.

### Task 5.6: Smart Reply Inline Component

**Files:**
- Create: `Sources/WeChatHUD/App/SmartReplyView.swift`

Inline reply area: text input for user thoughts, 3 AI candidates (standard/detailed/brief), [采用] button that AX-navigates to WeChat chat and pastes text.

---

## Phase 6: Settings & Algorithm Refresh

### Task 6.1: AI Engine Settings Section

**Files:**
- Modify: `Sources/WeChatHUD/App/SettingsView.swift`

Add "AI 引擎" section with: model config, prompt versions, algorithm parameters (session segmentation thresholds, context window sizes, signal word lists), [刷新算法规则] button, [重跑全量分类] button, accuracy dashboard.

### Task 6.2: Contact Management in Settings

**Files:**
- Modify: `Sources/WeChatHUD/App/SettingsView.swift`

Replace whitelist tab with full contact management: show all four tiers, edit role per contact, add role_note, adjust reply window. Support drag-to-change-level.

### Task 6.3: Algorithm Refresh Engine

**Files:**
- Create: `Sources/WeChatHUD/Services/AlgorithmRefresher.swift`

One-click refresh: re-scan chat history to rebuild interaction frequency baselines, extract writing style profiles, detect name variants, calibrate segmentation parameters.

---

## Execution Order

```
Phase 1 (Data Foundation)    ← START HERE, everything depends on this
  └─ Phase 2 (Algorithm Layer)
       └─ Phase 3 (AI Roles)
            └─ Phase 4 (ChatMonitor Redesign)
                 └─ Phase 5 (UI Redesign)
                      └─ Phase 6 (Settings & Refresh)
```

Phases 1-4 are fully specified with code. Phases 5-6 are structurally defined — the SwiftUI views follow the same patterns as existing views, and the engineer should reference `ExtendedTabsView.swift` (878 lines) as the template for new tabs.

**Total estimated tasks:** 20 (6 in Phase 1, 3 in Phase 2, 6 in Phase 3, 3 in Phase 4, 6 in Phase 5, 3 in Phase 6)

---

## Verification Commands

After each phase, run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
swift build 2>&1 | tail -3           # Must compile clean
swift test 2>&1 | tail -5            # Must pass all tests
swift test --filter NewSchemaTests   # Phase 1 specific
swift test --filter ConversationSegmenterTests  # Phase 2
swift test --filter CommitmentTrackerTests      # Phase 3
```
