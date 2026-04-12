# WeChatHUD Frontend AI Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire all 11 backend AI services into the existing WeChatHUD SwiftUI frontend — new views, data flow, and panel sizing.

**Architecture:** Add `@Published` properties to ChatMonitor for new data (commitments, recalled messages, VIP insights, whitelist suggestions, daily report). Create focused View files for each feature. Modify ExtendedTabsView to add a 4th "日报" tab and support row expansion. Keep all AI calls async with loading states.

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSPasteboard, AppleScript), Swift Concurrency (async/await, actors)

---

## File Map

**New files:**
- `Sources/WeChatHUD/Views/ReplyDebtExpandedView.swift` — Reply suggestion expansion inside ReplyDebtRow
- `Sources/WeChatHUD/Views/DailyReportTabView.swift` — 日报 tab with retrospective + commitments
- `Sources/WeChatHUD/Views/VIPInsightCardView.swift` — Expandable VIP insight card
- `Sources/WeChatHUD/Views/RecalledMessageRow.swift` — Special row for recalled messages
- `Sources/WeChatHUD/Views/WhitelistScanView.swift` — Batch scan UI in settings
- `Sources/WeChatHUD/Views/WhitelistSuggestionBadge.swift` — Inline "建议关注" badge

**Modified files:**
- `Sources/WeChatHUD/Services/ChatMonitor.swift` — New @Published properties + AI service wiring
- `Sources/WeChatHUD/Views/ExtendedTabsView.swift` — 4th tab, row expansion support, VIP/recall badges
- `Sources/WeChatHUD/Views/HUDRootView.swift` — Pass new data to ExtendedTabsView, update sizing
- `Sources/WeChatHUD/Views/GroupContextBriefingButton.swift` — Enhanced popover with ContextAnalyzer
- `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift` — AI scan button
- `Sources/WeChatHUD/App/AppDelegate.swift` — Panel sizing for 日报 tab
- `Sources/WeChatHUD/Services/WeChatLauncher.swift` — Paste-to-WeChat helper

---

### Task 1: ChatMonitor Data Layer — New @Published Properties

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift:28-47`

- [ ] **Step 1: Add new published properties to ChatMonitor**

Add after the existing `@Published var groupContextStates` (line 47):

```swift
    /// Commitments extracted from user's outgoing messages.
    @Published var commitments: [Commitment] = []
    /// Recalled messages with AI analysis.
    @Published var recalledMessages: [RecalledMessage] = []
    /// VIP aggregate insights keyed by vip username.
    @Published var vipInsights: [String: VIPAggregator.AggregateResult] = [:]
    /// AI-suggested whitelist additions keyed by chat username.
    @Published var whitelistSuggestions: [String: AIWhitelistCategorizer.Suggestion] = [:]
    /// Cached daily retrospective, regenerated every 30 minutes.
    @Published var dailyReport: AIDailyRetrospector.Retrospective? = nil
    var dailyReportGeneratedAt: Date? = nil
```

- [ ] **Step 2: Add data loading methods**

Add these methods to ChatMonitor:

```swift
    /// Reload commitments and recalled messages from store.
    func reloadAIData() {
        commitments = store.loadCommitments()
        recalledMessages = store.loadRecalledMessages(limit: 50)
    }

    /// Load or refresh daily report. Only calls AI if stale (>30 min).
    func loadDailyReport(force: Bool = false) async {
        if !force, let gen = dailyReportGeneratedAt,
           Date().timeIntervalSince(gen) < 1800,
           dailyReport != nil {
            return // cached and fresh
        }
        let cfg = store.loadClassifierConfig()
        let retrospector = AIDailyRetrospector(store: store, config: cfg)
        let pending = store.loadPendingAsks(status: .pending)
        let handled = store.loadPendingAsks(status: .done)
        let input = AIDailyRetrospector.Input(
            date: {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: Date())
            }(),
            handled: handled,
            pending: pending,
            messageCount: stats.unreadCount,
            focusDurationMinutes: 0
        )
        dailyReport = await retrospector.retrospect(input)
        dailyReportGeneratedAt = Date()
    }

    /// Generate reply suggestions for a reply debt item.
    func loadReplySuggestions(for item: ReplyDebtItem) async -> [AIReplySuggester.Suggestion] {
        let cfg = store.loadClassifierConfig()
        let suggester = AIReplySuggester(store: store, config: cfg)
        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: .none,
            relationship: "work"
        )
        return await suggester.suggest(input) ?? []
    }
```

- [ ] **Step 3: Call reloadAIData at end of scan cycle**

In the scan completion block (after line 654 where `stats = o.stats`), add:

```swift
        reloadAIData()
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat: add ChatMonitor published properties for AI data layer"
```

---

### Task 2: Reply Suggestion Expansion View

**Files:**
- Create: `Sources/WeChatHUD/Views/ReplyDebtExpandedView.swift`

- [ ] **Step 1: Create the reply suggestion expansion view**

```swift
import SwiftUI
import AppKit

/// Expandable reply suggestion area shown below a ReplyDebtRow.
/// Loads 3 AI reply candidates, lets user click to copy + optionally
/// open WeChat and paste.
struct ReplyDebtExpandedView: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: ReplyDebtItem

    @State private var suggestions: [AIReplySuggester.Suggestion] = []
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 9))
                Text("候选回复")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }
            .foregroundColor(.white.opacity(0.6))

            if suggestions.isEmpty && !isLoading {
                Text("暂无回复建议")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    SuggestionRow(suggestion: suggestion, chatName: item.chatName)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            isLoading = true
            suggestions = await monitor.loadReplySuggestions(for: item)
            isLoading = false
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: AIReplySuggester.Suggestion
    let chatName: String
    @State private var hovered = false

    var body: some View {
        Button {
            copyAndOffer()
        } label: {
            HStack(spacing: 8) {
                Text(toneLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(toneColor)
                    .frame(width: 30)
                Text(suggestion.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var toneLabel: String {
        switch suggestion.tone.lowercased() {
        case "friendly": return "友好"
        case "formal":   return "正式"
        case "brief":    return "简洁"
        default:         return suggestion.tone
        }
    }

    private var toneColor: Color {
        switch suggestion.tone.lowercased() {
        case "friendly": return .green
        case "formal":   return .blue
        case "brief":    return .orange
        default:         return .white
        }
    }

    private func copyAndOffer() {
        WeChatLauncher.copyText(suggestion.text)

        let alert = NSAlert()
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = "是否打开微信对话框并粘贴？"
        alert.addButton(withTitle: "打开并粘贴")
        alert.addButton(withTitle: "仅复制")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            WeChatLauncher.openChat(named: chatName)
            // Brief delay for WeChat to focus, then paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WeChatLauncher.pasteClipboard()
            }
        }
    }
}
```

- [ ] **Step 2: Add pasteClipboard helper to WeChatLauncher**

Add to `Sources/WeChatHUD/Services/WeChatLauncher.swift`:

```swift
    /// Simulate Cmd+V paste into the frontmost application.
    static func pasteClipboard() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'v'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/ReplyDebtExpandedView.swift Sources/WeChatHUD/Services/WeChatLauncher.swift
git commit -m "feat: add ReplyDebtExpandedView with AI reply suggestions + paste helper"
```

---

### Task 3: Wire Reply Expansion into ReplyDebtRow

**Files:**
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift` (ReplyDebtRow, lines 682-829)

- [ ] **Step 1: Add expansion state to ReplyDebtRow**

In the `ReplyDebtRow` struct (line 682), add:

```swift
    @State private var isExpanded = false
```

- [ ] **Step 2: Replace the onTapGesture in ReplyDebtRow body**

Replace the existing `.onTapGesture` block (around line 740-746):

```swift
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    WeChatLauncher.copyText("\(item.senderName): \(item.preview)")
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }
```

- [ ] **Step 3: Add the expansion view after the row content**

After the closing `}` of `FirstMouseRowHost` and before `.frame(maxWidth:)`, insert:

```swift
        if isExpanded {
            ReplyDebtExpandedView(item: item)
        }
```

Wrap both in a VStack:

```swift
    var body: some View {
        VStack(spacing: 0) {
            FirstMouseRowHost {
                // ... existing row content ...
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                ReplyDebtExpandedView(item: item)
            }
        }
    }
```

- [ ] **Step 4: Add "打开微信" to context menu**

The existing context menu already has "在微信中打开". Add a reply suggestion entry after it:

```swift
            Button {
                withAnimation { isExpanded = true }
            } label: {
                Label("AI 回复建议", systemImage: "sparkles")
            }
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat: wire reply suggestion expansion into ReplyDebtRow"
```

---

### Task 4: Daily Report Tab View

**Files:**
- Create: `Sources/WeChatHUD/Views/DailyReportTabView.swift`

- [ ] **Step 1: Create the daily report tab view**

```swift
import SwiftUI
import AppKit

/// Fourth tab in ExtendedTabsView — daily retrospective + commitment tracking.
struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewSection
                if let report = monitor.dailyReport {
                    summarySection(report)
                    tomorrowSection(report)
                    commitmentSection
                    dailyReportDraft(report)
                } else {
                    loadingOrEmpty
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日概览")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(todayString)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                statPill("消息", value: "\(monitor.stats.unreadCount)")
                statPill("待处理", value: "\(monitor.commitments.filter { $0.status == .pending }.count)")
                statPill("承诺", value: "\(monitor.commitments.count)")
            }
        }
    }

    private func summarySection(_ report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("今日总结")
            Text(report.todaySummary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tomorrowSection(_ report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("明天第一件事")
            HStack(spacing: 6) {
                Image(systemName: "alarm")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text(report.tomorrowFirstThing.action)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }

    private var commitmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("承诺追踪")
            let sorted = monitor.commitments.sorted { a, b in
                a.status.sortOrder < b.status.sortOrder
            }
            if sorted.isEmpty {
                Text("暂无承诺记录")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(sorted, id: \.id) { commitment in
                    CommitmentRow(commitment: commitment)
                }
            }
        }
    }

    private func dailyReportDraft(_ report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("微信日报草稿")
                Spacer()
                Button("复制") {
                    WeChatLauncher.copyText(report.wechatDailyReport)
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            Text(report.wechatDailyReport)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var loadingOrEmpty: some View {
        if monitor.dailyReport == nil && monitor.dailyReportGeneratedAt == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在生成日报…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.vertical, 20)
        } else {
            Text("日报生成失败，请稍后重试")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.vertical, 20)
        }
    }

    private func statPill(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.06))
        .cornerRadius(5)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.5))
    }

    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

private struct CommitmentRow: View {
    let commitment: Commitment

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(commitment.content)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                if let deadline = commitment.deadlineAt {
                    Text(relativeDeadline(deadline))
                        .font(.system(size: 9))
                        .foregroundColor(deadlineColor(deadline))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch commitment.status {
        case .overdue:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .pending:
            Circle().fill(Color.yellow).frame(width: 8, height: 8)
        case .fulfilled:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
    }

    private func relativeDeadline(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff < 0 {
            let hours = Int(-diff / 3600)
            return hours > 24 ? "逾期 \(hours / 24) 天" : "逾期 \(hours) 小时"
        } else {
            let hours = Int(diff / 3600)
            return hours > 24 ? "\(hours / 24) 天后到期" : "\(hours) 小时后到期"
        }
    }

    private func deadlineColor(_ date: Date) -> Color {
        date < Date() ? .red : .white.opacity(0.5)
    }
}

private extension CommitmentStatus {
    var sortOrder: Int {
        switch self {
        case .overdue: return 0
        case .pending: return 1
        case .fulfilled: return 2
        case .cancelled: return 3
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportTabView.swift
git commit -m "feat: add DailyReportTabView with retrospective + commitment tracking"
```

---

### Task 5: Add 日报 Tab to ExtendedTabsView

**Files:**
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift`
- Modify: `Sources/WeChatHUD/Views/HUDRootView.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`

- [ ] **Step 1: Add .dailyReport case to Tab enum**

In `ExtendedTabsView`, update the `Tab` enum (line 22):

```swift
    enum Tab {
        case vip
        case unread
        case replyDebt
        case dailyReport
    }
```

- [ ] **Step 2: Add 日报 tab button to tabBar**

In the `tabBar` computed property, add before `Spacer()` (around line 111):

```swift
            tabButton(.dailyReport, label: "日报", count: 0)
```

- [ ] **Step 3: Add dailyReport case to the body switch**

In the `body` switch (around line 66), add:

```swift
                    case .dailyReport: DailyReportTabView()
```

- [ ] **Step 4: Update extendedTabsSize to account for 日报 tab**

In `HUDRootView.swift`, update `extendedTabsSize` (line 75) to handle the daily report tab's fixed height:

```swift
func extendedTabsSize(vip: Int, unread: Int, replyDebt: Int, hasDailyReport: Bool = true) -> (CGFloat, CGFloat) {
    let vipRows = min(CGFloat(max(vip, 0)), 10)
    let unreadRows = min(CGFloat(max(unread, 0)), 10)
    let replyDebtRows = min(CGFloat(max(replyDebt, 0)), 8)

    let vipSectionHeaderBudget: CGFloat = vip > 0 ? 40 : 0
    let vipBodyHeight = max(50, vipRows * 34 + vipSectionHeaderBudget)
    let unreadBodyHeight = max(50, unreadRows * 30)
    let replyDebtBodyHeight = max(70, replyDebtRows * 42)
    let dailyReportBodyHeight: CGFloat = 360  // fixed scrollable height
    let bodyHeight = max(vipBodyHeight, unreadBodyHeight, replyDebtBodyHeight, dailyReportBodyHeight)
    let height: CGFloat = min(38 + 1 + bodyHeight + 6, 500)
    let width: CGFloat = replyDebt > 0 ? 520 : 480
    return (width, height)
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Views/ExtendedTabsView.swift Sources/WeChatHUD/Views/HUDRootView.swift
git commit -m "feat: add 日报 tab to ExtendedTabsView with panel sizing"
```

---

### Task 6: VIP Insight Card + Inline Tags

**Files:**
- Create: `Sources/WeChatHUD/Views/VIPInsightCardView.swift`
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift` (MessageRow)

- [ ] **Step 1: Create VIPInsightCardView**

```swift
import SwiftUI

/// Expandable VIP insight card showing mood, urgency, recommended action.
struct VIPInsightCardView: View {
    let insight: VIPAggregator.AggregateResult
    let vipName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mood trend
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 9))
                    Text("情绪趋势")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.6))
                Text("\(insight.mood) — \(insight.moodEvidence)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Recommended action
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.system(size: 9))
                    Text("建议行动")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.6))
                Text(insight.recommendedAction)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                if !insight.actionTiming.isEmpty {
                    Text("建议时机：\(insight.actionTiming)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            // Key topics
            if !insight.keyTopics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关键话题")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    HStack(spacing: 4) {
                        ForEach(insight.keyTopics, id: \.self) { topic in
                            Text(topic)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(3)
                        }
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }
}

/// Inline mood + urgency tags for VIP message rows.
struct VIPInlineTags: View {
    let insight: VIPAggregator.AggregateResult

    var body: some View {
        HStack(spacing: 4) {
            if !insight.mood.isEmpty {
                miniTag("情绪:\(insight.mood)", color: moodColor)
            }
            if insight.urgency == "urgent" || insight.urgency == "high" {
                miniTag("紧急", color: .red)
            }
        }
    }

    private func miniTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private var moodColor: Color {
        switch insight.mood.lowercased() {
        case let m where m.contains("焦虑") || m.contains("不满") || m.contains("angry"):
            return .red
        case let m where m.contains("紧张") || m.contains("担忧"):
            return .orange
        case let m where m.contains("平静") || m.contains("满意"):
            return .green
        default:
            return .white.opacity(0.7)
        }
    }
}
```

- [ ] **Step 2: Wire VIP tags into MessageRow**

In `ExtendedTabsView.swift`, in the `MessageRow` body HStack, after the VIP badge and before `GroupContextBriefingButton`, add:

```swift
                if notification.isVIP,
                   let insight = monitor.vipInsights[notification.chatUsername] {
                    VIPInlineTags(insight: insight)
                }
```

- [ ] **Step 3: Add VIP card expansion to MessageRow**

Add `@State private var showInsight = false` to MessageRow, and wrap the body in a VStack:

```swift
    var body: some View {
        VStack(spacing: 0) {
            FirstMouseRowHost {
                // ... existing HStack content ...
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        WeChatLauncher.copyText("\(notification.senderName): \(notification.snippet)")
                    } else if notification.isVIP && monitor.vipInsights[notification.chatUsername] != nil {
                        withAnimation(.easeInOut(duration: 0.2)) { showInsight.toggle() }
                    } else {
                        WeChatLauncher.openChat(named: notification.chatName)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showInsight, let insight = monitor.vipInsights[notification.chatUsername] {
                VIPInsightCardView(insight: insight, vipName: notification.senderName)
            }
        }
    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/VIPInsightCardView.swift Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat: add VIP insight cards with inline mood/urgency tags"
```

---

### Task 7: Recalled Message Row

**Files:**
- Create: `Sources/WeChatHUD/Views/RecalledMessageRow.swift`
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift` (vipContent)

- [ ] **Step 1: Create RecalledMessageRow**

```swift
import SwiftUI

/// Row for recalled messages with AI analysis.
struct RecalledMessageRow: View {
    let recalled: RecalledMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(recalled.senderName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("撤回了一条消息")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer(minLength: 0)
                        Text(relativeTime(recalled.recalledAt))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                            .monospacedDigit()
                    }
                    Text("原文：\(recalled.originalText)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        if let value = recalled.aiIntelligenceValue {
                            valueBadge(value)
                        }
                        if let reason = recalled.aiReason {
                            Text(reason)
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.06))
            .overlay(
                Rectangle()
                    .fill(intelligenceColor.opacity(0.8))
                    .frame(width: 2),
                alignment: .leading
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { expanded.toggle() }
            }

            if expanded, let detail = recalled.aiDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func valueBadge(_ value: String) -> some View {
        Text("情报:\(value == "high" ? "高" : value == "medium" ? "中" : "低")")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(intelligenceColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(intelligenceColor.opacity(0.12))
            .cornerRadius(3)
    }

    private var intelligenceColor: Color {
        switch recalled.aiIntelligenceValue {
        case "high": return .red
        case "medium": return .orange
        default: return .white.opacity(0.5)
        }
    }
}

private func relativeTime(_ date: Date) -> String {
    let diff = Int(Date().timeIntervalSince(date))
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(diff / 60)分前" }
    if diff < 86400 { return "\(diff / 3600)时前" }
    return "\(diff / 86400)天前"
}
```

- [ ] **Step 2: Add recalled messages to vipContent in ExtendedTabsView**

In `vipContent`, after the whitelist section, add:

```swift
                let notifiableRecalls = monitor.recalledMessages.filter { $0.aiShouldNotify == true }
                if !notifiableRecalls.isEmpty {
                    sectionHeader("撤回消息", count: notifiableRecalls.count)
                    ForEach(notifiableRecalls, id: \.id) { recalled in
                        RecalledMessageRow(recalled: recalled)
                    }
                }
```

Add `@EnvironmentObject var monitor: ChatMonitor` to `ExtendedTabsView` if not already present. The `vipContent` currently uses `vipNotifications` passed as a let — since `monitor` is already in the environment, access it directly.

- [ ] **Step 3: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/RecalledMessageRow.swift Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat: add recalled message rows with AI analysis to 关注 tab"
```

---

### Task 8: Enhanced "什么情况" Popover (GroupCatchup + ContextAnalyzer)

**Files:**
- Modify: `Sources/WeChatHUD/Views/GroupContextBriefingButton.swift`

- [ ] **Step 1: Add ContextAnalyzer fields to GroupContextBriefing model**

In `Sources/WeChatHUD/Data/Models.swift`, add optional deep-analysis fields to `GroupContextBriefing`:

```swift
    // Deep analysis fields (from ContextAnalyzer, loaded async)
    var deepBackground: String?
    var deepWhatTheyWant: String?
    var deepHiddenContext: String?
    var deepStakeholders: [String]?   // ["张总(决策者)", "李姐(执行)"]
    var deepYourPosition: String?
    var deepSuggestedAction: String?
    var deepSuggestedTiming: String?
    var deepRiskIfIgnore: String?
```

- [ ] **Step 2: Extend the popover body to show deep analysis**

In `GroupContextBriefingButton.swift`, in `GroupContextBriefingPopover.briefingBody`, after the existing sections add:

```swift
            // Deep analysis section (from ContextAnalyzer)
            if let bg = briefing.deepBackground {
                Divider()
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("深度分析")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary)
                    section("背景", text: bg)
                    if let want = briefing.deepWhatTheyWant {
                        section("他想要什么", text: want)
                    }
                    if let stakeholders = briefing.deepStakeholders, !stakeholders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("利益相关方")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                            FlowChips(items: stakeholders)
                        }
                    }
                    if let position = briefing.deepYourPosition {
                        section("你的立场", text: position)
                    }
                    if let action = briefing.deepSuggestedAction {
                        section("建议行动", text: action)
                    }
                    if let timing = briefing.deepSuggestedTiming {
                        section("建议时机", text: timing)
                    }
                    if let risk = briefing.deepRiskIfIgnore {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text("风险：\(risk)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
```

- [ ] **Step 3: Update loadGroupContextBriefing in ChatMonitor to also call ContextAnalyzer**

In `ChatMonitor.swift`, find `loadGroupContextBriefing` and after the existing GroupContextBriefingService call succeeds, chain a ContextAnalyzer call to enrich the briefing. Add the deep analysis fields to the resulting `GroupContextBriefing` before setting the state.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Data/Models.swift Sources/WeChatHUD/Views/GroupContextBriefingButton.swift Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat: enhance 什么情况 popover with deep context analysis"
```

---

### Task 9: Whitelist Suggestion Badge + Auto-Trigger

**Files:**
- Create: `Sources/WeChatHUD/Views/WhitelistSuggestionBadge.swift`
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift` (UnreadRow)

- [ ] **Step 1: Create WhitelistSuggestionBadge**

```swift
import SwiftUI

/// Inline badge shown on unread rows for non-whitelisted contacts
/// that AI suggests adding to whitelist.
struct WhitelistSuggestionBadge: View {
    @EnvironmentObject var monitor: ChatMonitor
    let chatUsername: String
    let suggestion: AIWhitelistCategorizer.Suggestion

    @State private var showConfirm = false

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            Text("建议关注")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showConfirm) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AI 建议将此联系人加入白名单")
                    .font(.system(size: 12, weight: .semibold))
                Text("分类：\(categoryLabel)")
                    .font(.system(size: 11))
                Text("理由：\(suggestion.reason)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("置信度：\(Int(suggestion.confidence * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack {
                    Button("加入白名单") {
                        monitor.acceptWhitelistSuggestion(chatUsername: chatUsername, suggestion: suggestion)
                        showConfirm = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("忽略") {
                        monitor.dismissWhitelistSuggestion(chatUsername: chatUsername)
                        showConfirm = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 260)
        }
    }

    private var categoryLabel: String {
        switch suggestion.category {
        case "work": return "工作"
        case "life": return "生活"
        default: return "其他"
        }
    }
}
```

- [ ] **Step 2: Add helper methods to ChatMonitor**

```swift
    func acceptWhitelistSuggestion(chatUsername: String, suggestion: AIWhitelistCategorizer.Suggestion) {
        let category: WhitelistCategory = suggestion.category == "work" ? .work : suggestion.category == "life" ? .life : .other
        let entry = WhitelistEntry(
            id: 0,
            displayName: suggestion.isGroup ? chatUsername : chatUsername,
            isGroup: suggestion.isGroup,
            category: category,
            attentionLevel: .watch,
            addedAt: Date(),
            autoSuggested: true
        )
        try? store.upsertWhitelist(entry, username: chatUsername)
        whitelistSuggestions.removeValue(forKey: chatUsername)
    }

    func dismissWhitelistSuggestion(chatUsername: String) {
        whitelistSuggestions.removeValue(forKey: chatUsername)
    }
```

- [ ] **Step 3: Wire badge into UnreadRow**

In `UnreadRow` body, after `statusBadge` and before the timestamp, add:

```swift
                if !item.isWhitelisted,
                   let suggestion = monitor.whitelistSuggestions[item.chatUsername] {
                    WhitelistSuggestionBadge(
                        chatUsername: item.chatUsername,
                        suggestion: suggestion
                    )
                }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/WhitelistSuggestionBadge.swift Sources/WeChatHUD/Views/ExtendedTabsView.swift Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat: add whitelist suggestion badges with auto-trigger"
```

---

### Task 10: Whitelist Batch Scan View (Settings)

**Files:**
- Create: `Sources/WeChatHUD/Views/WhitelistScanView.swift`
- Modify: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`

- [ ] **Step 1: Create WhitelistScanView**

```swift
import SwiftUI

/// Batch whitelist scan UI shown in settings. Scans contacts in batches
/// of 10, shows progress, lets user accept/reject suggestions individually
/// or in bulk.
struct WhitelistScanView: View {
    @EnvironmentObject var store: HUDStore

    @State private var isScanning = false
    @State private var progress: Double = 0
    @State private var total: Int = 0
    @State private var scanned: Int = 0
    @State private var suggestions: [(username: String, suggestion: AIWhitelistCategorizer.Suggestion)] = []
    @State private var dismissed: Set<String> = []

    var visibleSuggestions: [(username: String, suggestion: AIWhitelistCategorizer.Suggestion)] {
        suggestions.filter { !dismissed.contains($0.username) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 扫描建议")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !isScanning {
                    Button("开始扫描") {
                        Task { await startScan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("扫描进度 \(scanned)/\(total)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            if !visibleSuggestions.isEmpty {
                ForEach(visibleSuggestions, id: \.username) { item in
                    ScanSuggestionRow(
                        username: item.username,
                        suggestion: item.suggestion,
                        onAccept: { accept(item.username, item.suggestion) },
                        onDismiss: { dismissed.insert(item.username) }
                    )
                }

                HStack {
                    Button("全部接受") { acceptAll() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("全部忽略") { dismissAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if !isScanning && suggestions.isEmpty && total > 0 {
                Text("扫描完成，没有新的建议")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func startScan() async {
        isScanning = true
        suggestions = []
        dismissed = []

        // Get all sessions that aren't whitelisted
        // For now use a simple approach: scan recent unread contacts
        let cfg = store.loadClassifierConfig()
        let categorizer = AIWhitelistCategorizer(store: store, config: cfg)

        // Placeholder: load contacts from store that aren't whitelisted
        let contacts = store.loadNonWhitelistedContacts(limit: 30)
        total = contacts.count
        scanned = 0

        let batchSize = 10
        for batch in stride(from: 0, to: contacts.count, by: batchSize) {
            let end = min(batch + batchSize, contacts.count)
            for i in batch..<end {
                let contact = contacts[i]
                let input = AIWhitelistCategorizer.Input(
                    contactName: contact.displayName,
                    isGroup: contact.username.contains("@chatroom"),
                    messages: [] // Would need recent messages from reader
                )
                if let result = await categorizer.categorize(input), result.shouldWhitelist {
                    suggestions.append((username: contact.username, suggestion: result))
                }
                scanned += 1
                progress = Double(scanned) / Double(total)
            }
        }
        isScanning = false
    }

    private func accept(_ username: String, _ suggestion: AIWhitelistCategorizer.Suggestion) {
        let category: WhitelistCategory = suggestion.category == "work" ? .work : suggestion.category == "life" ? .life : .other
        let entry = WhitelistEntry(
            id: 0, displayName: username, isGroup: suggestion.isGroup,
            category: category, attentionLevel: .watch, addedAt: Date(), autoSuggested: true
        )
        try? store.upsertWhitelist(entry, username: username)
        dismissed.insert(username)
    }

    private func acceptAll() {
        for item in visibleSuggestions {
            accept(item.username, item.suggestion)
        }
    }

    private func dismissAll() {
        for item in visibleSuggestions {
            dismissed.insert(item.username)
        }
    }
}

private struct ScanSuggestionRow: View {
    let username: String
    let suggestion: AIWhitelistCategorizer.Suggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(username)
                        .font(.system(size: 12, weight: .medium))
                    Text(suggestion.category)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(3)
                    Text("置信度\(Int(suggestion.confidence * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Text("理由：\(suggestion.reason)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("接受") { onAccept() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button("忽略") { onDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Add scan button to ContactsSettingsView**

In `ContactsSettingsView.swift`, add at the top or bottom of the view:

```swift
            Divider()
            WhitelistScanView()
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/WhitelistScanView.swift Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift
git commit -m "feat: add whitelist batch scan with progress + accept/reject UI"
```

---

### Task 11: Final Integration — Pass Data Through & Panel Sizing

**Files:**
- Modify: `Sources/WeChatHUD/Views/HUDRootView.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`

- [ ] **Step 1: Update HUDRootView to pass monitor to ExtendedTabsView**

Ensure `ExtendedTabsView` has access to `monitor` via `@EnvironmentObject`. Since `HUDRootView` already injects `monitor` into the environment, `ExtendedTabsView` and all its children can access it. No changes needed if `@EnvironmentObject var monitor: ChatMonitor` is already declared in `ExtendedTabsView`.

If `ExtendedTabsView` doesn't have `@EnvironmentObject var monitor`, add it.

- [ ] **Step 2: Subscribe to new published properties for panel resizing**

In `AppDelegate.swift`, after the existing `monitor.$replyDebtItems` sink (around line 136), add:

```swift
        monitor.$commitments
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        monitor.$recalledMessages
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)
```

- [ ] **Step 3: Build the complete project**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift build 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 4: Run tests to make sure nothing is broken**

Run: `cd /Users/yuriwong/wechatcli/WeChatHUD && swift test 2>&1 | tail -20`
Expected: All tests pass (AI live tests may be skipped if oMLX is not running)

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/HUDRootView.swift Sources/WeChatHUD/App/AppDelegate.swift
git commit -m "feat: wire panel sizing and data subscriptions for AI views"
```

---

### Task 12: Build & Smoke Test

- [ ] **Step 1: Full clean build**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift package clean && swift build 2>&1 | tail -10
```

- [ ] **Step 2: Run all tests**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && swift test 2>&1 | grep -E '(Test Suite|Executed|failed|skipped)'
```

- [ ] **Step 3: Build and run the app**

```bash
cd /Users/yuriwong/wechatcli/WeChatHUD && make app && make run
```

Verify:
- Hover shows 4 tabs: 关注 / 待回 / 未读 / 日报
- 待回 tab: clicking a row expands reply suggestions
- 关注 tab: VIP rows show mood/urgency tags, recalled messages section visible
- 日报 tab: shows loading state, then daily summary + commitments
- 什么情况 button: popover shows enhanced analysis
- Settings → 联系人: AI 扫描建议 section visible

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete frontend AI integration — all 11 services wired to UI"
```
