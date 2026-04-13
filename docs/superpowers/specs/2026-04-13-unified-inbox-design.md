# Unified Inbox Redesign

**Date**: 2026-04-13
**Status**: Approved

## Problem

Current 7-tab system (关注/待回/未读/追赶/承诺/日报/托管) has significant data overlap — the same message can appear in up to 4 tabs simultaneously. Tab proliferation creates cognitive overhead for what is fundamentally a "what needs my attention right now" tool.

## Design Decisions

1. **Core = unified inbox** — single priority-sorted list, no tabs
2. **Low-frequency features (日报/承诺/托管) move to detail panel** — accessible via gear icon
3. **Message lifecycle: auto-remove on reply + manual dismiss**

## Data Model

```swift
struct InboxItem: Identifiable {
    let id: String              // chatUsername as dedup key
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String         // latest message summary
    let isGroup: Bool
    let timestamp: Date

    // Classification
    let actionRequired: Bool    // true = 待办区, false = 仅通知区
    let priority: Priority      // p0/p1/p2 (meaningful only when actionRequired=true)

    // Source tags (for UI display, not tab routing)
    let isVIP: Bool
    let isWhitelisted: Bool
    let unreadCount: Int
    let askType: AskType

    // Lifecycle
    var status: Status          // active / dismissed
    var dismissedAtMsgId: Int64? // track which batch was dismissed
}

enum Priority: Comparable {
    case p0  // VIP/boss + needs reply, or group @-mention
    case p1  // whitelisted + needs reply (ask/task/deadline)
    case p2  // whitelisted + info-only
}

enum Status {
    case active
    case dismissed
}
```

## Priority Calculation

Merges existing ReplyDebtScorer weights + VIP attention level:

- **P0**: contact role is boss/key_client AND needs reply, OR group chat with direct @-mention
- **P1**: whitelisted contact + askType is not .none (ask/task/deadline/review/etc.)
- **P2**: whitelisted contact + info-only (askType == .none, no @-mention)

## actionRequired Logic

- `true`: askType != .none, OR group @-mention, OR (unreadCount > 0 AND contactRole is boss/key_client)
- `false`: pure info-flow — FYI messages, group chat without @, recalled messages

## Layout

```
┌──────────────────────────────────┐
│  收件箱 (3)              ⚙       │
├──────────────────────────────────┤
│ P0 🔴 凌慧 — 红字为修改部分请查收  │
│      私聊 · 白名单 · 12分钟前      │
│ P0 🔴 ponge — 果然...            │
│      私聊 · 白名单 · 25分钟前      │
│ P1 🟡 产品群 — @你 方案定了吗      │
│      群聊 · 3分钟前               │
│ ─ ─ ─ ─ 仅通知 ─ ─ ─ ─ ─        │
│ 📋 张总 — 明天10点开会            │
│      群聊 · 看了就行              │
└──────────────────────────────────┘
```

- Top section: actionRequired=true items, sorted by priority then timestamp
- Bottom section: actionRequired=false items (仅通知), visually separated
- Click row → expand reply suggestions / open WeChat
- Swipe/click dismiss → remove from list

## Message Lifecycle

### Auto-remove on reply
ScanEngine detects outbound message to the same chatUsername → removes the InboxItem automatically.

### Manual dismiss
User clicks dismiss → sets status=dismissed and records dismissedAtMsgId (the latest msgId at time of dismiss).

### Re-activation after dismiss
Next scan finds a newer msgId than dismissedAtMsgId → creates a new active InboxItem. This ensures dismissed items come back when new messages arrive.

## Group Chat Merging

One InboxItem per group chat (not per sender). Preview shows the most important message:
1. @-mention of user (highest)
2. VIP sender's message
3. Most recent message (fallback)

unreadCount shows total unread in the group.

## List Limits

- **actionRequired items**: no cap, all shown
- **仅通知 items**: max 5 visible, overflow collapsed as "还有 N 条动态" with expand option

## Empty State

When inbox is empty: "没有待处理消息" + last sync timestamp. Confirms the system is working, not broken.

## Recalled Messages

Recalled messages appear in the 仅通知 section with preview: "[撤回] original content preview". Never treated as actionRequired.

## Low-Frequency Features Relocation

Moved out of the main tab bar into the detail panel (gear icon):

| Feature | Current Tab | New Location |
|---------|-------------|--------------|
| 日报/周报 | dailyReport tab | Detail panel section |
| 承诺管理 | commitments tab | Detail panel section |
| 托管控制 | autopilot tab | Detail panel section |
| 追赶模式 | catchup tab | Removed (inbox subsumes its function) |

## Removed Components

- **CompactBarView** — already removed in prior commit
- **ExtendedTabsView tab bar** — replaced by single inbox list
- **CatchupTabView** — inbox's priority sort + 仅通知 section covers this use case
- **Tab enum and defaultTab logic** — no longer needed

## Preserved Components (relocated)

- **ReplyDebtExpandedView** — reused as the expand-on-click panel for inbox items
- **CommitmentTabView** — moved into detail panel
- **DailyReportTabView** — moved into detail panel
- **AutopilotTabView** — moved into detail panel

## Build Pipeline

InboxItem generation replaces the current separate pipelines:

```
ScanEngine.scan()
  → reads whitelist + sessions + recent messages
  → for each whitelisted chat with activity:
      → classify message (askType)
      → compute priority (role + askType + @mention)
      → determine actionRequired
      → check dismissed status (compare msgId)
      → emit InboxItem
  → ChatMonitor.inboxItems = sorted result
```

Existing ReplyDebtScorer logic is absorbed into the priority calculation. HUDNotification and UnreadItem pipelines are replaced by the unified InboxItem builder.
