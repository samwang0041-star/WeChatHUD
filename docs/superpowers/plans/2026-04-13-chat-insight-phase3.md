# ChatInsight Phase 3: UI Views

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the UI layer — global briefing view (ChatInsightView), detail view (ChatInsightDetailView), and integrate as a new tab in ExtendedTabsView.

**Architecture:** Follow existing tab view patterns (DailyReportTabView, CatchupTabView). SwiftUI views consuming ChatMonitor's @Published properties. Dark theme, compact typography matching existing app style.

**Tech Stack:** SwiftUI, existing EnvironmentObject pattern.

**Spec:** `docs/superpowers/specs/2026-04-13-chat-insight-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/WeChatHUD/Views/Analytics/ChatInsightView.swift` | Main view: global briefing flow |
| Create | `Sources/WeChatHUD/Views/Analytics/ChatInsightDetailView.swift` | Detail: per-group/person analysis |
| Modify | `Sources/WeChatHUD/Views/ExtendedTabsView.swift` | Add .insight tab case |

---

### Task 1: ChatInsightView — main briefing view

**Files:**
- Create: `Sources/WeChatHUD/Views/Analytics/ChatInsightView.swift`

- [ ] **Step 1: Create the Analytics directory and ChatInsightView.swift**

```swift
import SwiftUI

/// Main chat insight view — a scrollable briefing flow.
struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @State private var selectedChat: String? = nil  // chatUsername for detail nav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            if monitor.insightLoading && monitor.globalBriefing == nil {
                loadingView
            } else if let briefing = monitor.globalBriefing {
                briefingContent(briefing)
            } else {
                emptyView
            }
        }
        .task { await monitor.loadInsight() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("聊天洞察")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if monitor.insightLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            Button(action: { Task { await monitor.loadInsight(force: true) } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    // MARK: - Briefing content

    @ViewBuilder
    private func briefingContent(_ briefing: GlobalBriefing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Action required section
                if !briefing.actionRequired.isEmpty {
                    sectionCard(title: "🔴 需要你行动", color: .red) {
                        ForEach(Array(briefing.actionRequired.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.source): \(item.what)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.85))
                                    Text("等了\(String(format: "%.0f", item.waitingHours))小时")
                                        .font(.system(size: 9))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                            }
                        }
                    }
                }

                // Global overview
                sectionCard(title: "📊 今日全景", color: .blue) {
                    // Stats row
                    HStack(spacing: 8) {
                        statPill("消息", "\(briefing.stats.totalMessages)")
                        statPill("群聊", "\(briefing.stats.activeGroups)/\(briefing.stats.totalGroups)")
                        statPill("私聊", "\(briefing.stats.activePrivateChats)")
                        statPill("工作", "\(Int(briefing.stats.workRatio * 100))%")
                    }

                    Text(briefing.headline)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(4)
                }

                // Per-chat cards grouped by category
                let sortedInsights = sortedChatCards()
                let workChats = sortedInsights.filter { $0.category == .work }
                let lifeChats = sortedInsights.filter { $0.category == .life }
                let otherChats = sortedInsights.filter { $0.category == .other }

                if !workChats.isEmpty {
                    chatSection(title: "🏢 工作", chats: workChats)
                }
                if !lifeChats.isEmpty {
                    chatSection(title: "🏠 生活", chats: lifeChats)
                }
                if !otherChats.isEmpty {
                    chatSection(title: "💬 其他", chats: otherChats)
                }

                // Cross-chat topics
                if !briefing.crossTopics.isEmpty {
                    sectionCard(title: "🔗 跨群话题", color: .purple) {
                        ForEach(Array(briefing.crossTopics.enumerated()), id: \.offset) { _, topic in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(topic.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                    Spacer()
                                    Text(topic.status)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                Text(topic.chats.joined(separator: " · "))
                                    .font(.system(size: 9))
                                    .foregroundColor(.purple.opacity(0.7))
                                Text(topic.summary)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(2)
                                if let conflict = topic.conflict {
                                    Text("⚠ \(conflict)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.yellow.opacity(0.8))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Dark signals
                if let darkHeadline = briefing.darkSignals.headline, !darkHeadline.isEmpty {
                    sectionCard(title: "🔇 暗信号", color: .orange) {
                        Text(darkHeadline)
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.8))
                            .lineLimit(4)
                    }
                }

                // Top suggestion
                sectionCard(title: "💡 建议", color: .green) {
                    Text(briefing.topSuggestion)
                        .font(.system(size: 11))
                        .foregroundColor(.green.opacity(0.8))
                }

                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    // MARK: - Chat card data

    private struct ChatCardData: Identifiable {
        let id: String  // chatUsername
        let name: String
        let category: WhitelistCategory
        let result: ChatInsightResult
        let score: Int
    }

    private func sortedChatCards() -> [ChatCardData] {
        let whitelist = monitor.store.loadWhitelist()
        return monitor.chatInsights.compactMap { (username, result) -> ChatCardData? in
            guard let entry = whitelist.first(where: { $0.id == username }) else { return nil }
            let stats = ChatStatsData(
                chatUsername: username, chatName: entry.displayName,
                isGroup: entry.isGroup, category: entry.category,
                messageCount: result.topics.reduce(0) { $0 + $1.messageCount },
                myMessageCount: 0, participantCount: 0,
                messagesByHour: Array(repeating: 0, count: 24),
                avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
                topSenders: [], silentMembers: [], ignoredMessages: []
            )
            let score = ChatInsightEngine.sortingScore(stats, hasActionForMe: result.needsMyAttention)
            return ChatCardData(id: username, name: entry.displayName,
                              category: entry.category, result: result, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - Chat section

    @ViewBuilder
    private func chatSection(title: String, chats: [ChatCardData]) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
            .padding(.top, 4)

        ForEach(chats) { chat in
            Button(action: { selectedChat = chat.id }) {
                chatCard(chat)
            }
            .buttonStyle(.plain)
            .sheet(item: Binding(
                get: { selectedChat == chat.id ? chat : nil },
                set: { if $0 == nil { selectedChat = nil } }
            )) { card in
                ChatInsightDetailView(chatUsername: card.id, chatName: card.name, result: card.result)
                    .environmentObject(monitor)
            }
        }
    }

    private func chatCard(_ chat: ChatCardData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(chat.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if chat.result.needsMyAttention {
                    Text("⚠")
                        .font(.system(size: 9))
                }
                Text(chat.result.overallMood)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Topics as tags
            HStack(spacing: 4) {
                ForEach(Array(chat.result.topics.prefix(3).enumerated()), id: \.offset) { _, topic in
                    Text(topic.name)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
            }

            Text(chat.result.headline)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionCard(title: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color.opacity(0.8))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(.white.opacity(0.8))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("正在分析聊天...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text("暂无分析数据")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Text("点击刷新开始分析")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Fix any issues (likely need to adjust `store` access — it may not be directly accessible from `monitor`, in which case use `@EnvironmentObject var store: HUDStore` separately).

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/Analytics/ChatInsightView.swift
git commit -m "feat(insight): add ChatInsightView main briefing UI"
```

---

### Task 2: ChatInsightDetailView

**Files:**
- Create: `Sources/WeChatHUD/Views/Analytics/ChatInsightDetailView.swift`

- [ ] **Step 1: Create ChatInsightDetailView.swift**

```swift
import SwiftUI

/// Detail view for a single chat's insight analysis.
struct ChatInsightDetailView: View {
    let chatUsername: String
    let chatName: String
    let result: ChatInsightResult

    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(chatName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Text(result.overallMood)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Topics
                    detailSection("在聊什么") {
                        ForEach(Array(result.topics.enumerated()), id: \.offset) { _, topic in
                            topicRow(topic)
                        }
                    }

                    // Waiting for me
                    if !result.waitingForMe.isEmpty || !result.myCommitments.isEmpty {
                        detailSection("和我相关") {
                            if result.mentionsMe > 0 {
                                detailBullet("被@\(result.mentionsMe)次")
                            }
                            ForEach(Array(result.waitingForMe.enumerated()), id: \.offset) { _, item in
                                detailBullet("⚠ \(item.source)等你: \(item.what) (已等\(String(format: "%.0f", item.waitingHours))h)")
                            }
                            ForEach(Array(result.myCommitments.enumerated()), id: \.offset) { _, c in
                                detailBullet("📌 你承诺: \(c)")
                            }
                        }
                    }

                    // Mood
                    detailSection("氛围") {
                        HStack(spacing: 8) {
                            moodBadge(result.overallMood)
                            Text("信噪比 \(Int(result.signalNoiseRatio * 100))%")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                            Text("决策效率 \(result.decisionEfficiency)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        if let shift = result.moodShift {
                            Text("💫 \(shift.time): \(shift.from) → \(shift.to)")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow.opacity(0.7))
                            Text("触发: \(shift.trigger)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }

                    // Attitudes
                    if let attitudes = result.attitudes, !attitudes.isEmpty {
                        detailSection("态度信号") {
                            ForEach(Array(attitudes.enumerated()), id: \.offset) { _, att in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(att.person)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.white.opacity(0.7))
                                        Text("→ \(att.topic)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.4))
                                        Spacer()
                                        attitudeBadge(att.attitude)
                                    }
                                    Text(""\(att.evidence)"")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.35))
                                        .italic()
                                }
                            }
                        }
                    }

                    // Participants (group) or Relationship (private)
                    if let participants = result.participants, !participants.isEmpty {
                        detailSection("谁在说话") {
                            ForEach(Array(participants.enumerated()), id: \.offset) { _, p in
                                HStack {
                                    Text(p.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                    Text("\(p.messageCount)条")
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundColor(.white.opacity(0.35))
                                    Text(p.role)
                                        .font(.system(size: 9))
                                        .foregroundColor(.blue.opacity(0.6))
                                    Spacer()
                                    Text(p.doing)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Dark signals
                    if let tones = result.toneChanges, !tones.isEmpty {
                        detailSection("🔇 暗信号") {
                            ForEach(Array(tones.enumerated()), id: \.offset) { _, tone in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(tone.person): \(tone.change)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange.opacity(0.7))
                                    Text(tone.interpretation)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                            }
                        }
                    }

                    // Insight + Suggestion
                    detailSection("💡 洞察") {
                        Text(result.insight)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    detailSection("🎯 建议") {
                        Text(result.suggestion)
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.7))
                    }

                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
    }

    // MARK: - Components

    private func topicRow(_ topic: TopicInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(topic.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Text("\(topic.messageCount)条 · \(topic.participantCount)人")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
                statusBadge(topic.status)
            }
            Text(topic.summary)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(3)
            if let involvement = topic.myInvolvement {
                Text("你: \(involvement)")
                    .font(.system(size: 9))
                    .foregroundColor(.blue.opacity(0.6))
            }
            if let cross = topic.crossChats, !cross.isEmpty {
                Text("🔗 也在: \(cross.joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundColor(.purple.opacity(0.6))
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            content()
        }
    }

    private func detailBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•").foregroundColor(.white.opacity(0.3)).font(.system(size: 10))
            Text(text).font(.system(size: 10)).foregroundColor(.white.opacity(0.65))
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(status == "已决" ? .green : status == "搁置" ? .gray : .yellow)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background((status == "已决" ? Color.green : status == "搁置" ? Color.gray : Color.yellow).opacity(0.12))
            .cornerRadius(3)
    }

    private func moodBadge(_ mood: String) -> some View {
        let color: Color = mood.contains("焦虑") || mood.contains("紧张") ? .red
            : mood.contains("轻松") ? .green : .white
        return Text(mood)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color.opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private func attitudeBadge(_ attitude: String) -> some View {
        let color: Color = attitude.contains("积极") ? .green
            : attitude.contains("反对") ? .red
            : attitude.contains("敷衍") ? .gray
            : .yellow
        return Text(attitude)
            .font(.system(size: 8))
            .foregroundColor(color.opacity(0.8))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(2)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/Analytics/ChatInsightDetailView.swift
git commit -m "feat(insight): add ChatInsightDetailView for per-chat analysis"
```

---

### Task 3: Integrate into ExtendedTabsView

**Files:**
- Modify: `Sources/WeChatHUD/Views/ExtendedTabsView.swift`

- [ ] **Step 1: Add .insight to Tab enum**

In `ExtendedTabsView.swift`, find the Tab enum and add:

```swift
case insight
```

- [ ] **Step 2: Add view dispatch**

In the switch statement (around line 75-83), add:

```swift
case .insight: ChatInsightView()
```

- [ ] **Step 3: Add tab button**

In the tab bar section, add a button for the insight tab. Add it near the dailyReport button:

```swift
tabButton(.insight, label: "洞察", count: 0)
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | grep -E "passed|failed" | tail -3`

- [ ] **Step 6: Build app and verify**

Run: `make app 2>&1 | tail -3`

- [ ] **Step 7: Commit**

```bash
git add Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat(insight): add insight tab to ExtendedTabsView"
```
