# Unified Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 7-tab ExtendedTabsView with a single priority-sorted inbox list, relocate low-frequency features (日报/承诺/托管) to the detail/settings panel.

**Architecture:** ScanEngine continues to produce ReplyDebtItem + UnreadItem + HUDNotification. A new `InboxBuilder` merges these into a unified `[InboxItem]` array, deduplicating by chatUsername and computing a single priority. ChatMonitor publishes `inboxItems` instead of separate arrays. A new `InboxView` replaces ExtendedTabsView. Low-frequency tabs become new sidebar entries in SettingsView.

**Tech Stack:** Swift, SwiftUI, AppKit (NSPanel sizing)

**Spec:** `docs/superpowers/specs/2026-04-13-unified-inbox-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Sources/WeChatHUD/Data/InboxItem.swift` | InboxItem model + Priority + Status enums |
| Create | `Sources/WeChatHUD/Services/InboxBuilder.swift` | Merge ReplyDebt + Unread + Notification → [InboxItem] |
| Create | `Sources/WeChatHUD/Views/InboxView.swift` | Unified inbox list view (replaces ExtendedTabsView) |
| Create | `Sources/WeChatHUD/Views/InboxRowView.swift` | Single row in the inbox list |
| Create | `Tests/WeChatHUDTests/InboxBuilderTests.swift` | Unit tests for InboxBuilder |
| Modify | `Sources/WeChatHUD/Services/ChatMonitor.swift` | Add `@Published var inboxItems`, call InboxBuilder after scan |
| Modify | `Sources/WeChatHUD/Views/HUDRootView.swift` | Replace ExtendedTabsView with InboxView |
| Modify | `Sources/WeChatHUD/App/AppDelegate.swift` | Update panel sizing + resize sinks for inboxItems |
| Modify | `Sources/WeChatHUD/App/PanelState.swift` | Remove .compact from HUDState enum |
| Modify | `Sources/WeChatHUD/Views/Settings/SettingsView.swift` | Add 日报/承诺/托管 sidebar tabs |
| Modify | `Sources/WeChatHUD/Views/DetailPanelView.swift` | No change needed (already routes to SettingsView) |

---

### Task 1: InboxItem Data Model

**Files:**
- Create: `Sources/WeChatHUD/Data/InboxItem.swift`

- [ ] **Step 1: Create InboxItem model**

```swift
// Sources/WeChatHUD/Data/InboxItem.swift
import Foundation

/// Unified inbox entry. One per chat (deduped by chatUsername).
struct InboxItem: Identifiable {
    let id: String                  // == chatUsername
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String
    let isGroup: Bool
    let timestamp: Date

    let actionRequired: Bool
    let priority: InboxPriority
    let isVIP: Bool
    let isWhitelisted: Bool
    let unreadCount: Int
    let isAtMention: Bool
    let askType: AskType
    let reasons: [ReplyDebtReason]
    let suggestedReplyMinutes: Int

    var status: InboxStatus
    var dismissedAtMsgId: Int64?
}

enum InboxPriority: Int, Comparable {
    case p0 = 0
    case p1 = 1
    case p2 = 2

    static func < (lhs: InboxPriority, rhs: InboxPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum InboxStatus {
    case active
    case dismissed
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/InboxItem.swift
git commit -m "feat(inbox): add InboxItem data model"
```

---

### Task 2: InboxBuilder — Merge Logic

**Files:**
- Create: `Sources/WeChatHUD/Services/InboxBuilder.swift`
- Create: `Tests/WeChatHUDTests/InboxBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/WeChatHUDTests/InboxBuilderTests.swift
import XCTest
@testable import WeChatHUD

final class InboxBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeDebtItem(
        chatUsername: String = "wxid_test",
        chatName: String = "Test",
        senderName: String = "Sender",
        preview: String = "Hello",
        isGroup: Bool = false,
        isVIP: Bool = false,
        isWhitelisted: Bool = true,
        isAtMention: Bool = false,
        priority: ReplyDebtPriority = .p1,
        score: Int = 6,
        unreadCount: Int = 1,
        timestamp: Date = Date()
    ) -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: preview,
            latestOutboundPreview: nil,
            timestamp: timestamp,
            priority: priority,
            score: score,
            unreadCount: unreadCount,
            isGroup: isGroup,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            isAtMention: isAtMention,
            inboundCountSinceLastOutbound: 1,
            reasons: [],
            suggestedReplyMinutes: 30
        )
    }

    private func makeNotification(
        chatUsername: String = "wxid_vip",
        chatName: String = "VIP",
        senderName: String = "Boss",
        snippet: String = "FYI info",
        attentionLevel: AttentionLevel = .vip,
        isAtMention: Bool = false,
        timestamp: Date = Date()
    ) -> HUDNotification {
        HUDNotification(
            chatUsername: chatUsername,
            chatName: chatName,
            senderUsername: "sender_u",
            senderName: senderName,
            attentionLevel: attentionLevel,
            messageID: 1,
            rawText: snippet,
            snippet: snippet,
            isAtMention: isAtMention,
            timestamp: timestamp,
            kind: .privateChat
        )
    }

    // MARK: - Tests

    func testDebtItemBecomesActionRequired() {
        let debt = makeDebtItem(priority: .p0)
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].actionRequired)
        XCTAssertEqual(items[0].priority, .p0)
    }

    func testNotificationOnlyBecomesInfoItem() {
        let notif = makeNotification(chatUsername: "wxid_info", attentionLevel: .whitelist, isAtMention: false)
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].actionRequired)
        XCTAssertEqual(items[0].priority, .p2)
    }

    func testDebtAndNotificationSameChatDeduplicates() {
        let debt = makeDebtItem(chatUsername: "wxid_shared")
        let notif = makeNotification(chatUsername: "wxid_shared")
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1, "same chatUsername should dedup to 1 item")
        XCTAssertTrue(items[0].actionRequired, "debt takes precedence")
    }

    func testSortOrderPriorityThenTime() {
        let old = makeDebtItem(chatUsername: "wxid_old", priority: .p1, score: 6, timestamp: Date().addingTimeInterval(-600))
        let urgent = makeDebtItem(chatUsername: "wxid_urgent", priority: .p0, score: 9, timestamp: Date().addingTimeInterval(-60))
        let items = InboxBuilder.build(replyDebtItems: [old, urgent], notifications: [], dismissed: [:])
        XCTAssertEqual(items[0].chatUsername, "wxid_urgent", "p0 should come first")
        XCTAssertEqual(items[1].chatUsername, "wxid_old")
    }

    func testActionRequiredBeforeInfoOnly() {
        let action = makeDebtItem(chatUsername: "wxid_action", priority: .p1)
        let info = makeNotification(chatUsername: "wxid_info", attentionLevel: .whitelist)
        let items = InboxBuilder.build(replyDebtItems: [action], notifications: [info], dismissed: [:])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].actionRequired)
        XCTAssertFalse(items[1].actionRequired)
    }

    func testDismissedItemFiltered() {
        let debt = makeDebtItem(chatUsername: "wxid_dismissed")
        let dismissed: [String: Int64] = ["wxid_dismissed": 999]
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: dismissed)
        XCTAssertTrue(items.isEmpty, "dismissed item should not appear")
    }

    func testDismissedItemReactivatedByNewerMessage() {
        let debt = makeDebtItem(chatUsername: "wxid_reactivated")
        // dismissedAtMsgId = 100 but the item's message is newer (simulated by builder)
        // InboxBuilder compares timestamp — if debt exists, its message is newer than dismiss
        let dismissed: [String: Int64] = ["wxid_reactivated": 100]
        // debt item exists = there IS a newer inbound message since last outbound
        // So InboxBuilder should include it — the ScanEngine wouldn't produce a
        // ReplyDebtItem if the user had already replied.
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: dismissed)
        // ReplyDebtItem existing means ScanEngine found unreplied inbound → reactivate
        XCTAssertEqual(items.count, 1, "debt item means newer message exists → reactivate")
    }

    func testInfoItemsCappedAtFive() {
        let notifs = (0..<10).map { i in
            makeNotification(chatUsername: "wxid_\(i)", chatName: "Chat\(i)", attentionLevel: .whitelist)
        }
        let items = InboxBuilder.build(replyDebtItems: [], notifications: notifs, dismissed: [:])
        let infoItems = items.filter { !$0.actionRequired }
        XCTAssertEqual(infoItems.count, 5, "info-only items capped at 5")
    }

    func testVIPNotificationWithAtMentionIsActionRequired() {
        let notif = makeNotification(chatUsername: "wxid_vip_at", attentionLevel: .vip, isAtMention: true)
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].actionRequired, "@mention from VIP is action-required")
        XCTAssertEqual(items[0].priority, .p0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InboxBuilderTests 2>&1 | tail -5`
Expected: compilation error — `InboxBuilder` not defined

- [ ] **Step 3: Implement InboxBuilder**

```swift
// Sources/WeChatHUD/Services/InboxBuilder.swift
import Foundation

enum InboxBuilder {

    /// Merge reply-debt items and whitelist notifications into a single
    /// priority-sorted inbox. Deduplicates by chatUsername — debt items
    /// take precedence over pure notifications.
    ///
    /// - Parameters:
    ///   - replyDebtItems: from ScanEngine (already scored/sorted)
    ///   - notifications: from whitelist scan (HUDNotification)
    ///   - dismissed: map of chatUsername → dismissedAtMsgId. If a chat
    ///     has a ReplyDebtItem (meaning newer unreplied inbound exists),
    ///     it reactivates regardless of dismiss state. Pure notifications
    ///     stay dismissed.
    static func build(
        replyDebtItems: [ReplyDebtItem],
        notifications: [HUDNotification],
        dismissed: [String: Int64]
    ) -> [InboxItem] {
        var seen = Set<String>()
        var actionItems: [InboxItem] = []
        var infoItems: [InboxItem] = []

        // 1. ReplyDebtItems → always actionRequired, always reactivate
        for debt in replyDebtItems {
            seen.insert(debt.chatUsername)
            let item = InboxItem(
                id: debt.chatUsername,
                chatUsername: debt.chatUsername,
                chatName: debt.chatName,
                senderName: debt.senderName,
                preview: debt.preview,
                isGroup: debt.isGroup,
                timestamp: debt.timestamp,
                actionRequired: true,
                priority: mapPriority(debt.priority),
                isVIP: debt.isVIP,
                isWhitelisted: debt.isWhitelisted,
                unreadCount: debt.unreadCount,
                isAtMention: debt.isAtMention,
                askType: .none,
                reasons: debt.reasons,
                suggestedReplyMinutes: debt.suggestedReplyMinutes,
                status: .active,
                dismissedAtMsgId: nil
            )
            actionItems.append(item)
        }

        // 2. Notifications not already covered by debt items
        for notif in notifications {
            guard !seen.contains(notif.chatUsername) else { continue }
            seen.insert(notif.chatUsername)

            // Skip dismissed pure notifications
            if dismissed[notif.chatUsername] != nil { continue }

            let isAction = notif.isAtMention || notif.attentionLevel == .vip && notif.isAtMention
            let priority: InboxPriority
            if notif.isAtMention && notif.attentionLevel == .vip {
                priority = .p0
            } else if notif.isAtMention {
                priority = .p1
            } else {
                priority = .p2
            }

            let item = InboxItem(
                id: notif.chatUsername,
                chatUsername: notif.chatUsername,
                chatName: notif.chatName,
                senderName: notif.senderName,
                preview: notif.snippet,
                isGroup: notif.kind == .groupAt || notif.kind == .groupMessage,
                timestamp: notif.timestamp,
                actionRequired: isAction,
                priority: priority,
                isVIP: notif.attentionLevel == .vip,
                isWhitelisted: notif.attentionLevel == .vip || notif.attentionLevel == .whitelist,
                unreadCount: 0,
                isAtMention: notif.isAtMention,
                askType: .none,
                reasons: [],
                suggestedReplyMinutes: 0,
                status: .active,
                dismissedAtMsgId: nil
            )

            if isAction {
                actionItems.append(item)
            } else {
                infoItems.append(item)
            }
        }

        // 3. Sort: action items by priority then timestamp
        actionItems.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.timestamp > rhs.timestamp
        }

        // 4. Cap info items at 5, sorted by timestamp
        infoItems.sort { $0.timestamp > $1.timestamp }
        let cappedInfo = Array(infoItems.prefix(5))

        return actionItems + cappedInfo
    }

    private static func mapPriority(_ p: ReplyDebtPriority) -> InboxPriority {
        switch p {
        case .p0: return .p0
        case .p1: return .p1
        case .p2: return .p2
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter InboxBuilderTests 2>&1 | tail -5`
Expected: `Test Suite 'InboxBuilderTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/InboxBuilder.swift Tests/WeChatHUDTests/InboxBuilderTests.swift
git commit -m "feat(inbox): add InboxBuilder with merge/dedup/sort logic"
```

---

### Task 3: ChatMonitor — Publish inboxItems

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add @Published property and dismissed state**

At the top of ChatMonitor (near line 68, after `@Published var replyDebtItems`), add:

```swift
    @Published var inboxItems: [InboxItem] = []
    /// Tracks dismissed inbox items: chatUsername → msgId at time of dismiss.
    private var dismissedInbox: [String: Int64] = [:]
```

- [ ] **Step 2: Call InboxBuilder after scan results are applied**

In the `scan()` method, after the existing batched apply block (after line 810 `latestNotification = latest`), add:

```swift
        // Build unified inbox from scan results
        inboxItems = InboxBuilder.build(
            replyDebtItems: replyDebtItems,
            notifications: recentNotifications,
            dismissed: dismissedInbox
        )
```

- [ ] **Step 3: Add dismiss method**

After `loadReplySuggestions(for:)` method (around line 1310), add:

```swift
    /// Dismiss an inbox item. It will reactivate if a new message arrives
    /// (ScanEngine produces a new ReplyDebtItem for the chat).
    func dismissInboxItem(_ item: InboxItem) {
        dismissedInbox[item.chatUsername] = Int64(item.timestamp.timeIntervalSince1970)
        inboxItems = InboxBuilder.build(
            replyDebtItems: replyDebtItems,
            notifications: recentNotifications,
            dismissed: dismissedInbox
        )
    }
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat(inbox): publish inboxItems from ChatMonitor"
```

---

### Task 4: InboxRowView — Single Row Component

**Files:**
- Create: `Sources/WeChatHUD/Views/InboxRowView.swift`

- [ ] **Step 1: Create the row view**

```swift
// Sources/WeChatHUD/Views/InboxRowView.swift
import SwiftUI

/// A single row in the unified inbox list.
struct InboxRowView: View {
    let item: InboxItem
    let onDismiss: () -> Void
    @State private var hovered = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                priorityBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.chatName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        if item.isVIP {
                            Text("VIP")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(2)
                        }
                        if item.isGroup {
                            Text("群聊")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        Spacer()
                        Text(timeAgo(item.timestamp))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    HStack(spacing: 4) {
                        if item.isGroup {
                            Text(item.senderName + ":")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        Text(item.preview)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                if hovered {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { expanded.toggle() }

            if expanded && item.actionRequired {
                // Reuse existing ReplyDebtExpandedView by converting InboxItem
                // to the ReplyDebtItem it wraps. The expanded view loads AI
                // reply suggestions.
                ReplyDebtExpandedView(item: item.toReplyDebtItem())
            }
        }
    }

    private var priorityBadge: some View {
        let (color, label) = priorityDisplay(item.priority, actionRequired: item.actionRequired)
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .frame(width: 22, height: 16)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private func priorityDisplay(_ p: InboxPriority, actionRequired: Bool) -> (Color, String) {
        guard actionRequired else { return (.white.opacity(0.3), "📋") }
        switch p {
        case .p0: return (.red, "P0")
        case .p1: return (.yellow, "P1")
        case .p2: return (.white.opacity(0.5), "P2")
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        return "\(hours / 24)天前"
    }
}
```

- [ ] **Step 2: Add `toReplyDebtItem()` conversion on InboxItem**

Append to `Sources/WeChatHUD/Data/InboxItem.swift`:

```swift
extension InboxItem {
    /// Convert to ReplyDebtItem for compatibility with ReplyDebtExpandedView.
    func toReplyDebtItem() -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: preview,
            latestOutboundPreview: nil,
            timestamp: timestamp,
            priority: {
                switch priority {
                case .p0: return .p0
                case .p1: return .p1
                case .p2: return .p2
                }
            }(),
            score: priority == .p0 ? 9 : priority == .p1 ? 6 : 3,
            unreadCount: unreadCount,
            isGroup: isGroup,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            isAtMention: isAtMention,
            inboundCountSinceLastOutbound: 1,
            reasons: reasons,
            suggestedReplyMinutes: suggestedReplyMinutes
        )
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/InboxRowView.swift Sources/WeChatHUD/Data/InboxItem.swift
git commit -m "feat(inbox): add InboxRowView with priority badge and dismiss"
```

---

### Task 5: InboxView — Main Inbox List

**Files:**
- Create: `Sources/WeChatHUD/Views/InboxView.swift`

- [ ] **Step 1: Create the inbox view**

```swift
// Sources/WeChatHUD/Views/InboxView.swift
import SwiftUI

/// Unified inbox — replaces ExtendedTabsView. Shows all messages in a
/// single priority-sorted list with an action section on top and an
/// info-only section below.
struct InboxView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Smart Digest banner
            if panelState.showSmartDigest {
                smartDigestBanner
            }
            header
            Divider().background(Color.white.opacity(0.08))
            if monitor.inboxItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let actionItems = monitor.inboxItems.filter { $0.actionRequired }
                        let infoItems = monitor.inboxItems.filter { !$0.actionRequired }

                        ForEach(actionItems) { item in
                            InboxRowView(item: item) {
                                monitor.dismissInboxItem(item)
                            }
                        }

                        if !infoItems.isEmpty {
                            infoSectionHeader
                            ForEach(infoItems) { item in
                                InboxRowView(item: item) {
                                    monitor.dismissInboxItem(item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
            Text("收件箱")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("\(actionCount)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(actionCount > 0 ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                .foregroundColor(actionCount > 0 ? .red : .white.opacity(0.5))
                .cornerRadius(3)
            Spacer()
            if let syncAt = monitor.stats.lastSyncAt {
                Text(syncLabel(syncAt))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            Button(action: { panelState.showDetail() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Info section divider

    private var infoSectionHeader: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            Text("仅通知")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.25))
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("没有待处理消息")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            if let syncAt = monitor.stats.lastSyncAt {
                Text("上次同步: \(syncLabel(syncAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Smart Digest banner

    private var smartDigestBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text("你离开了一段时间")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Button("知道了") {
                panelState.showSmartDigest = false
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Helpers

    private func syncLabel(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚同步" }
        return "\(seconds / 60)分钟前同步"
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/InboxView.swift
git commit -m "feat(inbox): add InboxView as unified inbox list"
```

---

### Task 6: Wire InboxView Into HUDRootView + AppDelegate

**Files:**
- Modify: `Sources/WeChatHUD/Views/HUDRootView.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`

- [ ] **Step 1: Replace ExtendedTabsView with InboxView in HUDRootView**

Replace the entire `.extended` case in HUDRootView (lines 28-51) with:

```swift
            case .extended:
                let itemCount = monitor.inboxItems.count
                let (w, h) = inboxSize(itemCount: itemCount)
                InboxView()
                    .frame(width: w, height: h)
```

Remove the old `extendedTabsSize` call and the `.compact` EmptyView case. The full switch becomes:

```swift
        Group {
            switch panelState.currentState {
            case .compact, .extended:
                let itemCount = monitor.inboxItems.count
                let (w, h) = inboxSize(itemCount: itemCount)
                InboxView()
                    .frame(width: w, height: h)
            case .notification:
                if let notif = monitor.latestNotification {
                    NotificationBannerView(notification: notif)
                }
            case .detail:
                DetailPanelView()
            }
        }
```

Replace the `extendedTabsSize` function at the bottom of HUDRootView with:

```swift
/// Size of the inbox panel for given item count.
func inboxSize(itemCount: Int) -> (CGFloat, CGFloat) {
    if itemCount == 0 {
        return (400, 120)  // empty state
    }
    let rows = min(CGFloat(itemCount), 10)
    let bodyHeight = max(60, rows * 38)
    let height: CGFloat = min(38 + 1 + bodyHeight + 6, 480)
    return (480, height)
}
```

- [ ] **Step 2: Update AppDelegate panel sizing**

In `panelSize(for:)` (AppDelegate.swift around line 334), replace the `.extended` case:

```swift
        case .compact, .extended:
            let count = monitor.inboxItems.count
            if count == 0 {
                return (400, 120)
            }
            return inboxSize(itemCount: count)
```

Replace the resize sink subscriptions (lines 125-153). Remove the 6 individual sinks for `unreadItems`, `suppressedItems`, `recentNotifications`, `replyDebtItems`, `commitments`, `recalledMessages`. Replace with a single sink:

```swift
        monitor.$inboxItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/HUDRootView.swift Sources/WeChatHUD/App/AppDelegate.swift
git commit -m "feat(inbox): wire InboxView into HUDRootView and AppDelegate"
```

---

### Task 7: Relocate Low-Frequency Features to Settings Panel

**Files:**
- Modify: `Sources/WeChatHUD/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add new sidebar tabs**

In the `Tab` enum inside SettingsView, add three new cases after `.ignored`:

```swift
        case dailyReport
        case commitments
        case autopilotDashboard
```

Add to `label`:
```swift
            case .dailyReport:          return "日报"
            case .commitments:          return "承诺"
            case .autopilotDashboard:   return "托管面板"
```

Add to `icon`:
```swift
            case .dailyReport:          return "doc.text.fill"
            case .commitments:          return "checkmark.circle.fill"
            case .autopilotDashboard:   return "robot"
```

Add to `tint`:
```swift
            case .dailyReport:          return .mint
            case .commitments:          return .pink
            case .autopilotDashboard:   return .cyan
```

Add to `subtitle`:
```swift
            case .dailyReport:          return "查看日报和周报摘要。"
            case .commitments:          return "追踪你和对方的承诺和待办。"
            case .autopilotDashboard:   return "自动回复活动日志和会话统计。"
```

- [ ] **Step 2: Add content routing**

In the SettingsView body, find the `switch selectedTab` content pane and add cases. The existing tab views (`DailyReportTabView`, `CommitmentTabView`, `AutopilotTabView`) are reused directly:

```swift
            case .dailyReport:
                DailyReportTabView()
            case .commitments:
                CommitmentTabView()
            case .autopilotDashboard:
                AutopilotTabView()
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/Settings/SettingsView.swift
git commit -m "feat(inbox): relocate 日报/承诺/托管 to settings panel"
```

---

### Task 8: Clean Up — Remove Dead Tab Code

**Files:**
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift` (delete or gut)
- Modify: `Sources/WeChatHUD/Views/HUDRootView.swift` (remove extendedTabsSize import if needed)

- [ ] **Step 1: Remove ExtendedTabsView tab routing**

The file `ExtendedTabsView.swift` is no longer referenced by HUDRootView. However, it may still contain `ExtendedBarView` (the empty-state compact bar) which is also unused now. Verify no other file imports it:

Run: `grep -r "ExtendedTabsView\|ExtendedBarView" Sources/ --include="*.swift" -l`

If only `ExtendedTabsView.swift` itself and docs reference it, the file can be left as-is (dead code) or gutted. Leave the file in place for now — removing it is cosmetic and can be done in a follow-up cleanup.

- [ ] **Step 2: Remove CatchupTabView from main tab routing**

CatchupTabView is no longer reachable from any view (inbox replaced tabs, settings doesn't include it). Verify:

Run: `grep -r "CatchupTabView" Sources/ --include="*.swift" -l`

If only referenced in ExtendedTabsView.swift (which is dead), no action needed.

- [ ] **Step 3: Final build + test**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

Run: `swift test --filter InboxBuilderTests 2>&1 | tail -5`
Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "chore(inbox): verify dead tab code is unreachable"
```

---

### Task 9: Integration Test — Build, Package, Launch

- [ ] **Step 1: Release build**

Run: `swift build -c release 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 2: Package and launch**

Run: `make app && open .build/WeChatHUD.app`

- [ ] **Step 3: Manual verification checklist**

1. App launches directly into inbox view (no compact bar, no tabs)
2. Header shows "收件箱 (N)" with action item count
3. Action items (P0/P1) appear above the "仅通知" divider
4. Info-only items appear below the divider
5. Hover on a row shows X dismiss button
6. Click dismiss removes the item
7. Click an action item expands reply suggestions
8. Gear icon opens settings panel
9. Settings panel has 日报/承诺/托管 in the sidebar
10. Empty inbox shows "没有待处理消息" + sync time

- [ ] **Step 4: Commit all remaining changes**

```bash
git add -A
git commit -m "feat(inbox): unified inbox complete — single priority-sorted list"
```
