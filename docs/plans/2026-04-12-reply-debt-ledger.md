# Reply Debt Ledger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a cross-chat reply debt ledger that tells the user who they currently owe a reply to, ranks those chats by risk, and surfaces the result directly in the WeChatHUD compact and hover-expanded UI, using a deterministic baseline plus optional local AI reranking through the user's OMLX OpenAI-compatible endpoint.

**Architecture:** Keep reply debt as a derived view, not a second unread system. A pure scoring service computes the baseline debt items from recent WeChat sessions plus recent messages, then an optional local AI judgment pass can suppress obvious false positives or rerank the top candidates using the existing OpenAI-compatible path. `ChatMonitor` publishes the ranked list during each scan, and the existing `chat_actions` table remains the single suppression mechanism for silence and snooze. The UI only needs a new stat plus a dedicated `待回` tab; settings UI can wait until after MVP.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, SQLite3, XCTest

---

## MVP Product Decisions

- Reply debt is **not** the same as WeChat unread.
  - A chat can have `unread_count == 0` and still be debt if the latest meaningful inbound message is newer than the user's latest outbound reply.
- Eligibility rules:
  - Private chat: eligible when `latestInbound > latestOutbound`.
  - Group chat: only eligible when the latest inbound is `@我`, contains an urgent keyword, or comes from a whitelisted chat with a clear action/question signal.
- Suppression rules:
  - Reuse `chat_actions`.
  - `silenced_at` hides debt up to that inbound timestamp.
  - `snoozed_until` hides the whole chat until expiry.
  - A strictly newer inbound message re-opens the debt automatically.
- Initial scan scope:
  - Use recent sessions from `session.db`.
  - Start with the most recent 100 sessions to keep scan cost bounded.
- Rollout order:
  - Phase A: deterministic baseline only.
  - Phase B: local AI shadow mode via the user's OMLX OpenAI-compatible endpoint.
  - Phase C: opt-in AI rerank/judge for the top deterministic candidates.
- Out of scope for this MVP:
  - AI-generated reply suggestions
  - Settings UI for thresholds
  - Detail panel redesign
  - Commitment extraction
  - Project lane aggregation

## User-Facing Shape

- Compact pill:
  - Keep the existing unread display.
  - Add a `待回` badge only when `replyDebtCount > 0`.
  - If the highest-ranked debt is `P0`, tint the badge amber/red.
- Hover-expanded panel:
  - Add a new top-level tab: `待回`.
  - If there is any `P0` or `P1` debt, default to `待回` for the current hover session.
  - Each row shows: chat name, latest inbound preview, relative time, 1-2 reason chips, priority color.
- Row actions:
  - Click: open WeChat chat
  - `Cmd`-click: copy preview
  - Context menu: open, copy, silence, snooze

## Scoring Rules

Create a deterministic score so the user can trust the ranking:

- Base signals:
  - `+5` group `@我`
  - `+4` private chat
  - `+3` whitelisted chat
  - `+3` urgent keyword (`紧急`, `尽快`, `ASAP`, `马上`, `立即`, `截止`, `deadline`)
  - `+2` explicit ask/question signal (`?`, `？`, `麻烦`, `请`, `帮忙`, `发我`, `确认`, `看看`)
  - `+1` WeChat unread count still > 0
  - `+1` two or more inbound messages since the user's last outbound
  - `+1` age passed threshold
- Thresholds:
  - private / normal chat overdue: 120 minutes
  - whitelisted chat overdue: 30 minutes
  - group `@我` overdue: 30 minutes
- Priority mapping:
  - `P0`: score >= 8
  - `P1`: score 5-7
  - `P2`: score < 5
- Reason chips:
  - `@你`
  - `私聊`
  - `白名单`
  - `紧急`
  - `未读`
  - `超时`
  - `连续催促`

## Hybrid Decision Boundary

Use deterministic logic for facts and local AI for semantic judgment:

- Deterministic only:
  - latest inbound / latest outbound ordering
  - whether the chat is private or group
  - whether the message contains `@我`
  - whether the chat is whitelisted
  - whether WeChat still shows unread
  - whether the chat is silenced or snoozed
  - age / overdue calculation
- Local AI only:
  - whether the inbound message really implies "the user owes a reply now"
  - whether a short acknowledgment already closes the obligation
  - whether an apparently urgent message is actually just broadcast noise
  - whether the top candidates should be reranked among the same risk band
- Never let AI overwrite facts:
  - AI cannot invent a newer outbound reply
  - AI cannot clear snooze or silence state
  - AI cannot create a debt candidate that deterministic recall did not surface

Design rule:

- Deterministic logic owns recall.
- Local AI only filters or reranks recalled candidates.
- On any AI failure, timeout, or invalid JSON, fall back to deterministic ordering unchanged.

## Local AI Integration (OMLX OpenAI-Compatible)

Assume the user runs a local OMLX server that exposes an OpenAI-compatible chat completions endpoint.

- Transport:
  - reuse the existing `AIService`
  - endpoint shape: `/v1/chat/completions`
  - request format: OpenAI-compatible `model + messages`
- New settings key:
  - `replyDebtAI`
- Proposed config:

```swift
struct ReplyDebtAIConfig: Codable {
    var enabled: Bool = false
    var shadowMode: Bool = true
    var maxCandidates: Int = 12
    var minRuleScore: Int = 4
    var requestTimeoutSeconds: Int = 20
}
```

- Candidate selection for AI:
  - only send the top `maxCandidates` deterministic candidates
  - only send candidates with `rule_score >= minRuleScore`
  - do not send the entire chat history; send a compact evidence window

Proposed input payload to the model:

```json
{
  "now_ts": 1712900000,
  "candidates": [
    {
      "chat_username": "wxid_alice",
      "chat_name": "Alice",
      "is_group": false,
      "is_whitelisted": true,
      "unread_count": 0,
      "rule_score": 7,
      "priority": "p1",
      "age_minutes": 44,
      "latest_inbound": "方案你定了吗？",
      "latest_outbound": "我晚上看下",
      "inbound_count_since_last_outbound": 2,
      "reason_codes": ["privateChat", "whitelisted", "repeatedInbound", "overdue"]
    }
  ]
}
```

Expected model output:

```json
{
  "judgments": [
    {
      "chat_username": "wxid_alice",
      "needs_reply": true,
      "priority_override": "keep",
      "confidence": "high",
      "ai_reason": "对方在追问明确事项，且你上次回复后又连续来了两条消息。"
    }
  ]
}
```

Output contract rules:

- `chat_username` must match one of the inputs exactly
- `needs_reply` is required
- `priority_override` must be one of `keep`, `p0`, `p1`, `p2`
- `confidence` must be one of `high`, `medium`, `low`
- `ai_reason` must be a short explanation, max 60 Chinese characters after trimming
- invalid rows are ignored, not partially applied

Application rules:

- `shadowMode == true`:
  - compute AI judgments
  - print diffs versus deterministic ranking
  - do not change the UI ordering
- `shadowMode == false`:
  - AI may suppress a candidate only when `needs_reply == false` and `confidence == high`
  - AI may override priority by at most one band
  - if AI says `keep`, retain the deterministic score/order

## Data Model

Add a first-class reply debt model in the Swift target:

```swift
enum ReplyDebtPriority: String, Codable {
    case p0, p1, p2
}

enum ReplyDebtReasonCode: String, Codable {
    case atMention, privateChat, whitelisted, urgentKeyword, askSignal, unread, overdue, repeatedInbound
}

struct ReplyDebtReason: Identifiable, Codable, Hashable {
    var id: String { code.rawValue }
    let code: ReplyDebtReasonCode
    let label: String
}

struct ReplyDebtItem: Identifiable {
    let id: String           // chatUsername
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String
    let timestamp: Date
    let priority: ReplyDebtPriority
    let score: Int
    let unreadCount: Int
    let isWhitelisted: Bool
    let isAtMention: Bool
    let reasons: [ReplyDebtReason]
}

struct ReplyDebtConfig: Codable {
    var maxSessions: Int = 100
    var normalOverdueMinutes: Int = 120
    var vipOverdueMinutes: Int = 30
    var groupAtOverdueMinutes: Int = 30
}

struct ReplyDebtAIConfig: Codable {
    var enabled: Bool = false
    var shadowMode: Bool = true
    var maxCandidates: Int = 12
    var minRuleScore: Int = 4
    var requestTimeoutSeconds: Int = 20
}
```

`HUDStats` also gets:

```swift
var replyDebtCount: Int = 0
```

## Task 1: Add Reply Debt Domain Types And Config

**Files:**
- Modify: `Sources/WeChatHUD/Data/Models.swift`
- Test: `Tests/WeChatHUDTests/HUDStoreTests.swift`

**Step 1: Write the failing tests**

Add a config round-trip test:

```swift
func testReplyDebtConfigRoundTrip() throws {
    let cfg = ReplyDebtConfig(maxSessions: 50, normalOverdueMinutes: 90, vipOverdueMinutes: 20, groupAtOverdueMinutes: 15)
    try store.setSettingJSON("replyDebt", value: cfg)
    let loaded = store.getSettingJSON("replyDebt", as: ReplyDebtConfig.self)
    XCTAssertEqual(loaded?.maxSessions, 50)
    XCTAssertEqual(loaded?.normalOverdueMinutes, 90)
    XCTAssertEqual(loaded?.vipOverdueMinutes, 20)
    XCTAssertEqual(loaded?.groupAtOverdueMinutes, 15)
}
```

Add an AI config round-trip test:

```swift
func testReplyDebtAIConfigRoundTrip() throws {
    let cfg = ReplyDebtAIConfig(enabled: true, shadowMode: true, maxCandidates: 8, minRuleScore: 5, requestTimeoutSeconds: 15)
    try store.setSettingJSON("replyDebtAI", value: cfg)
    let loaded = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self)
    XCTAssertEqual(loaded?.enabled, true)
    XCTAssertEqual(loaded?.shadowMode, true)
    XCTAssertEqual(loaded?.maxCandidates, 8)
    XCTAssertEqual(loaded?.minRuleScore, 5)
    XCTAssertEqual(loaded?.requestTimeoutSeconds, 15)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter HUDStoreTests/testReplyDebtConfigRoundTrip
```

Expected: compile failure because `ReplyDebtConfig` / `ReplyDebtAIConfig` do not exist yet.

**Step 3: Write minimal implementation**

- Add `ReplyDebtPriority`, `ReplyDebtReasonCode`, `ReplyDebtReason`, `ReplyDebtItem`, `ReplyDebtConfig`, `ReplyDebtAIConfig`.
- Extend `HUDStats` with `replyDebtCount`.

**Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter HUDStoreTests/testReplyDebtConfigRoundTrip
```

Expected: PASS.

**Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Data/Models.swift Tests/WeChatHUDTests/HUDStoreTests.swift
git commit -m "feat: add reply debt domain models"
```

## Task 2: Build A Pure Reply Debt Scorer

**Files:**
- Create: `Sources/WeChatHUD/Services/ReplyDebtScorer.swift`
- Test: `Tests/WeChatHUDTests/ReplyDebtScorerTests.swift`

**Step 1: Write the failing tests**

Create a focused unit test file with at least these cases:

```swift
func testPrivateChatWithoutReplyCreatesDebtEvenWhenRead()
func testLatestOutboundClearsDebt()
func testAtMentionGroupBeatsNormalPrivateChat()
func testSilencedDebtStaysHiddenUntilNewerInbound()
func testSnoozedDebtIsHiddenUntilExpiry()
```

Minimal test shape:

```swift
func testPrivateChatWithoutReplyCreatesDebtEvenWhenRead() {
    let item = ReplyDebtScorer.build(
        seeds: [makeSeed(unreadCount: 0, isGroup: false, latestInbound: 200, latestOutbound: 100)],
        config: ReplyDebtConfig()
    ).first

    XCTAssertEqual(item?.chatUsername, "alice")
    XCTAssertEqual(item?.priority, .p1)
    XCTAssertTrue(item?.reasons.contains(where: { $0.code == .privateChat }) == true)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ReplyDebtScorerTests
```

Expected: compile failure because `ReplyDebtScorer` does not exist.

**Step 3: Write minimal implementation**

Implement a pure scorer with no UI dependencies:

```swift
enum ReplyDebtScorer {
    struct Seed {
        let session: SessionInfo
        let chatName: String
        let isWhitelisted: Bool
        let latestInbound: MessageInfo?
        let latestOutbound: MessageInfo?
        let inboundCountSinceLastOutbound: Int
        let chatAction: HUDStore.ChatActionState?
        let now: Date
    }

    static func build(seeds: [Seed], config: ReplyDebtConfig) -> [ReplyDebtItem] { ... }
}
```

Rules inside the scorer:

- Skip if `latestInbound == nil`.
- Skip if `latestOutbound.createTime >= latestInbound.createTime`.
- Skip group chats unless they match one of the allowed eligibility rules.
- Respect `snoozed_until` and `silenced_at`.
- Emit stable reason chips from matched signals.
- Sort by `priority`, then `score`, then `timestamp`.

**Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ReplyDebtScorerTests
```

Expected: PASS.

**Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/ReplyDebtScorer.swift Tests/WeChatHUDTests/ReplyDebtScorerTests.swift
git commit -m "feat: add reply debt scorer"
```

## Task 3: Integrate Deterministic Reply Debt Into ChatMonitor

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`
- Modify: `Sources/WeChatHUD/Data/Models.swift`

**Step 1: Add the failing integration surface**

Introduce a new published property and wire stats usage so the compiler forces the rest of the integration:

```swift
@Published var replyDebtItems: [ReplyDebtItem] = []
```

Then update `ScanOutcome`:

```swift
let replyDebtItems: [ReplyDebtItem]
```

This should make `performScan` and the final apply block fail to compile until the field is threaded through.

**Step 2: Run build to verify it fails**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build
```

Expected: compiler errors about missing `replyDebtItems` population.

**Step 3: Implement the scan integration**

- Load `ReplyDebtConfig` from settings, falling back to defaults.
- Keep the current unread / VIP scan logic unchanged.
- Add a second pass over recent sessions:
  - start with `reader.getSessions().prefix(config.maxSessions)`
  - fetch recent messages per session with a bounded limit like `12`
  - derive `latestInbound`, `latestOutbound`, and `inboundCountSinceLastOutbound`
  - build seeds and call `ReplyDebtScorer.build`
- Set:

```swift
stats.replyDebtCount = replyDebtItems.count
```

- Publish `replyDebtItems` in the main-thread apply block.

Important guardrails:

- Do not make extra database passes for every message row if the latest 12 messages already decide the debt state.
- Do not mix reply debt with the existing unread list.
- Do not create a new persistence table for MVP.

**Step 4: Run build and tests**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test
```

Expected: full package PASS.

**Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/ChatMonitor.swift Sources/WeChatHUD/Data/Models.swift
git commit -m "feat: publish reply debt items from chat monitor"
```

## Task 4: Add Local AI Judge/Rerank Through OMLX

**Files:**
- Create: `Sources/WeChatHUD/Services/ReplyDebtJudge.swift`
- Modify: `Sources/WeChatHUD/Services/AIService.swift`
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`
- Test: `Tests/WeChatHUDTests/ReplyDebtJudgeTests.swift`

**Step 1: Write the failing tests**

Cover the judgment contract and fallback behavior:

```swift
func testJudgeBuildsCompactPayloadForTopCandidatesOnly()
func testJudgeIgnoresUnknownChatUsernamesInResponse()
func testJudgeFallsBackToDeterministicWhenJSONIsInvalid()
func testJudgeInShadowModeDoesNotMutateOrdering()
func testJudgeCanSuppressOnlyHighConfidenceFalsePositive()
```

Use a fake client rather than the network:

```swift
struct FakeReplyDebtLLMClient: ReplyDebtLLMClient {
    let response: String
    func complete(system: String, user: String) async throws -> String { response }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test --filter ReplyDebtJudgeTests
```

Expected: compile failure because `ReplyDebtJudge` does not exist.

**Step 3: Write minimal implementation**

Implement a small adapter around the existing OpenAI-compatible path:

```swift
protocol ReplyDebtLLMClient {
    func complete(system: String, user: String) async throws -> String
}

struct ReplyDebtJudge {
    func apply(
        to items: [ReplyDebtItem],
        config: ReplyDebtAIConfig,
        client: ReplyDebtLLMClient
    ) async -> [ReplyDebtItem] { ... }
}
```

Implementation requirements:

- Build a compact JSON payload from the top deterministic candidates only.
- Reuse `AIService` in production by conforming it to `ReplyDebtLLMClient`.
- Parse model output strictly and ignore invalid rows.
- In `shadowMode`, log the diff but return the original list unchanged.
- In active mode, only:
  - suppress `needs_reply == false && confidence == high`
  - or move `p1 -> p0`, `p2 -> p1`, `p1 -> p2` one band at a time
- On request failure, timeout, or parse failure, return the original list unchanged.

**Step 4: Integrate the judge into `ChatMonitor`**

- Load `ReplyDebtAIConfig` from settings.
- Run AI only when:
  - `enabled == true`
  - there are deterministic candidates
  - `AIService` is configured successfully
- Apply the AI pass after deterministic scoring and before publishing `replyDebtItems`.
- Never block the rest state forever:
  - if AI is slow, prefer a bounded timeout and publish deterministic results

**Step 5: Run full test suite**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test
```

Expected: PASS.

**Step 6: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Services/ReplyDebtJudge.swift Sources/WeChatHUD/Services/AIService.swift Sources/WeChatHUD/Services/ChatMonitor.swift Tests/WeChatHUDTests/ReplyDebtJudgeTests.swift
git commit -m "feat: add local ai rerank for reply debt"
```

## Task 5: Surface Reply Debt In The HUD

**Files:**
- Modify: `Sources/WeChatHUD/Views/CompactBarView.swift`
- Modify: `Sources/WeChatHUD/Views/ExtendedBarView.swift`
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift`
- Modify: `Sources/WeChatHUD/Views/HUDRootView.swift`

**Step 1: Start with compile-driven UI changes**

Add `replyDebtCount` reads to the compact and extended bars so the compiler points at every view that still assumes the old stats shape.

**Step 2: Implement the minimal UI**

- Compact pill:
  - Add a `bubble.left.and.bubble.right.fill` or `arrowshape.turn.up.left.fill`-style badge.
  - Show only when `stats.replyDebtCount > 0`.
- Extended bar:
  - Include `待回` in the summary strip when there are no tab contents.
- Extended tabs:
  - Add `case replyDebt`.
  - Show tab when `replyDebtItems` is non-empty.
  - Default to `.replyDebt` when there is any `P0` or `P1` item.
  - Add a dedicated row renderer with:

```swift
chat name | preview | reason chips | relative time
```

- Reuse existing row actions:
  - click -> `WeChatLauncher.openChat`
  - `Cmd`-click -> copy
  - context menu -> open, copy, silence, snooze

**Step 3: Update layout sizing**

`extendedTabsSize(...)` must consider the largest of:

- VIP rows
- unread rows
- reply debt rows

so the panel height tracks whichever tab is tallest.

**Step 4: Run build and manual smoke check**

Run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift build
```

Then run:

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && make app && open .build/WeChatHUD.app
```

Manual smoke checks:

- unread-only account still behaves exactly as before
- a read-but-unreplied private chat appears in `待回`
- silencing a debt hides it until a newer inbound arrives
- snoozing a debt hides it until expiry
- clicking a debt row opens WeChat on the first click
- when AI shadow mode is on, the UI still matches deterministic ordering
- when AI active mode is on, only the top candidates can change

**Step 5: Commit**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD
git add Sources/WeChatHUD/Views/CompactBarView.swift Sources/WeChatHUD/Views/ExtendedBarView.swift Sources/WeChatHUD/Views/ExtendedTabsView.swift Sources/WeChatHUD/Views/HUDRootView.swift
git commit -m "feat: surface reply debt in hud"
```

## Acceptance Criteria

- A private chat can appear in `待回` even when WeChat unread count is zero.
- A chat disappears from `待回` immediately after the user's newer outbound message is seen.
- Group chats do not flood the list unless they are `@我`, urgent, or whitelisted + actionable.
- Silence and snooze work identically for reply debt and unread triage.
- Compact pill shows a stable `待回` count.
- Hover-expanded panel shows a readable ranked `待回` list.
- With AI disabled, behavior is fully deterministic.
- With AI enabled but failing, behavior falls back to the deterministic list unchanged.
- With AI enabled in shadow mode, logs capture rule-vs-AI differences without affecting UI.
- Full `swift test` passes.

## Effectiveness And Rollout

Do not trust the AI path by default. Promote it only after proving it helps.

- Build a small labeled set:
  - at least 100 candidate chats
  - label each as `needs_reply` / `not_needed`
  - record whether the deterministic priority feels too high / too low
- Evaluate deterministic baseline first:
  - `Top-5 precision`
  - false-positive themes
  - false-negative themes
- Run AI in `shadowMode` for at least one week:
  - compare AI suppressions against what the user actually replied to later
  - review all places where AI would have hidden a deterministic `P0` or `P1`
- Promotion gate for active mode:
  - no obvious high-confidence false suppressions in the review set
  - top-5 precision is better than or equal to deterministic baseline
  - user confirms the AI reasons read as sensible rather than generic
- Keep a rollback switch:
  - `replyDebtAI.enabled = false` immediately restores deterministic behavior

## Implementation Notes

- If `reader.getSessions()` turns out to return too small a subset, expand `WeChatReader` first rather than adding ad hoc direct SQLite reads in `ChatMonitor`.
- Keep deterministic recall authoritative even after AI ships. The user should still be able to understand why an item entered the list before AI reranking.
- The local OMLX model is only useful if it returns stable JSON. Validate strictly and bias toward dropping invalid AI output rather than trying to repair it.
- Once this ships, the next feature should be `承诺账本`, because it can reuse the same per-chat message window and suppression semantics.
