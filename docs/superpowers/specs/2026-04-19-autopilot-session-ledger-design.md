# Autopilot Session Ledger + Prompt v3 — Design Spec

**Date:** 2026-04-19
**Author:** brainstormed with user
**Status:** approved — proceed to implementation

## Problem

Autopilot replies pass the "single message" smell test but collapse on conversational continuity:

1. **No short-term memory of own output.** The model sees `ConversationMemory` (rolling summary) + recent peer messages, but not "here's exactly what autopilot told the peer 15 minutes ago". Easy to contradict yourself within one session.
2. **Prompt tuned for Qwen.** `autopilot_reply_v2.txt` is instruction-dense (13 numbered rules) and was designed for a local 35B model that needed heavy steering. With gpt-5.4 via Codex, the same style is fighting the model rather than trusting it.
3. **Peer-triggered recall is lossy.** If the user's last autopilot reply said "我晚上 8 点给你打电话" and the peer 30 min later says "记得打哦", the model has no durable reference to "I already committed to call at 8" — only a possibly-stale memory summary.

User scope narrowed to: **(a) contextual coherence within an autopilot session, (b) reply text that doesn't read as obviously AI.**

## Goal

Ship two tightly scoped changes in one go:

1. A session-scoped ledger of outgoing messages that's injected into every autopilot reply's prompt, so the model can honor its own prior claims and echo back naturally ("对，刚说了 8 点").
2. A prompt v3 template tuned for gpt-5.4 — shorter, trusts the model, makes the ledger a first-class input, drops the long "don't sound like AI" rulebook (gpt-5.4 doesn't need that lecture).

Non-goal: style-profile overhaul, semantic few-shot retrieval, cross-chat memory. All deferred.

## Design

### SessionLedger (new)

**Lifecycle:** lives in memory on `ChatMonitor`. Keyed by `chatUsername`. Reset on `startAutopilot()` / `stopAutopilot()`. Preserved across pause/resume (pause is not session termination). Not persisted to SQLite — a dropped process starts a new session anyway.

**Entry shape:**

```swift
struct LedgerEntry {
    let timestamp: Date
    let outgoingText: String
    let peerLastMessage: String?
    let topic: String?
}
```

**Container on ChatMonitor:**

```swift
@Published private(set) var autopilotSessionLedger: [String: [LedgerEntry]] = [:]

func appendLedgerEntry(_ entry: LedgerEntry, for chatUsername: String) {
    var list = autopilotSessionLedger[chatUsername] ?? []
    list.append(entry)
    if list.count > 20 { list.removeFirst(list.count - 20) }
    autopilotSessionLedger[chatUsername] = list
}

func resetSessionLedger() {
    autopilotSessionLedger = [:]
}
```

**Cap:** 20 entries per chat (FIFO). Covers ~1-2h of active chat at typical pacing.

### Write Paths

Every confirmed outgoing message writes one entry:

1. `AutopilotService.serialSend` — after `verifySend` returns `(verified, _)` == true.
2. `ConversationDetailView.sendReply` — if autopilot session active, append on success. (Manual sends during autopilot matter too — otherwise autopilot can forget the user just said X.)
3. `AutopilotService.executeSend` — the pending-queue approval path. Writes on success.

Skipped messages, pending queues, and read-but-not-replied states do NOT write. Only actual sends.

### Read Path

Inside `AutoReplyGenerator` (the thing that builds the prompt for the LLM), pull the ledger and format it for injection:

```swift
func formatLedger(_ entries: [LedgerEntry]) -> String {
    guard !entries.isEmpty else {
        return "（会话刚开始，你还没发过消息。）"
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return entries.suffix(8).map { e in
        let peer = e.peerLastMessage.map { "[\(fmt.string(from: e.timestamp)) 对方: \"\($0.prefix(50))\"]" }
            ?? "[\(fmt.string(from: e.timestamp))]"
        return "\(peer) → 你回:「\(e.outgoingText)」"
    }.joined(separator: "\n")
}
```

The formatted string replaces a new `{session_ledger}` placeholder in prompt v3.

### Prompt v3 (`autopilot_reply_v3.txt`)

Design principles for the rewrite:

- **Trust gpt-5.4**. Drop the 13-numbered-rules rulebook. Keep only structural constraints (JSON output, skip/pending/read_no_reply decisions).
- **Put the ledger front-and-center**. The model sees "here's exactly what you've been saying" before it sees peer context.
- **Keep the style fingerprint concise**. Length range, punctuation habits, a few example messages. No meta-commentary like "不要用'好的呢'".
- **Separate identity vs situation**. Identity (who am I, how do I talk) at the top. Situation (what's being said right now) at the bottom. Clearer for the model than the current interleaved prose.

Rough shape (final text during implementation, not placeholder here):

```
你是在替用户回复微信。用户的写作特征和这段会话的实时记录如下。

# 用户是谁（说话方式）
- 消息长度：{length_p25}-{length_p75} 字
- 标点：{punctuation_style}
- 句式：{sentence_style}
- 常用语：{frequent_phrases}
- 真实发过的句子：{few_shot_examples}

# 对方是谁
{contact_role}，关注级别：{attention_level}
过去对话的背景：{conversation_memory}

# 这次托管会话里你已经说过什么（不能自相矛盾，可以自然回应）
{session_ledger}

# 最近几条消息
{context_window}

# 需要回复的
{sender_name}：{message_body}

输出：{"reply":"...","confidence":0-1,"risk":"low/medium/high","skip":false,"pending":false,"read_no_reply":false,"reasoning":"..."}

只输出 JSON，不加说明。
```

v2 kept on disk for rollback. AutopilotService selects v3 by filename.

### Data Flow

```
[peer sends msg]
    ↓
AutopilotService.evaluateIncomingMessage
    ↓
AutoReplyGenerator.generate
    ├── loads prompt v3 from PromptLoader
    ├── pulls ledger via monitor.autopilotSessionLedger[chatUsername]
    ├── pulls style profile via StyleProfiler
    ├── pulls ConversationMemory via store
    └── calls AIService.complete(...)  ← Codex → gpt-5.4
    ↓
[reply returned, confidence checked, guardrails]
    ↓
AutopilotService.serialSend
    ↓ (success + verified)
ChatMonitor.appendLedgerEntry  ← new
    ↓
[next peer message, loop]
```

## Components

**New:**
- `Sources/WeChatHUD/Data/Models.swift` — `struct LedgerEntry`
- `Sources/WeChatHUD/Resources/prompts/autopilot_reply_v3.txt`

**Modified:**
- `Sources/WeChatHUD/Services/ChatMonitor.swift` — `autopilotSessionLedger` dictionary, `appendLedgerEntry`, `resetSessionLedger` (called from `startAutopilot` / `stopAutopilot`)
- `Sources/WeChatHUD/Services/AutopilotService.swift` — call `monitor.appendLedgerEntry` after verified sends (3 sites: serialSend, executeSend, any other send path)
- `Sources/WeChatHUD/Services/AutoReplyGenerator.swift` — load v3 by default; build `{session_ledger}` substitution; add `peerLastMessage` param so it can be stored in the ledger entry
- `Sources/WeChatHUD/Views/ConversationDetailView.swift` — when autopilot session is active, call `appendLedgerEntry` on successful manual send

**Untouched:**
- `StyleProfiler` — prompt v3 still consumes its output, same interface
- `ConversationMemory` — still used as longer-term background
- `AutopilotConfig` — no new fields

## Rollback

Single file swap. Either revert `AutoReplyGenerator`'s template-name constant (`autopilot_reply_v3` → `autopilot_reply_v2`) or delete the v3 file. Ledger code is additive (no write = read returns empty string = prompt includes the "会话刚开始" fallback), so keeping the ledger infrastructure in place is safe even during a prompt rollback.

## Testing

- **Unit tests** for `appendLedgerEntry` capacity cap (21st entry evicts the first) and session reset clearing all chats.
- **Prompt-load test** confirming `autopilot_reply_v3` loads and has all expected placeholders.
- **Integration test** (skippable if Codex not logged in) sending a two-message sequence: first reply commits to "我明天上午 10 点开会", second peer message asks "记得开会吧?" → assert v3 output doesn't contradict the earlier commitment. Use `XCTSkipIf` when auth is missing so CI stays green.
- **Smoke test** via existing 352-test suite — should stay green.

## Non-goals

- Semantic-similarity few-shot selection. Random/recent stays.
- Cross-chat identity memory.
- Multi-turn planning / agent state machine.
- Token budget management for gpt-5.4 (current payloads well under limits).
- UI surfacing of the ledger (developer-only feature for this pass).
