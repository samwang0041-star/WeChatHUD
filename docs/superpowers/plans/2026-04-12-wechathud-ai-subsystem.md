# WeChatHUD AI 子系统 — Design Doc

> **Status:** Foundation phase. This is a design + implementation plan for the AI infrastructure that will underpin features #4 (keywords), #5 (commitment tracking), the new "decision queue" core, and end-of-day retrospective.
>
> **Author note:** Earlier feature plans (#4 keywords as a standalone) are superseded by this. The keyword tab will be a degenerate case of the ask classifier ("keyword-only mode") rather than a separate scanner.

---

## Why this exists

The previous proposal for "ranked compact pill / live activities / commitment tracker / retrospective" relies on **semantic** understanding of WeChat messages. Pure rules (regex, timestamps, counters) can build the chrome but cannot decide the *meaning* of a message — and meaning is what makes the difference between a notification badge and a co-pilot.

Concretely, four pieces of value are unreachable without an LLM:

1. **What is the sender asking me to do?** (ask extraction)
2. **Is this message a commitment, and by whom toward whom?** (commitment detection)
3. **Of all pending things, what should the user see right now?** (prioritization)
4. **What's a useful one-paragraph summary of today?** (retrospective)

This document specifies the AI subsystem that delivers all four, plus the engineering guardrails that keep it from becoming a black-box embarrassment.

---

## Non-goals

- **No cloud calls.** Everything runs against the user's local MLX OpenAI-compatible endpoint. The existing `AIService` already supports this — we extend it, not replace it.
- **No streaming.** Classification responses are short JSON. Streaming complicates parsing for no benefit.
- **No fine-tuning.** Prompt + few-shot only. If quality plateaus, we revisit.
- **No new permission prompts.** All AI work is local HTTP, no entitlements needed.
- **Not a chatbot.** No free-form conversational interface. AI is invisible plumbing.

---

## Architecture overview

```
                    ┌──────────────────────────────┐
                    │     ChatMonitor.scan()       │
                    │   (existing, off-main)       │
                    └──────────────┬───────────────┘
                                   │
                                   │ new whitelist/VIP messages
                                   ▼
                ┌────────────────────────────────────┐
                │       AIClassifier.classify()      │  ← Role 1 (small, hot)
                │   per-message ask extraction       │     200-400ms each
                │   model: 1.5B-3B class             │
                └────────┬───────────────────────────┘
                         │
                         │ {is_ask, type, summary,
                         │  deadline_relative, confidence}
                         ▼
                ┌────────────────────────────────────┐
                │           HUDStore                 │
                │  ┌──────────────────────────────┐  │
                │  │ pending_asks                 │  │
                │  │ ai_audit  (every call)       │  │
                │  │ ai_feedback (user signals)   │  │
                │  └──────────────────────────────┘  │
                └────────┬───────────────────────────┘
                         │
              ┌──────────┴──────────────┐
              │                         │
              ▼                         ▼
    ┌──────────────────┐    ┌──────────────────────┐
    │ AIRanker         │    │  ExtendedTabsView    │
    │ (Role 2)         │    │  待决 / 承诺 tabs    │
    │ 7B, every 5min   │    │  (renders pending)   │
    │ → headline       │    └──────────────────────┘
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │ Compact pill     │
    │ "P1 林总等38m"   │
    └──────────────────┘

    ┌────────────────────────────────────┐
    │       AIRetrospector (Role 3)      │  ← Role 3 (cold, daily)
    │   14B, fired at 17:45              │
    │   → today's report + tomorrow plan │
    └────────────────────────────────────┘
```

### Three AI roles

| Role | Model | Frequency | Purpose | Latency budget |
|------|-------|-----------|---------|---------------|
| **1. Classifier** | `Qwen3.5-35B-A3B-4bit` | Per new whitelist msg (~100-300/day) | Extract ask metadata | < 800ms |
| **2. Ranker** | `Qwen3.5-35B-A3B-4bit` | Every 5 min OR on new P0 ask | Pick the headline for compact pill | < 3s |
| **3. Retrospector** | `Qwen3.5-35B-A3B-4bit` | Once daily at 17:45 | Generate end-of-day report | < 60s |

> **Phase 0 model strategy:** all three roles share the user's single loaded model `Qwen3.5-35B-A3B-4bit` (35B total / ~3B active MoE, 4-bit quantized). The role abstraction matters more than the model split — splitting can come later if cost analysis shows it's needed. With ~3B active parameters on Apple Silicon, per-call latency should land around 300-700ms for short JSON responses, comfortably inside the classifier budget.

---

## The five gates (quality assurance)

This is the part that distinguishes "AI shipped responsibly" from "vibes-based AI feature." All five must exist before AI output is allowed to drive the compact pill.

### Gate 1: Offline labeled test set
- File: `Tests/Fixtures/labeled_messages.json`
- Format:
  ```json
  [
    {
      "msg_id": "test-001",
      "text": "明天上午把预算单发给我",
      "sender_name": "林总",
      "chat_kind": "private",
      "expected": {
        "is_ask": true,
        "type": "send_file",
        "summary": "把预算单发给林总",
        "deadline_relative": "+1d"
      }
    },
    ...
  ]
  ```
- Goal: 200 hand-labeled samples covering all `type` values plus negatives
- Test runner: `Tests/AIClassifierTests.swift` runs every fixture through the classifier and computes precision / recall / F1 on `is_ask` and `type`
- **Hard gate:** `swift test` fails if F1 < 0.85
- This exists from day 1 even if empty; we add cases over time

### Gate 2: Confidence-based three-bucket dispatch
- Classifier output includes `confidence: 0.0-1.0`
- Routing:
  - `>= 0.85` → main "待决" list, fully visible
  - `0.5 - 0.85` → "待审" sub-list, collapsed by default, user opts to expand
  - `< 0.5` → discarded (silently dropped, NOT shown)
- Bias: prefer false negatives over false positives. A missed ask costs the user one trip back to WeChat. A false-positive ask costs trust in the whole system.

### Gate 3: User feedback loop
- Each ask row has two latent signals:
  - User clicked "处理了" (✓) → implicit positive
  - User clicked "不是 ask" (✗) → explicit negative
- Both written to `ai_feedback` table with the original input + original AI output
- Weekly review script (manual for now): list the top 20 worst false-positives and worst false-negatives, use to refine prompt or expand fixture

### Gate 4: Full audit log
- Every AI call (all three roles) writes a row to `ai_audit`:
  ```sql
  CREATE TABLE ai_audit (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      ts            INTEGER NOT NULL,        -- unix seconds
      role          TEXT NOT NULL,           -- 'classifier' | 'ranker' | 'retrospector'
      model         TEXT NOT NULL,           -- model name as sent
      prompt_ver    TEXT NOT NULL,           -- 'classifier_v1' etc
      input_text    TEXT NOT NULL,           -- the user content
      output_text   TEXT NOT NULL,           -- raw model output
      latency_ms    INTEGER NOT NULL,
      status        TEXT NOT NULL,           -- 'ok' | 'parse_error' | 'http_error' | 'timeout'
      error_msg     TEXT
  )
  ```
- Retention: 14 days, auto-prune on `HUDStore.open()`
- Use case: when something feels wrong, the user (or me) can grep the log and see exactly what the model was given and what came back

### Gate 5: Versioned prompts on disk
- Prompts live in `Resources/prompts/` not in Swift source
- Filename encodes version: `classifier_v1.txt`, `classifier_v2.txt`
- Loaded at startup via `Bundle.module.path(forResource:ofType:)` (need to update Package.swift to declare resources)
- Each `pending_asks` row records `prompt_version` so you know which version produced it
- Bumping versions is a deliberate, git-tracked act

---

## Data layer additions

### Table: pending_asks

```sql
CREATE TABLE IF NOT EXISTS pending_asks (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    msg_uid           TEXT UNIQUE NOT NULL,    -- WeChat msg UID, dedup key
    chat_username     TEXT NOT NULL,
    chat_name         TEXT NOT NULL,
    sender_name       TEXT NOT NULL,
    raw_text          TEXT NOT NULL,           -- original message body
    summary           TEXT NOT NULL,           -- AI-extracted ask summary
    ask_type          TEXT NOT NULL,           -- 'yes_no' | 'send_file' | 'review' | 'decide' | 'info' | 'none'
    deadline_at       INTEGER,                 -- unix seconds, nullable
    confidence        REAL NOT NULL,           -- 0-1
    bucket            TEXT NOT NULL,           -- 'main' | 'review'
    status            TEXT NOT NULL,           -- 'pending' | 'done' | 'dismissed'
    prompt_version    TEXT NOT NULL,
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_asks_status ON pending_asks(status, deadline_at);
```

### Table: ai_audit

(see Gate 4 above)

### Table: ai_feedback

```sql
CREATE TABLE IF NOT EXISTS ai_feedback (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    msg_uid         TEXT NOT NULL,
    feedback_type   TEXT NOT NULL,           -- 'true_positive' | 'false_positive' | 'true_negative' | 'false_negative'
    original_output TEXT NOT NULL,           -- the JSON the AI produced
    user_action     TEXT,                    -- 'marked_done' | 'marked_not_ask' | 'edited_summary'
    note            TEXT
);
```

### HUDStore methods to add

```swift
// pending_asks
func upsertPendingAsk(_ ask: PendingAsk)
func loadPendingAsks(bucket: String?, status: String?) -> [PendingAsk]
func updatePendingAskStatus(msgUID: String, status: String)
func dismissPendingAsk(msgUID: String)

// ai_audit
func writeAIAudit(_ entry: AIAuditEntry)
func loadRecentAIAudit(limit: Int) -> [AIAuditEntry]
func pruneAIAudit(olderThanDays: Int)

// ai_feedback
func writeAIFeedback(_ entry: AIFeedbackEntry)
func loadAIFeedback(limit: Int) -> [AIFeedbackEntry]
```

---

## AIClassifier service

### File: `Sources/WeChatHUD/Services/AIClassifier.swift`

Independent actor. Reuses `AIService.complete(system:, user:)` for the HTTP call but owns its own config, prompt loading, JSON parsing, and audit logging.

```swift
actor AIClassifier {
    private let aiService: AIService
    private let store: HUDStore
    private var config: AIClassifierConfig
    private let promptLoader: PromptLoader

    init(aiService: AIService, store: HUDStore, config: AIClassifierConfig)

    /// Classify a single message. Returns nil on irrecoverable failure
    /// (parse error after retry, HTTP timeout) — caller treats nil as
    /// "skip this message, will retry next scan."
    func classify(message: ClassifierInput) async -> ClassifierResult?
}

struct AIClassifierConfig: Codable {
    var baseURL: String = "http://127.0.0.1:8080/v1"   // MLX server default
    var model: String = "Qwen3.5-35B-A3B-4bit"         // user's currently-loaded MLX model
    var temperature: Double = 0.1
    var maxTokens: Int = 256
    var promptVersion: String = "classifier_v1"
}

struct ClassifierInput {
    let msgUID: String
    let text: String
    let senderName: String
    let chatName: String
    let isGroup: Bool
}

struct ClassifierResult {
    let isAsk: Bool
    let type: AskType
    let summary: String
    let deadlineRelative: String?    // "+2h", "+1d", null
    let confidence: Double
    let promptVersion: String
}

enum AskType: String, Codable {
    case yesNo = "yes_no"
    case sendFile = "send_file"
    case review
    case decide
    case info
    case none
}
```

### Classify flow

1. Build the user prompt via `PromptLoader.load(version: config.promptVersion)` + interpolated `{message_body}` etc
2. Call `aiService.complete(system:, user:)` with `temperature=0.1` (overriding the default), `maxTokens=256`
3. Strip markdown code fences (` ```json ... ``` `) from the response — MLX/Qwen often wrap output even when told not to
4. Try `JSONDecoder().decode(ClassifierResultDTO.self, from:)`
5. On parse failure: **retry once** with an appended user message: `"Output ONLY a JSON object, no prose, no code fences."`
6. On second parse failure: write to `ai_audit` with `status = parse_error`, return nil
7. On success: write to `ai_audit` with `status = ok`, return `ClassifierResult`
8. Translate `deadline_relative` ("+2h", "+1d") → absolute unix timestamp at the call site (not in the classifier — keeps it pure)

### Prompt loading

```swift
final class PromptLoader {
    private var cache: [String: String] = [:]

    func load(version: String) throws -> String {
        if let cached = cache[version] { return cached }
        guard let url = Bundle.module.url(forResource: version, withExtension: "txt", subdirectory: "prompts") else {
            throw PromptError.notFound(version)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        cache[version] = text
        return text
    }
}
```

`Package.swift` needs:
```swift
.executableTarget(
    name: "WeChatHUD",
    resources: [
        .copy("Resources/prompts")
    ],
    ...
)
```

---

## The classifier_v1 prompt

### File: `Resources/prompts/classifier_v1.txt`

```
你是一个微信消息分类器。任务：判断这条消息是不是在向接收者**请求一个动作**，如果是，提取动作摘要、类型和截止时间。

输出**必须**是单个 JSON 对象，**不要**包含任何 markdown 代码围栏、解释或前后文本。

JSON schema:
{
  "is_ask": boolean,           // 是否在请求接收者做某事
  "type": string,              // "yes_no" | "send_file" | "review" | "decide" | "info" | "none"
  "summary": string,           // 一句话动作摘要，最多 20 字。is_ask=false 时为空字符串
  "deadline_relative": string, // 截止时间相对值："+30m" "+2h" "+1d" "+1w" 或 null
  "confidence": number         // 0.0-1.0，对自己判断的把握
}

类型定义：
- yes_no:    需要接收者回答是/否、确认/拒绝
- send_file: 需要接收者发送文件、链接、资料、信息
- review:    需要接收者审核、查看、批准内容
- decide:    需要接收者在多个选项中做决定
- info:      需要接收者提供某个信息（不是文件）
- none:      不是请求（陈述、问候、闲聊、抱怨等）

判断要点：
1. 接收者是 "你"，发送者是消息里的对方。
2. 只有当对方明确希望你做点什么时才算 ask。"我刚才发了报告" 不是 ask；"看一下我刚发的报告" 是 review。
3. 如果消息是对方在描述自己要做的事（"我下午发你"），那不是 ask 给你的，is_ask=false。
4. 群消息只有在明确 @ 你 或者上下文显然指向你时才算 ask。
5. 截止时间从消息里抽取相对值。"明天" → "+1d"；"下午" → "+4h"；"等下" → "+30m"；没说 → null。
6. 不确定就降低 confidence。宁可漏判也不要误报。

few-shot 例子：

输入: "明天上午把预算单发给我"
输出: {"is_ask":true,"type":"send_file","summary":"发送预算单","deadline_relative":"+1d","confidence":0.95}

输入: "好的，我下午处理"
输出: {"is_ask":false,"type":"none","summary":"","deadline_relative":null,"confidence":0.9}

输入: "周三还是周四开会比较好？"
输出: {"is_ask":true,"type":"decide","summary":"决定周三还是周四开会","deadline_relative":null,"confidence":0.92}

输入: "刚发的稿子帮看一下"
输出: {"is_ask":true,"type":"review","summary":"审核稿子","deadline_relative":null,"confidence":0.88}

输入: "你那边客户的预算批了吗"
输出: {"is_ask":true,"type":"yes_no","summary":"确认客户预算是否批了","deadline_relative":null,"confidence":0.9}

输入: "今天天气真好"
输出: {"is_ask":false,"type":"none","summary":"","deadline_relative":null,"confidence":0.98}

输入: "[图片]"
输出: {"is_ask":false,"type":"none","summary":"","deadline_relative":null,"confidence":0.7}

现在分类下面这条消息：

发送者: {sender_name}
聊天: {chat_name}（{chat_kind}）
消息: {message_body}

只输出 JSON，不要任何其它文字。
```

`{chat_kind}` is `"私聊"` or `"群聊"`. Variables interpolated by `AIClassifier.classify` before calling `complete()`.

---

## Test harness

### `Tests/WeChatHUDTests/AIClassifierTests.swift`

```swift
import XCTest
@testable import WeChatHUD

final class AIClassifierTests: XCTestCase {
    /// End-to-end against the live MLX endpoint. Skipped if endpoint
    /// not reachable so CI can still run unit tests.
    func testClassifierAgainstFixtures() async throws {
        guard await isMLXEndpointReachable() else {
            throw XCTSkip("MLX endpoint not reachable; skipping live classifier test")
        }

        let fixturesURL = Bundle.module.url(forResource: "labeled_messages", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: fixturesURL)
        let cases = try JSONDecoder().decode([LabeledCase].self, from: data)

        guard cases.count >= 20 else {
            throw XCTSkip("Fixture has < 20 cases; skipping until test set is built up")
        }

        let store = try makeTestStore()
        let aiService = AIService(config: .init())
        let classifier = AIClassifier(aiService: aiService, store: store, config: .init())

        var tp = 0, fp = 0, fn = 0, tn = 0
        for c in cases {
            guard let result = await classifier.classify(message: .init(
                msgUID: c.msgID, text: c.text, senderName: c.senderName,
                chatName: "test", isGroup: c.chatKind == "group"
            )) else { continue }

            switch (c.expected.isAsk, result.isAsk) {
            case (true, true):   tp += 1
            case (false, false): tn += 1
            case (true, false):  fn += 1
            case (false, true):  fp += 1
            }
        }

        let precision = Double(tp) / Double(tp + fp)
        let recall    = Double(tp) / Double(tp + fn)
        let f1        = 2 * precision * recall / (precision + recall)

        print("Classifier metrics: P=\(precision) R=\(recall) F1=\(f1) (n=\(cases.count))")
        XCTAssertGreaterThanOrEqual(f1, 0.85, "Classifier F1 below threshold")
    }
}
```

### `Tests/Fixtures/labeled_messages.json`

Start with the few-shot examples from the prompt as the seed:

```json
[
  {"msg_id": "seed-001", "text": "明天上午把预算单发给我", "sender_name": "林总", "chat_kind": "private",
   "expected": {"is_ask": true, "type": "send_file", "summary": "发送预算单", "deadline_relative": "+1d"}},
  {"msg_id": "seed-002", "text": "好的，我下午处理", "sender_name": "张姐", "chat_kind": "private",
   "expected": {"is_ask": false, "type": "none", "summary": "", "deadline_relative": null}},
  {"msg_id": "seed-003", "text": "周三还是周四开会比较好？", "sender_name": "王经理", "chat_kind": "private",
   "expected": {"is_ask": true, "type": "decide", "summary": "决定开会日期", "deadline_relative": null}},
  {"msg_id": "seed-004", "text": "刚发的稿子帮看一下", "sender_name": "小李", "chat_kind": "private",
   "expected": {"is_ask": true, "type": "review", "summary": "审核稿子", "deadline_relative": null}},
  {"msg_id": "seed-005", "text": "你那边客户的预算批了吗", "sender_name": "老周", "chat_kind": "private",
   "expected": {"is_ask": true, "type": "yes_no", "summary": "确认客户预算", "deadline_relative": null}},
  {"msg_id": "seed-006", "text": "今天天气真好", "sender_name": "同事", "chat_kind": "private",
   "expected": {"is_ask": false, "type": "none", "summary": "", "deadline_relative": null}},
  {"msg_id": "seed-007", "text": "[图片]", "sender_name": "未知", "chat_kind": "private",
   "expected": {"is_ask": false, "type": "none", "summary": "", "deadline_relative": null}}
]
```

User-grown to 200 cases over time. Below 20 the test self-skips with a warning.

---

## Manual test CLI

A subcommand of the main binary that bypasses the GUI for prompt iteration:

```bash
.build/debug/WeChatHUD classify "明天把预算单发给我" --sender 林总
# →  {"is_ask":true,"type":"send_file","summary":"发送预算单","deadline_relative":"+1d","confidence":0.95}
#    [latency: 312ms, model: qwen2.5-1.5b-instruct, prompt: classifier_v1]

.build/debug/WeChatHUD classify-fixture
# →  Runs all fixture cases, prints per-case result + final P/R/F1
```

Implementation: in `main.swift`, before `NSApplication.shared.run()`, check `CommandLine.arguments`:

```swift
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "classify" {
    let text = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
    Task {
        let store = HUDStore()
        try? store.open()
        let ai = AIService(config: store.getSettingJSON("ai", as: AIConfig.self) ?? .init())
        let cls = AIClassifier(aiService: ai, store: store, config: store.getSettingJSON("classifier", as: AIClassifierConfig.self) ?? .init())
        let result = await cls.classify(message: .init(
            msgUID: "cli", text: text, senderName: "<cli>", chatName: "<cli>", isGroup: false
        ))
        print(result.map { "\($0)" } ?? "<nil>")
        exit(0)
    }
    RunLoop.main.run()
}
```

---

## Implementation order (this is the plan codex / I will execute)

> **Phase 0 — foundation only.** No UI changes in this phase. We're building the AI substrate so later features stand on something solid.

### Task 1: HUDStore schema additions
- File: `Sources/WeChatHUD/Data/HUDStore.swift`
- Add `pending_asks`, `ai_audit`, `ai_feedback` tables
- Add CRUD methods listed above
- Wire `pruneAIAudit(olderThanDays: 14)` into `open()`

### Task 2: Models for AI types
- File: `Sources/WeChatHUD/Data/Models.swift`
- Add `AIClassifierConfig`, `ClassifierInput`, `ClassifierResult`, `AskType`, `PendingAsk`, `AIAuditEntry`, `AIFeedbackEntry`

### Task 3: Prompt loader + Resources wiring
- New file: `Sources/WeChatHUD/Services/PromptLoader.swift`
- Create directory: `Sources/WeChatHUD/Resources/prompts/`
- Add `classifier_v1.txt` (content above)
- Update `Package.swift` to include `resources: [.copy("Resources/prompts")]` on the executable target — note this will need a folder rename or path adjustment because the existing target may not have a `Resources` subdirectory under `Sources/WeChatHUD/`

### Task 4: AIClassifier service
- New file: `Sources/WeChatHUD/Services/AIClassifier.swift`
- Implement the actor as specified above
- Includes: prompt interpolation, retry-once on parse error, audit log writes, JSON cleanup (strip code fences)

### Task 5: Test fixture + harness
- New: `Tests/Fixtures/labeled_messages.json` with the 7 seed cases
- New: `Tests/WeChatHUDTests/AIClassifierTests.swift` with the harness above
- The test self-skips if endpoint unreachable or fixture < 20 cases

### Task 6: CLI subcommand
- Edit `Sources/WeChatHUD/main.swift` to handle `classify <text>` and `classify-fixture` before launching the app

### Task 7: Smoke test against live MLX
- Build: `swift build`
- Manual: `.build/debug/WeChatHUD classify "明天把预算单发给我"` should print parsed JSON with `is_ask: true`
- Manual: try 5-10 of your own real WeChat messages by hand, write down results, sanity-check
- Adjust prompt if obviously wrong patterns appear

### Task 8: Document handoff
- Append a "current state + next phase" note to this doc once Phase 0 ships

> **Out of scope for Phase 0** (will be Phase 1+):
> - Wiring classifier into `ChatMonitor.scan` (will replace the keyword pass)
> - "待决" tab UI in ExtendedTabsView
> - AIRanker (Role 2) for compact pill headline
> - AIRetrospector (Role 3) for end-of-day report
> - Settings UI for `AIClassifierConfig`

---

## Open questions to resolve before Task 4

1. **MLX endpoint URL** — assuming `http://127.0.0.1:8080/v1` (mlx_lm.server default). User to confirm or correct on first failed call.
2. ~~**Loaded model name**~~ — **resolved**: `Qwen3.5-35B-A3B-4bit` (single shared model for all three roles in Phase 0).
3. **Resources directory layout** — the existing `Resources/Info.plist` lives at the repo root, not under `Sources/WeChatHUD/`. SPM resource bundles need files under the target's source directory. Plan: create `Sources/WeChatHUD/Resources/prompts/` for prompts (separate from the root `Resources/` which is only used for Info.plist via linker flag) and add `resources: [.copy("Resources/prompts")]` to the SPM target. Verify the path works at first build.

---

## Success criteria for Phase 0

Phase 0 is "done" when all of these are true:

- [ ] `swift build` produces a binary
- [ ] `swift test` passes (with classifier test self-skipping if fixture < 20)
- [ ] `.build/debug/WeChatHUD classify "明天把预算单发给我"` prints valid `ClassifierResult` JSON in < 1s
- [ ] `~/.wechat-hud/hud.sqlite3` has `pending_asks`, `ai_audit`, `ai_feedback` tables
- [ ] After running 10 manual classify calls, `ai_audit` table has 10 rows with non-null latency
- [ ] At least 20 hand-labeled cases exist in `labeled_messages.json` and the test runs them through the classifier successfully (F1 metric printed even if below 0.85)

When all six are checked, we move to Phase 1: wire it into `ChatMonitor` and build the "待决" tab.
