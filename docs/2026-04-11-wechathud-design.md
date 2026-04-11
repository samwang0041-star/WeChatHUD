# WeChatHUD Design Spec

> macOS native floating overlay for WeChat message monitoring and AI-powered analysis.

## 1. Product Overview

### What It Is
A top-of-screen floating bar (吸顶条) that monitors WeChat messages in real-time, surfaces important information, and provides AI-powered analysis to help the user understand and respond to conversations efficiently.

### What It Is Not
- Not a full WeChat client (no sending messages)
- Not a replacement for the existing Python CLI (standalone app, ports relevant code)
- Not a menu bar app (it's a floating overlay on the main screen)

### Core Principles
- **Self-contained**: All code lives in one Swift project. WeChat DB reading logic ported from the Python CLI, not dependent on it at runtime.
- **Whitelist-driven**: Only analyzes conversations the user explicitly adds. Ignores everything else.
- **AI-configurable**: User chooses their AI provider and model in settings.

## 2. Architecture

```
WeChatHUD.app
├── UI Layer (SwiftUI + AppKit)
│   └── FloatingPanel (NSPanel)
│       ├── CompactBar
│       ├── NotificationBanner
│       └── DetailPanel
│           ├── ChatListView
│           ├── AnalysisView
│           └── SettingsView
│
├── Service Layer
│   ├── ChatMonitor        — poll for new messages
│   ├── AIService          — configurable AI API calls
│   ├── WebSearchService   — online search integration
│   ├── ReportGenerator    — daily/weekly report creation
│   └── SmartClassifier    — whitelist recommendation engine
│
└── Data Layer
    ├── WeChatReader       — read encrypted WeChat DBs (ported from CLI)
    └── HUDStore           — app's own SQLite database
```

## 3. Data Layer

### 3.1 WeChatReader

Ported from the Python CLI's `core/` module into Swift. Reads WeChat's encrypted databases directly.

**Source data locations:**
- Keys: `~/.wechat-cli/all_keys.json`
- WeChat DBs: `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/**/db_storage/`
- Contact DB: `contact.db` (encrypted)
- Message DBs: `message_*.db` (encrypted, partitioned)

**Ported logic:**
- Key loading and DB decryption (SQLCipher-compatible, using CommonCrypto)
- Decrypted DB caching to temp directory with mtime verification
- Message table discovery: `Msg_{MD5_hash}` tables per chat
- Content parsing: XML payload extraction, zstd decompression
- Contact name resolution from contact.db
- Group membership queries from `chat_room` / `chatroom_member` tables
- Incremental message detection via `last_local_id` tracking

**Message type mapping (from CLI):**
```
text=1, image=3, voice=34, video=43, sticker=47,
location=48, link/appmsg=49, call=50, system=10000
```

**Key API surface in Swift:**
```swift
class WeChatReader {
    func loadKeys() throws -> [DBKey]
    func listChats() throws -> [ChatInfo]
    func getMessages(chat: String, since: Int?, limit: Int) throws -> [RawMessage]
    func getContacts() throws -> [String: String]  // username → displayName
    func getGroupMembers(chat: String) throws -> [MemberInfo]
    func searchMessages(query: String, chat: String?) throws -> [RawMessage]
    func getNewMessageCount(since lastCheck: [String: Int]) throws -> MessageDelta
}
```

### 3.2 HUDStore

App's own SQLite database at `~/.wechat-hud/hud.sqlite3`. Stores settings, whitelist, cached analysis, and reports.

```sql
-- Whitelist: contacts and groups the user wants to monitor
-- Each entry belongs to exactly one category (mutually exclusive)
CREATE TABLE whitelist (
    username        TEXT PRIMARY KEY,
    display_name    TEXT NOT NULL,
    is_group        BOOLEAN NOT NULL DEFAULT 0,
    category        TEXT NOT NULL CHECK(category IN ('work', 'life', 'other')),
    added_at        INTEGER NOT NULL,
    auto_suggested  BOOLEAN NOT NULL DEFAULT 0
);

-- AI recommendation queue: contacts not yet in whitelist
CREATE TABLE suggestions (
    username        TEXT PRIMARY KEY,
    display_name    TEXT NOT NULL,
    is_group        BOOLEAN NOT NULL DEFAULT 0,
    predicted_category TEXT NOT NULL,
    score           REAL NOT NULL,       -- relevance score
    reason          TEXT,                -- why suggested (JSON)
    suggested_at    INTEGER NOT NULL,
    dismissed_until INTEGER              -- NULL = active, timestamp = snoozed
);

-- Cached AI analysis results
CREATE TABLE analysis_cache (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_username   TEXT NOT NULL,
    analysis_type   TEXT NOT NULL,       -- summary, context, reply, todo, catchup, profile, find
    input_hash      TEXT NOT NULL,       -- hash of input messages for cache invalidation
    result          TEXT NOT NULL,       -- JSON payload
    created_at      INTEGER NOT NULL,
    expires_at      INTEGER NOT NULL,
    UNIQUE(chat_username, analysis_type, input_hash)
);

-- Generated reports
CREATE TABLE reports (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    report_type     TEXT NOT NULL,       -- daily, weekly
    category        TEXT,                -- work, life, other, NULL=all
    period_start    INTEGER NOT NULL,
    period_end      INTEGER NOT NULL,
    content         TEXT NOT NULL,       -- JSON: sections, items, summary
    created_at      INTEGER NOT NULL
);

-- App settings (key-value)
CREATE TABLE settings (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL        -- JSON
);

-- Sync progress per source table
CREATE TABLE sync_state (
    source_key      TEXT PRIMARY KEY,    -- e.g. "message_01.db/Msg_abc123"
    last_local_id   INTEGER NOT NULL DEFAULT 0,
    last_check_at   INTEGER NOT NULL DEFAULT 0
);
```

**Default settings keys:**
```json
{
    "ai.provider": "openai-compatible",
    "ai.base_url": "http://127.0.0.1:11434/v1",
    "ai.model": "qwen2.5:14b",
    "ai.api_key": "",
    "sync.interval_seconds": 30,
    "sync.wechat_db_path": "auto",
    "notification.at_mention": true,
    "notification.important": true,
    "notification.all_whitelist": false,
    "notification.duration_seconds": 3,
    "search.provider": "none",
    "search.api_key": ""
}
```

## 4. UI: Three-State Floating Panel

### 4.1 Window Configuration

- **Type**: `NSPanel` with style mask `.nonactivatingPanel`
- **Level**: `.floating` (stays above normal windows, below alerts)
- **Behavior**: `.canJoinAllSpaces` (visible on all virtual desktops)
- **Activation policy**: `.accessory` (no Dock icon)
- **Position**: Top-center of screen, below menu bar
- **Width**: CompactBar ~500px centered; DetailPanel ~700px centered
- **Background**: Dark semi-transparent with vibrancy (`NSVisualEffectView`, `.dark` appearance, material `.hudWindow`)

### 4.2 State Machine

```
                  mouse enter
    Compact ─────────────────────► Detail
       ▲                              │
       │         mouse exit           │
       ◄──────────────────────────────┘
       │
       │  new important message / @mention
       ▼
    Notification ──(duration expires)──► Compact
       │
       │  mouse enter
       ▼
    Detail
```

Transitions use SwiftUI `.spring(response: 0.3, dampingFraction: 0.8)` animation on panel height.

### 4.3 CompactBar (~36px height)

Always visible. Shows aggregate stats for whitelisted conversations only.

```
┌──────────────────────────────────────────────────────────┐
│  ●  5条未读   2条@   1条重要   │   同步: 刚刚   │   ⚙️  │
└──────────────────────────────────────────────────────────┘
```

- Green dot: connected and syncing normally
- Yellow dot: sync delayed (>5 min since last success)
- Red dot: sync error or DB not found
- Counts computed from whitelisted chats only
- "Important" detection rules (ordered by priority):
  1. Direct @mention to the user's WeChat username
  2. @all in a whitelisted group
  3. Direct reply to a message the user sent
  4. Message from a whitelisted contact in a private chat (implies expecting response)
  5. Keywords: 紧急, 尽快, ASAP, 马上, 立即, 截止, deadline
- "Needs reply" = important message where user hasn't sent a message in that chat since

### 4.4 NotificationBanner (~90px height)

Triggered when a new message arrives that is:
- An @mention to the user in a whitelisted group
- Flagged as important by heuristic rules

```
┌──────────────────────────────────────────────────────────┐
│  ●  5条未读   2条@   1条重要   │   同步: 刚刚   │   ⚙️  │
│ ┌──────────────────────────────────────────────────────┐ │
│ │  🔴 产品讨论群 · 张三@了你: "方案评审时间确认下"      │ │
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

- Auto-collapses back to Compact after `notification.duration_seconds` (default 3s)
- If mouse enters during notification, transitions to Detail instead of collapsing
- Multiple notifications queue; shows latest, with "+2 more" badge if stacked

### 4.5 DetailPanel (~500px height)

Triggered by mouse entering the compact/notification bar. Two-column layout.

**Left column (200px): Chat navigation**
```
筛选: [全部▾ | 工作 | 生活 | 其他]

@提到你 (3)
  产品讨论群         2分钟前
  项目进度群         15分钟前
  技术评审群         1小时前

需回复 (2)
  张三 "方案定了吗？"   10分钟前
  李四 "文件发我下"     30分钟前

最近活跃
  王五               刚刚
  赵六               5分钟前
  ...

──────────
🔍 搜索...
⚙️ 设置
```

- Sections sorted by urgency: @mentions > needs reply > recent activity
- Only shows whitelisted chats
- Selecting a chat loads the right panel
- Category filter tabs at top

**Right column (500px): Analysis panel**

Content depends on what's selected and context. Organized as a stack of cards:

**Card: Group Summary** (when a group chat is selected)
```
┌─────────────────────────────────────────────┐
│ 📋 群聊摘要 · 最近1小时              [刷新] │
│                                             │
│ 在讨论3个话题:                              │
│ 1. Q2预算分配 — 张三/李四主导,等你确认       │
│ 2. 客户A对接进度 — 王五在跟进               │
│ 3. 下周评审时间 — 投票中,已有5人回复         │
└─────────────────────────────────────────────┘
```

**Card: Context & Smart Reply** (when a "needs reply" message is selected)
```
┌─────────────────────────────────────────────┐
│ 💬 张三: "上次说的方案定了吗？"              │
│                                             │
│ 🔍 AI找到相关上下文:                        │
│ · 3天前你说"周五前给方案" (产品讨论群)       │
│ · 5天前讨论了A/B/C三个备选方案               │
│ · 昨天李四在项目群提到"方案已选B"            │
│                                             │
│ 💡 建议回复:                                │
│ "定了，选的B方案，我整理下细节今天发你"       │
│                        [复制] [编辑后复制]    │
└─────────────────────────────────────────────┘
```

**Card: Catch-up** (manual trigger from toolbar)
```
┌─────────────────────────────────────────────┐
│ 🕐 离开追赶 · 过去3小时         [调整时间▾] │
│                                             │
│ 🔴 需要你处理:                              │
│ · 产品讨论群: 张三@你确认方案评审时间         │
│ · 李四私聊: 等你发文件                       │
│                                             │
│ 📌 重要动态:                                │
│ · 项目进度群: 决定了用B方案,王五负责推进      │
│ · 技术评审群: 下周三评审时间确定              │
│                                             │
│ 💤 可以稍后看:                              │
│ · 家庭群: 在讨论周末安排                     │
└─────────────────────────────────────────────┘
```

**Card: Person Profile** (when clicking a contact)
```
┌─────────────────────────────────────────────┐
│ 👤 张三 · 工作                              │
│                                             │
│ 最近7天: 聊了45条消息, 3个群有交集           │
│ 上次沟通: 10分钟前                          │
│                                             │
│ 📌 待处理:                                  │
│ · 等你回复方案确认 (10分钟前)                │
│ · 你答应周五前给细节 (3天前)                 │
│                                             │
│ 📊 最近话题: Q2预算, 客户A对接, 评审安排     │
└─────────────────────────────────────────────┘
```

**Card: Report** (daily/weekly)
```
┌─────────────────────────────────────────────┐
│ 📊 日报 · 2026-04-11               [导出]  │
│                                             │
│ 今日工作对话摘要:                            │
│ · 产品讨论群: Q2预算方案确定为B方案...        │
│ · 项目进度群: 评审定在下周三...               │
│                                             │
│ 待跟进:                                     │
│ · 给张三发方案细节                           │
│ · 确认评审时间                               │
│                                             │
│ 明日预期:                                    │
│ · 客户A对接会议                              │
└─────────────────────────────────────────────┘
```

**Card: Quick Find** (search bar in left column or dedicated)
```
┌─────────────────────────────────────────────┐
│ 🔍 "他之前问的那个报价"                      │
│                                             │
│ AI找到3条相关消息:                           │
│ · 3天前 张三(产品群): "报价单发一下"         │
│ · 5天前 你→张三: "报价需要审批,下周给"       │
│ · 7天前 李四(项目群): "客户A要报价"          │
│                                    [查看更多]│
└─────────────────────────────────────────────┘
```

**Card: Web Search** (manual trigger)
```
┌─────────────────────────────────────────────┐
│ 🌐 联网搜索 · "Q2支付通道政策变化"           │
│                                             │
│ 搜索结果:                                    │
│ · [央行发布Q2支付通道新规] — 来源: xxx       │
│ · [2026年支付行业趋势分析] — 来源: xxx       │
│                                    [搜索更多]│
└─────────────────────────────────────────────┘
```

**Toolbar at top of right column:**
```
[群聊摘要] [待办] [追赶] [日报] [周报] [🔍搜索] [🌐联网]
```
Active card determined by selection + toolbar. Selecting a group chat auto-shows summary; selecting a "needs reply" message auto-shows context+reply.

## 5. AI Service

### 5.1 Provider Configuration

Supports any OpenAI-compatible API. Configured in settings.

```swift
struct AIConfig {
    var baseURL: String          // e.g. "http://127.0.0.1:11434/v1"
    var model: String            // e.g. "qwen2.5:14b"
    var apiKey: String           // optional, for remote providers
    var maxTokens: Int           // default 2048
    var temperature: Double      // default 0.3
}
```

### 5.2 AI Analysis Types

Each analysis type has a dedicated prompt template. Input is always structured context (messages with metadata), not raw text dumps.

| Type | Prompt Input | Output Format |
|------|-------------|---------------|
| `summary` | Recent N messages from group | Topics list with participants and status |
| `context` | Target message + sender's recent history | Related message chain with timeline |
| `reply` | Target message + context chain | 1-2 suggested replies |
| `catchup` | All whitelisted new messages since timestamp | Prioritized list (urgent/important/low) |
| `profile` | Contact's recent messages across chats | Activity summary + pending items |
| `find` | Natural language query + candidate messages from FTS | Ranked relevant messages |
| `daily` | Today's messages grouped by chat | Structured daily report |
| `weekly` | Week's messages + previous daily reports | Structured weekly report |
| `classify` | Contact's recent messages | Predicted category (work/life/other) + confidence |

### 5.3 Caching Strategy

- Analysis results cached in `analysis_cache` table
- Cache key: `(chat_username, analysis_type, input_hash)`
- `input_hash` = SHA256 of sorted message UIDs used as input
- TTL by type: summary=5min, context=30min, reply=10min, reports=6hr, classify=24hr
- New messages to a chat invalidate that chat's summary/context cache

### 5.4 Streaming

AI responses streamed via Server-Sent Events (SSE) to the UI. Cards show a typing indicator while streaming, then render the complete result.

## 6. Smart Classifier

### 6.1 Recommendation Logic

Runs after each sync cycle:

```
For each contact/group NOT in whitelist and NOT dismissed:
    1. Count messages in last 7 days → msg_7d
    2. Count messages in last 30 days → msg_30d
    3. Check if user replied to them → reply_rate
    4. Score = msg_7d * 0.4 + msg_30d * 0.2 + reply_rate * 0.3 + keyword_match * 0.1
    5. If score > threshold → add to suggestions table
    6. Predict category using keyword matching:
       - work keywords: 项目,进度,方案,会议,评审,需求,排期,上线...
       - life keywords: 吃饭,周末,旅游,快递,家,聚餐...
       - Default to "other" if unclear
    7. For uncertain cases, batch-call AI classify once daily
```

### 6.2 Smart Auto-Add

When a new contact/group appears (first message detected) AND meets urgency criteria:
- Direct @mention to user
- High-frequency burst (>10 messages in 1 hour)
- Contains keywords matching existing work patterns

Auto-add to suggestions with high priority. User still confirms, but it surfaces immediately.

## 7. Settings Panel

### 7.1 Structure

```
Settings
├── AI Configuration
│   ├── Provider type (OpenAI-compatible / custom)
│   ├── API endpoint URL
│   ├── Model name
│   ├── API key (optional, masked)
│   └── [Test Connection] button
│
├── Whitelist Management
│   ├── Category tabs: Work / Life / Other
│   │   └── Per-category: list of contacts/groups with remove button
│   │       └── [+ Add] opens contact picker
│   ├── AI Recommendations section
│   │   └── Cards with [Add to Work] [Add to Life] [Add to Other] [Dismiss]
│   └── Search/filter across all categories
│
├── Data & Sync
│   ├── WeChat data path (auto-detect or manual)
│   ├── Sync interval (15s / 30s / 60s / 5min)
│   ├── Last sync status and timestamp
│   └── [Sync Now] button
│
├── Notifications
│   ├── Toggle: @mentions trigger notification bar
│   ├── Toggle: important messages trigger notification bar
│   ├── Toggle: all whitelist messages trigger notification bar
│   └── Notification duration slider (1-10 seconds)
│
└── Web Search
    ├── Search provider (none / Tavily / SearXNG / custom)
    ├── API endpoint
    └── API key
```

### 7.2 Whitelist Rules

- Every contact/group belongs to exactly ONE category (mutually exclusive)
- Moving a contact to a different category removes it from the previous one
- Removing from whitelist moves to "unmonitored" — messages ignored for analysis
- Categories are fixed: work, life, other (not user-creatable for simplicity)
- Dismissing an AI recommendation snoozes it for 30 days

## 8. Report Generation

### 8.1 Daily Report

**Trigger**: Manual button, or auto-generate at configurable time (e.g. 18:00)

**Input**: Today's messages from whitelisted chats, grouped by category and chat

**Output structure**:
```json
{
    "date": "2026-04-11",
    "category_summaries": [
        {
            "category": "work",
            "summary": "...",
            "chats": [
                {
                    "chat_name": "产品讨论群",
                    "topics": ["Q2预算", "客户A对接"],
                    "key_decisions": ["选定B方案"],
                    "action_items": ["给张三发细节"]
                }
            ]
        }
    ],
    "pending_items": [...],
    "tomorrow_outlook": "..."
}
```

### 8.2 Weekly Report

**Trigger**: Manual button, or auto-generate on configurable day (e.g. Friday 17:00)

**Input**: Week's daily reports + raw messages for gap-filling

**Output**: Aggregated weekly summary with trends, completed items, carry-over items.

## 9. Web Search Integration

Configurable search backend for looking up information related to conversation topics.

**Supported providers:**
- None (disabled)
- Tavily API
- SearXNG (self-hosted)
- Custom OpenAI-compatible endpoint with function calling

**Usage flow:**
1. User clicks 🌐 on a conversation or types a search query
2. AI extracts key search terms from conversation context (or uses user query directly)
3. Search API returns results
4. Results displayed in a card in the analysis panel
5. Optionally: AI synthesizes search results with conversation context

## 10. Technical Details

### 10.1 Build Configuration

- **SPM** (Swift Package Manager), no Xcode project
- **Platform**: macOS 14.0+
- **Dependencies**: system sqlite3 only (linked via SPM)
- **Crypto**: CommonCrypto (system framework) for DB decryption
- **Compression**: Compression framework for zstd decompression
- **Networking**: URLSession for AI API and web search calls

### 10.2 File Structure

```
WeChatHUD/
├── Package.swift
├── Makefile
├── Resources/
│   └── Info.plist
└── Sources/WeChatHUD/
    ├── main.swift
    ├── App/
    │   ├── AppDelegate.swift
    │   ├── FloatingPanel.swift         -- NSPanel setup and state machine
    │   └── MouseTracker.swift          -- NSTrackingArea for hover detection
    ├── Views/
    │   ├── HUDRootView.swift           -- top-level SwiftUI view, state switching
    │   ├── CompactBarView.swift
    │   ├── NotificationBannerView.swift
    │   ├── DetailPanelView.swift
    │   ├── ChatListView.swift
    │   ├── AnalysisView.swift
    │   ├── Cards/
    │   │   ├── GroupSummaryCard.swift
    │   │   ├── ContextReplyCard.swift
    │   │   ├── CatchupCard.swift
    │   │   ├── PersonProfileCard.swift
    │   │   ├── ReportCard.swift
    │   │   ├── QuickFindCard.swift
    │   │   └── WebSearchCard.swift
    │   └── Settings/
    │       ├── SettingsView.swift
    │       ├── AISettingsView.swift
    │       ├── WhitelistView.swift
    │       ├── SyncSettingsView.swift
    │       └── NotificationSettingsView.swift
    ├── Services/
    │   ├── ChatMonitor.swift           -- timer-based new message polling
    │   ├── AIService.swift             -- OpenAI-compatible API client
    │   ├── WebSearchService.swift      -- configurable search provider
    │   ├── ReportGenerator.swift       -- daily/weekly report orchestration
    │   ├── SmartClassifier.swift       -- whitelist recommendation engine
    │   └── NotificationManager.swift   -- notification state queueing
    └── Data/
        ├── Models.swift                -- all data types
        ├── WeChatReader.swift          -- encrypted DB reading (ported from CLI)
        ├── WeChatDecryptor.swift       -- SQLCipher decryption logic
        ├── WeChatParser.swift          -- message content parsing (XML, zstd)
        ├── HUDStore.swift              -- app's own SQLite database
        └── CacheManager.swift          -- analysis cache with TTL
```

### 10.3 Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WeChatHUD</string>
    <key>CFBundleIdentifier</key>
    <string>com.wechat-cli.hud</string>
    <key>CFBundleName</key>
    <string>WeChat HUD</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

### 10.4 Thread Model

- **Main thread**: UI rendering (SwiftUI/AppKit)
- **Background queue**: `ChatMonitor` polling, DB reads, AI API calls
- Data flows from background to UI via `@Published` properties on `@MainActor` ObservableObject classes
- SQLite connections use WAL mode, one reader connection per background task

## 11. MVP Scope

### Phase 1: Foundation
- FloatingPanel with 3-state transitions
- WeChatReader (port DB reading from CLI)
- HUDStore (whitelist, settings, sync_state)
- CompactBar with real unread/@/important counts
- Settings: AI config, data path, sync interval

### Phase 2: Core AI
- Group summary card
- Context + smart reply card
- Quick find card
- Person profile card
- Notification banner for @mentions

### Phase 3: Reports & Classification
- Daily report generation
- Weekly report generation
- Smart classifier + recommendation UI
- Whitelist management with categories

### Phase 4: Extended
- Catch-up mode
- Web search integration
- Commitment tracking (cross-chat)
- Topic threading (cross-chat)
- Tone/urgency detection
- Date/deadline extraction
- File/link tracking
- Decision tracking
