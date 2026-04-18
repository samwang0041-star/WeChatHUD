# Autopilot Entry Redesign — Design Spec

**Date:** 2026-04-19
**Author:** brainstormed with user
**Status:** approved, ready for plan

## Problem

Autopilot (自动托管) is a core feature — AI replies on the user's behalf with safety guardrails. Its only entry point today is a tab in the extended HUD (`ExtendedTabsView.swift:150`), which:

1. Can't be seen in compact mode — user has to hover-expand the pill to check if autopilot is running.
2. Is cramped: the extended tab bar already has 关注/待回/未读/追赶/承诺/工作台/日报/洞察/托管 — the 托管 tab gets pushed around and is easily missed.
3. Needs several clicks to toggle: hover → tab click → button click.
4. Has no presence on the compact bar so the user loses the "is autopilot actually running right now?" glance.

## Goal

Redesign the autopilot entry so it fits the Dynamic Island / PixelBuddy design language: **always-visible glance + one-click detail + dedicated full view**. Remove it from the crowded tab bar.

## Design

### 1. Left-wing Indicator (glanceable)

Compact bar's left wing gains a permanent autopilot indicator after the `aiTick` element:

```
[ ● 简报 · badges · aiTick · 🤖 ✓12 ⏳3 ] ( 缺口 ) [ PixelBuddy ]
                              ^^^^^^^^^^^^
```

**States:**

| Autopilot state | Icon color | Trailing stats |
|---|---|---|
| Off | Grey 30% opacity 🤖 | (none) |
| Running | Green 🤖 | `✓N ⏳M` (sent / pending) |
| Paused (manual) | Yellow 🤖 | same stats |
| Paused (auto — WeChat foreground) | Yellow 🤖 | same stats |
| Error | Red 🤖 | last error in tooltip |

- Icon size: 10pt matching aiTick / badges.
- Stats size: 9pt weight medium, color-tinted (sent = green, pending = orange).
- Tooltip on hover: short status string (e.g. "已跑 12 分钟 · 点击查看").

**Interaction:** Left-click opens popover (§2). Right-click: no menu (keep simple).

### 2. Click Popover (quick control)

An AppKit `NSPopover` anchored below the indicator, 180–240pt wide. Layout changes with state:

**When off:**

```
┌─────────────────────────┐
│  🤖 自动托管            │
│  当前关着               │
│  ┌───────────────────┐  │
│  │  ▶  开始托管      │  │
│  └───────────────────┘  │
│  → 打开详情 · 设置       │
└─────────────────────────┘
```

**When running:**

```
┌─────────────────────────────┐
│  🤖 自动托管 · 已跑 12 分钟   │
│   ✓ 已发    12              │
│   ⏳ 待确认  3              │
│   ⊘ 跳过    1               │
│  ┌─────────┐ ┌────────────┐ │
│  │ ⏸ 暂停  │ │ ■ 停止      │ │
│  └─────────┘ └────────────┘ │
│  → 查看日志 · 设置           │
└─────────────────────────────┘
```

**When paused:** "⏸ 暂停" becomes "▶ 恢复" (green). If auto-paused, a grey info line below buttons: "已暂停 — 你正在用微信，离开后自动恢复".

**Interaction details:**

- Start / Stop: fire immediately. Popover shows a 2-second confirmation toast ("托管已启动" / "托管已停止") then auto-closes.
- Pause / Resume: toggle `autopilotManuallyPaused`. No close.
- "打开详情" / "查看日志": close popover, call `panelState.showDetail(kind: .autopilot)` (§3).
- "设置": close popover, open Settings window scrolled to 自动托管 section.
- Click outside popover: close (standard `NSPopover.Behavior.transient`).

### 3. Detail View (full control surface)

The existing `AutopilotTabView` content moves into `DetailPanelView`. The Tab-enum case `.autopilot` is removed from `ExtendedTabsView.Tab`.

**New `PanelState.DetailKind`:**

```swift
enum DetailKind: Equatable {
    case conversation(chatUsername: String)   // existing behavior
    case autopilot
}
```

Replace the current `panelState.detailChatUsername: String?` with `detailKind: DetailKind?`. Call sites:

- `showDetail(chatUsername:)` → `showDetail(kind: .conversation(chatUsername))`
- Popover "打开详情" → `showDetail(kind: .autopilot)`

**DetailPanelView.body** branches on `panelState.detailKind`:

- `.conversation(chatUsername)`: existing ConversationDetailView.
- `.autopilot`: wrap the content currently inside `AutopilotTabView.body`. The AutopilotTabView file becomes the rendering component for both the (soon-gone) tab and the new detail state — keep the file, just rename if needed to `AutopilotDetailView`. Header shows a back chevron consistent with the chat detail.

### 4. PixelBuddy Autopiloting Mood

Add to `BuddyMood`:

```swift
case autopiloting
```

**Sprite:** reuse the existing idle sprite, overlay a small antenna/cap pixel pattern on top of the head. Keep a single extra sprite frame (or overlay layer) — no full animation sequence needed for v1. Position the antenna 2-3 pixels above the existing head row using the existing pixel palette.

**Mood priority in `AIBuddyOverlay`:**

```swift
let effectiveMood: BuddyMood
if tracker.isActive { effectiveMood = .analyzing }
else if monitor.autopilotActive { effectiveMood = .autopiloting }
else { effectiveMood = propagatedMood }
```

Rationale: AI activity wins (transient signal), autopilot shows underneath (persistent session).

### 5. Cleanup — Remove from Tab Bar

`ExtendedTabsView.swift`:

- Delete line 150 (`tabButton(.autopilot, label: ...)` in `tabBar`).
- Delete line 85 (`.autopilot: AutopilotTabView()` in the `switch selectedTab`).
- Delete `case autopilot` from `enum Tab`.
- Any remaining `.autopilot` references → compile error → fix call sites.

`AutopilotTabView.swift` stays as the component rendered inside `DetailPanelView`. Rename optional — it now renders in detail state, not a tab.

## Data Model (no schema changes)

Reuses existing fields on `ChatMonitor`:

- `autopilotActive: Bool`
- `autopilotManuallyPaused: Bool`
- `autopilotPaused: Bool` (auto-paused when WeChat frontmost)
- `autopilotSessionSent: Int`
- `autopilotSessionPending: Int`
- `autopilotSessionStats: SessionStats` (existing — has `startedAt`, `duration`, etc.)
- `toggleAutopilot()`, `startAutopilot()`, `stopAutopilot()`

New derived values (computed in the indicator view):

- Color/icon derived from `(autopilotActive, autopilotManuallyPaused, autopilotPaused)` state triple.
- Duration string: formatted `autopilotSessionStats.duration` → "已跑 X 分钟" / "已跑 X 小时".
- Skipped count: `autopilotSessionStats` has `skipSum` or similar — if missing, derive from log entries.

## Components (file structure)

**New:**
- `Sources/WeChatHUD/Views/AutopilotIndicator.swift` — left-wing indicator view + popover content. Single file, contains:
  - `struct AutopilotIndicator: View` — the 10pt icon + stats displayed in CompactInboxBar.
  - `struct AutopilotPopoverView: View` — the popover UI.
  - Helper logic to map `(active, paused, manuallyPaused)` → color + label.

**Modified:**
- `Sources/WeChatHUD/Views/CompactInboxBar.swift` — add `AutopilotIndicator` after `aiTick` inside `leftWing`.
- `Sources/WeChatHUD/Views/PixelBuddyView.swift` — add `.autopiloting` mood, render overlay pixels.
- `Sources/WeChatHUD/App/PanelState.swift` — add `DetailKind` enum, migrate `detailChatUsername` → `detailKind`.
- `Sources/WeChatHUD/Views/DetailPanelView.swift` — branch on `detailKind`, render AutopilotTabView content for `.autopilot`.
- `Sources/WeChatHUD/Views/ExtendedTabsView.swift` — remove autopilot tab + enum case.
- `Sources/WeChatHUD/Views/AutopilotTabView.swift` — extract the shared content used in detail state; header gets a back chevron that dismisses back to extended. Rename optional.

**Potential settings integration:**
- `Sources/WeChatHUD/Views/Settings/SettingsView.swift` — "设置" link in popover navigates to `.autopilot` settings tab. Existing routing should cover this.

## Testing

- Unit tests for the state-to-visual mapping (given `(active, manuallyPaused, paused, sent, pending)`, the indicator renders expected color/text).
- Unit tests for `DetailKind` routing in PanelState.
- Existing 352 tests continue to pass.
- Smoke test: build + launch + visual inspection of:
  - Indicator off-state looks right
  - Click → popover opens, start button works
  - Indicator becomes green; stats update
  - "打开详情" navigates to detail view rendering AutopilotTabView content
  - Pausing from popover flips icon to yellow

## Non-goals

- No new autopilot features — this is entry/presentation only.
- No menu bar toggle item (out of scope; tab-bar removal already makes the popover the canonical entry).
- No keyboard shortcut (can be added later if user wants).
- No responsive / collapsing indicator — if the compact bar width doesn't fit, the indicator keeps its full form and pushes the pill wider. The pill is already dynamic-width.

## Open questions

None — user locked in every prompted choice.
