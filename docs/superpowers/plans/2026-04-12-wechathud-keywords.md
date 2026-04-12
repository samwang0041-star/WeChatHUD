# WeChatHUD #4 关键词订阅 — Implementation Plan

> **For agentic workers:** Implement task-by-task. Each task has explicit file paths, code shapes, and verification steps. Don't refactor unrelated code; don't add features beyond what's listed.

**Goal:** 用户在设置里维护一组关键词；扫描时对**所有聊天**（不限白名单）匹配命中的消息，聚合到 ExtendedTabsView 新增的 `关注` tab。命中条目独立于 VIP / 未读两个 tab，提供 dismiss（忽略此条）和 mute（在设置里删词）两种处理路径。

**Non-goals:** AI 摘要、命中通知 banner、按关键词归档、正则匹配。本期只做朴素 substring 匹配。

---

## Architecture overview

```
User → Settings/KeywordSettingsView → store.setSettingJSON("keywords", ...)
                                    ↓
                              monitor.updateKeywordsConfig(cfg)
                                    ↓
                                  scan()
                                    ↓
              ChatMonitor.performScan (off-main, Task.detached)
                ├── 已有：fetch unread chats / VIP messages
                └── 新增：fetch top-100 sessions × 20 msgs each
                              ↓
                        substring match per msg
                              ↓
                        filter dismissed UIDs
                              ↓
                       sort + cap to maxMatches
                              ↓
                  ScanOutcome.keywordMatches
                              ↓
            main: monitor.keywordMatches = outcome.keywordMatches
                              ↓
              ExtendedTabsView 关注 tab renders
```

---

## Task 1: Data models

**File:** `Sources/WeChatHUD/Data/Models.swift`

Add at the bottom of the file (before `// MARK: - DB Key`):

```swift
// MARK: - Keyword subscription

/// Persisted via `HUDStore.setSettingJSON("keywords", ...)`. Empty by
/// default — until the user adds at least one keyword, the scanner skips
/// the keyword pass entirely.
struct KeywordsConfig: Codable {
    var keywords: [String] = []
    var caseSensitive: Bool = false
    /// Hard cap on how many matches we keep in memory. Older / lower
    /// priority matches are dropped to keep the UI snappy.
    var maxMatches: Int = 50
}

/// One message that matched at least one configured keyword. The full
/// `preview` is kept (not truncated) so the row UI can render the hit
/// in context. `matchedKeyword` is the first keyword that matched —
/// used for the inline highlight.
struct KeywordMatch: Identifiable {
    let id = UUID()
    /// WeChat-side message UID. Used as the dedup / dismiss key so the
    /// same message never re-appears across scans.
    let msgUID: String
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String
    let matchedKeyword: String
    let timestamp: Date
    let kind: HUDNotificationKind
}
```

**Verify:** `swift build` compiles.

---

## Task 2: Persistence — dismissed-match table

**File:** `Sources/WeChatHUD/Data/HUDStore.swift`

### Step 2.1: Schema

In the existing `open()` method, add the new table next to the others:

```swift
CREATE TABLE IF NOT EXISTS keyword_dismissed (
    msg_uid       TEXT PRIMARY KEY,
    dismissed_at  INTEGER NOT NULL
)
```

### Step 2.2: API

Add three methods on `HUDStore`:

```swift
/// Returns the set of WeChat msg UIDs the user has explicitly dismissed
/// from the keyword 关注 tab. Used by `ChatMonitor.performScan` to filter
/// out re-matches across scans.
func loadDismissedKeywordMatches() -> Set<String>

/// Mark a specific keyword match as dismissed. Idempotent.
func dismissKeywordMatch(msgUID: String)

/// House-keeping — drop dismiss records older than `days` days so the
/// table doesn't grow forever. Called once on `open()`.
func clearDismissedKeywordMatches(olderThanDays days: Int)
```

Implementation pattern: use the same `sqlite3_prepare_v2` / `sqlite3_step` boilerplate as the existing `chat_actions` methods. Timestamps are unix seconds.

### Step 2.3: Wire cleanup into open()

At the end of `HUDStore.open()`, call `clearDismissedKeywordMatches(olderThanDays: 7)`.

**Verify:** `swift build` compiles. Run the app once, check that `~/.wechat-hud/hud.sqlite3` has the new table:

```bash
sqlite3 ~/.wechat-hud/hud.sqlite3 ".schema keyword_dismissed"
```

---

## Task 3: Scanner integration

**File:** `Sources/WeChatHUD/Services/ChatMonitor.swift`

### Step 3.1: New @Published + state

```swift
@Published var keywordMatches: [KeywordMatch] = []

private var keywordsConfig: KeywordsConfig
```

In `init`, load from store:
```swift
self.keywordsConfig = store.getSettingJSON("keywords", as: KeywordsConfig.self) ?? KeywordsConfig()
```

### Step 3.2: ScanOutcome

Add `keywordMatches: [KeywordMatch]` to the `ScanOutcome` struct.

### Step 3.3: performScan — keyword pass

This is the main work. Inside `performScan` (the `nonisolated private static` function), after the existing unread / VIP passes complete, add a third pass:

```swift
// MARK: keyword scan
//
// Scope is intentionally larger than the unread pass: we want to
// catch keyword hits in chats the user does NOT consider VIP and
// has NOT marked unread. To bound IO cost we sort sessions by
// last_timestamp desc and take the top 100, then pull the latest
// 20 messages from each. ~2000 msgs per cycle, all string-matched.
let kwCfg: KeywordsConfig = /* passed in via params, see Step 3.4 */
var keywordMatches: [KeywordMatch] = []

if !kwCfg.keywords.isEmpty {
    let dismissed: Set<String> = /* loaded once at start of scan, see 3.4 */
    let normalizedKeywords: [(raw: String, search: String)] = kwCfg.keywords.map {
        ($0, kwCfg.caseSensitive ? $0 : $0.lowercased())
    }

    let topSessions = reader.fetchAllSessions()                 // already exists
        .sorted { $0.lastTimestamp > $1.lastTimestamp }
        .prefix(100)

    for session in topSessions {
        guard let msgs = try? reader.fetchMessages(
            chatUsername: session.username,
            limit: 20
        ) else { continue }

        for msg in msgs {
            // Skip messages the user already dismissed.
            if dismissed.contains(msg.id) { continue }

            let haystack = kwCfg.caseSensitive ? msg.text : msg.text.lowercased()
            guard let hit = normalizedKeywords.first(where: { haystack.contains($0.search) }) else {
                continue
            }

            keywordMatches.append(KeywordMatch(
                msgUID: msg.id,
                chatUsername: msg.chatUsername,
                chatName: msg.chatName,
                senderName: msg.senderName,
                preview: msg.text,
                matchedKeyword: hit.raw,
                timestamp: Date(timeIntervalSince1970: TimeInterval(msg.createTime)),
                kind: session.isGroup ? .groupMessage : .privateChat
            ))
        }
    }

    // Newest first, then cap.
    keywordMatches.sort { $0.timestamp > $1.timestamp }
    if keywordMatches.count > kwCfg.maxMatches {
        keywordMatches = Array(keywordMatches.prefix(kwCfg.maxMatches))
    }
}
```

> **Verify against the actual API**: `WeChatReader.fetchAllSessions()` and `fetchMessages(chatUsername:limit:)` are the exact names used elsewhere in `ChatMonitor`. If the signatures differ, match what's already there — do not invent new reader methods.

Add the result to the returned `ScanOutcome`.

### Step 3.4: Pass keyword config + dismissed set into performScan

`scan()` already snapshots state for the detached task. Add two more captures:

```swift
nonisolated(unsafe) let storeRef = store          // already exists
let kwCfg = keywordsConfig                         // NEW
let dismissedSet = store.loadDismissedKeywordMatches()  // NEW — main thread, before detach

let outcome = await Task.detached(priority: .userInitiated) {
    return ChatMonitor.performScan(
        reader: readerRef,
        store: storeRef,
        changedRelPaths: cp,
        thresholds: th,
        currentRecent: currentRecent,
        recentLimit: rLimit,
        keywordsConfig: kwCfg,            // NEW param
        dismissedKeywordMatches: dismissedSet  // NEW param
    )
}.value
```

Update `performScan`'s signature accordingly.

### Step 3.5: Apply on main

In the existing main-thread apply block at the end of `scan()`:

```swift
self.keywordMatches = outcome.keywordMatches
```

### Step 3.6: Public mutators

Add to `ChatMonitor`:

```swift
/// Persist + apply a new keyword config, then re-trigger a scan so
/// the 关注 tab updates immediately.
func updateKeywordsConfig(_ cfg: KeywordsConfig) {
    self.keywordsConfig = cfg
    store.setSettingJSON("keywords", value: cfg)
    Task { await self.scan() }
}

/// User dismissed a single match — write it to the dismiss table and
/// drop it from the in-memory list. The next scan will skip it via
/// the `dismissed` filter.
func dismissKeywordMatch(_ match: KeywordMatch) {
    store.dismissKeywordMatch(msgUID: match.msgUID)
    keywordMatches.removeAll { $0.id == match.id }
}
```

**Verify:** `swift build` compiles. Launch app, manually invoke `monitor.updateKeywordsConfig(KeywordsConfig(keywords: ["test"]))` from a debug menu or by setting it in `applicationDidFinishLaunching` temporarily. Confirm `monitor.keywordMatches` populates after scan.

---

## Task 4: ExtendedTabsView — 关注 tab

**File:** `Sources/WeChatHUD/Views/ExtendedTabsView.swift`

### Step 4.1: New input

Add to the struct:

```swift
let keywordMatches: [KeywordMatch]
```

### Step 4.2: New tab case

```swift
enum Tab {
    case vip
    case unread
    case keyword       // NEW
}
```

### Step 4.3: tabBar — conditional 关注 chip

After the existing `if !unreadItems.isEmpty || !suppressedItems.isEmpty` block, add:

```swift
if !keywordMatches.isEmpty {
    tabButton(.keyword, label: "关注", count: keywordMatches.count)
}
```

### Step 4.4: switch in body

```swift
switch selectedTab {
case .vip:     vipContent
case .unread:  unreadContent
case .keyword: keywordContent     // NEW
}
```

### Step 4.5: keywordContent view

```swift
private var keywordContent: some View {
    VStack(alignment: .leading, spacing: 0) {
        if keywordMatches.isEmpty {
            emptyState("没有命中关键词的消息")
        } else {
            ForEach(keywordMatches) { match in
                KeywordRow(match: match)
            }
        }
    }
    .padding(.bottom, 6)
}
```

### Step 4.6: KeywordRow

Mirror `UnreadRow`'s structure. Differences:

- Left accent bar: `Color.yellow.opacity(0.7)` (distinguishes from VIP-blue and overdue-red).
- `content` inlines a yellow highlight on the matched keyword:

```swift
private var content: Text {
    let sender = Text(match.senderName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
    let colon = Text(": ").foregroundColor(.white.opacity(0.7))

    // Split the preview around the first occurrence of the matched
    // keyword and recompose with a highlighted middle segment.
    let body = highlightedPreview(match.preview, keyword: match.matchedKeyword)

    switch match.kind {
    case .privateChat:
        return sender + colon + body
    default:
        let group = Text(match.chatName).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
        let sep = Text(" · ").foregroundColor(.white.opacity(0.35))
        return group + sep + sender + colon + body
    }
}

private func highlightedPreview(_ preview: String, keyword: String) -> Text {
    guard let range = preview.range(of: keyword, options: .caseInsensitive) else {
        return Text(preview).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
    }
    let pre = String(preview[..<range.lowerBound])
    let hit = String(preview[range])
    let post = String(preview[range.upperBound...])
    return Text(pre).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
        + Text(hit).font(.system(size: 12, weight: .bold)).foregroundColor(.yellow)
        + Text(post).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
}
```

- Tap behavior: same as `UnreadRow` — `WeChatLauncher.openChat(named: match.chatName)`, Cmd+click copies.
- Context menu:
  - 在微信中打开
  - 复制消息
  - Divider
  - **忽略此条** → `monitor.dismissKeywordMatch(match)`

Wrap the row in `FirstMouseRowHost { ... }` for the same reason `UnreadRow` does.

**Verify:** Build. `monitor.dismissKeywordMatch(_)` is reachable via `@EnvironmentObject var monitor: ChatMonitor`.

---

## Task 5: HUDRootView — pass new prop

**File:** `Sources/WeChatHUD/Views/HUDRootView.swift`

Find the `ExtendedTabsView(...)` instantiation and add:

```swift
ExtendedTabsView(
    vipNotifications: monitor.recentNotifications,
    unreadItems: monitor.unreadItems,
    suppressedItems: monitor.suppressedItems,
    keywordMatches: monitor.keywordMatches    // NEW
)
```

If `extendedTabsSize(vip:unread:)` lives here, update its callers (also in `AppDelegate`) to factor keyword count into the row total — see Task 6.

---

## Task 6: AppDelegate — sizing + sink

**File:** `Sources/WeChatHUD/App/AppDelegate.swift`

### Step 6.1: panelSize for .extended

```swift
case .extended:
    let vip = monitor.recentNotifications.count
    let visible = monitor.unreadItems.count
    let suppressed = monitor.suppressedItems.count
    let kw = monitor.keywordMatches.count          // NEW
    if vip == 0 && visible == 0 && suppressed == 0 && kw == 0 {
        return (PanelState.width(for: .extended), PanelState.height(for: .extended))
    }
    return extendedTabsSize(vip: vip, unread: max(visible, suppressed, kw))
```

### Step 6.2: New Combine sink

Next to the existing `monitor.$unreadItems` / `$suppressedItems` / `$recentNotifications` sinks:

```swift
monitor.$keywordMatches
    .dropFirst()
    .sink { [weak self] _ in self?.resizeExtendedIfActive() }
    .store(in: &cancellables)
```

**Verify:** Build, run. With one or more keyword matches present, hover the pill — it should expand to fit the keyword tab's row count.

---

## Task 7: Settings UI

### Step 7.1: New file

**File:** `Sources/WeChatHUD/Views/Settings/KeywordSettingsView.swift` (NEW)

```swift
import SwiftUI

/// Lets the user manage their keyword subscription. Keywords are matched
/// case-insensitively by default against EVERY chat, not just the
/// whitelist — that's the whole point. Saving any change immediately
/// triggers a re-scan via `monitor.updateKeywordsConfig`.
struct KeywordSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    @State private var config: KeywordsConfig = KeywordsConfig()
    @State private var newKeyword: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("命中以下任一关键词的消息将出现在「关注」标签中。监控范围覆盖最近活跃的所有聊天，不限白名单。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))

            HStack(spacing: 8) {
                TextField("输入关键词后回车", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addKeyword() }
                Button("添加") { addKeyword() }
                    .disabled(trimmedNew.isEmpty)
            }

            if config.keywords.isEmpty {
                Text("还没有添加任何关键词。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 6)
            } else {
                // Simple wrap layout — chips reflow into multiple rows.
                FlexibleChipRow(items: config.keywords) { kw in
                    KeywordChip(text: kw) { removeKeyword(kw) }
                }
            }

            Toggle("区分大小写", isOn: $config.caseSensitive)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onChange(of: config.caseSensitive) { _ in save() }
        }
        .onAppear {
            config = store.getSettingJSON("keywords", as: KeywordsConfig.self) ?? KeywordsConfig()
        }
    }

    private var trimmedNew: String {
        newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addKeyword() {
        let kw = trimmedNew
        guard !kw.isEmpty else { return }
        guard !config.keywords.contains(kw) else {
            newKeyword = ""
            return
        }
        config.keywords.append(kw)
        newKeyword = ""
        save()
    }

    private func removeKeyword(_ kw: String) {
        config.keywords.removeAll { $0 == kw }
        save()
    }

    private func save() {
        monitor.updateKeywordsConfig(config)
    }
}

private struct KeywordChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.yellow.opacity(0.4), lineWidth: 0.5)
        )
    }
}

/// Minimal flow-layout that wraps chips onto new lines. Avoid pulling
/// in any third-party FlowLayout package — this is a one-screen need.
private struct FlexibleChipRow<Item: Hashable, ChipView: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> ChipView

    var body: some View {
        // SwiftUI's built-in `Layout` (macOS 13+) gives us a real flow.
        FlowLayoutImpl(spacing: 6) {
            ForEach(items, id: \.self) { item in
                chip(item)
            }
        }
    }
}

private struct FlowLayoutImpl: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
```

### Step 7.2: Register tab in SettingsView

**File:** `Sources/WeChatHUD/Views/Settings/SettingsView.swift`

Add a `.keywords` case to `Tab`:

```swift
enum Tab: Hashable, CaseIterable {
    case whitelist
    case keywords        // NEW (place between whitelist and ai)
    case ai
    case sync
    case notification

    var label: String {
        switch self {
        ...
        case .keywords:    return "关键词订阅"
        }
    }

    var icon: String {
        switch self {
        ...
        case .keywords:    return "magnifyingglass"
        }
    }

    var tint: Color {
        switch self {
        ...
        case .keywords:    return .yellow
        }
    }

    var subtitle: String {
        switch self {
        ...
        case .keywords:    return "订阅关键词，跨群跨好友捕获重要话题。"
        }
    }
}
```

In the `content` switch:

```swift
case .keywords:
    SettingsCard { KeywordSettingsView() }
```

**Verify:** Build. Open detail panel → settings → 关键词订阅 tab renders, can add/remove keywords, the change persists across restart.

---

## Task 8: End-to-end verification

1. `swift build` clean.
2. `make app && open .build/WeChatHUD.app`.
3. Open settings → 关键词订阅 → add keyword `测试`.
4. From another device or WeChat itself, send a message containing `测试` to any chat (private or group, whitelist or not).
5. Within one scan cycle (≤ a few seconds — FSEvents-driven), the pill should grow a `关注` tab. Hover the pill, click `关注`.
6. The matching message appears with `测试` highlighted yellow.
7. Right-click the row → 忽略此条. The row disappears.
8. Send the **same** chat another `测试` — it should appear (different msg UID).
9. Send the **previously dismissed** message's content again — only the new occurrence appears; the dismissed UID stays hidden.
10. Quit and relaunch. Settings still has `测试`. Dismissed list still suppresses the old UID.
11. Add a second keyword `报销`, verify both match.
12. Remove all keywords from settings → `关注` tab disappears from the tab bar entirely.
13. Watch CPU / memory in Activity Monitor over a minute of normal use — keyword pass should add < 5% extra CPU on a typical user's DB.

If step 13 shows noticeable lag, lower the per-chat fetch limit from 20 → 10 first; if still bad, drop to scanning every 3rd cycle by adding a `keywordScanCounter` in `ChatMonitor`.

---

## Out-of-scope guardrails

- **Don't** broadcast keyword hits as banner notifications. The user can opt into that later if needed.
- **Don't** add regex / glob matching. Plain `String.contains` only.
- **Don't** persist matches themselves — they're recomputed on every scan from the ground truth (WeChat DB) plus the dismiss filter.
- **Don't** touch the existing VIP / unread scan logic. Keyword pass is additive; failures inside it must NOT abort the rest of the scan (wrap the whole `if !kwCfg.keywords.isEmpty { ... }` block in a `do { } catch { print("[WCHUD] keyword scan failed: \(error)") }` if any throwing call lives inside).
