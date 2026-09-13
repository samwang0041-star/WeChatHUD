import SwiftUI

struct AssistantTodayView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var panelState: PanelState
    let navigate: (SettingsView.Tab) -> Void
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var showUpdates = false
    @State private var dismissed: InboxItem?
    @State private var expandedID: String?
    @State private var snoozeReceipt: String?
    @State private var revealedOriginalIDs: Set<String> = []
    @State private var aiReadinessLoaded = false
    @State private var aiConfigured = false
    @State private var aiTested = false

    private var visible: [InboxItem] {
        let items = showUpdates ? monitor.inboxItems : TodayFeed.needsReply(monitor.inboxItems)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { text.isEmpty || [$0.chatName, $0.preview, $0.aiSummary ?? ""].contains { $0.localizedCaseInsensitiveContains(text) } }
    }
    private var needsReply: [InboxItem] { TodayFeed.needsReply(monitor.inboxItems) }
    private var mineTasks: [DiscussionItem] {
        TodayFeed.mineTasks(monitor.discussionItems, strictness: monitor.discussionStrictness)
    }
    private var waitingTasks: [DiscussionItem] {
        TodayFeed.waitingTasks(monitor.discussionItems, strictness: monitor.discussionStrictness)
    }

    private var upcoming: [Commitment] {
        monitor.commitments.filter { $0.status == .pending || $0.status == .overdue }
            .sorted { ($0.deadlineAt ?? .distantFuture) < ($1.deadlineAt ?? .distantFuture) }
    }

    private var wechatConnected: Bool {
        guard monitor.stats.lastSyncAt != nil else { return false }
        switch monitor.stats.syncStatus {
        case .ok, .idle, .syncing, .stale: return true
        default: return false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CompanionSetupCard(navigate: navigate)
                    todayHero
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 24) {
                            messageFeed.frame(maxWidth: .infinity)
                            companionRail.frame(width: 280)
                        }
                    } else {
                        messageFeed
                        companionRail
                    }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { refreshAIReadiness() }
    }

    private func refreshAIReadiness() {
        let config = store.loadAIConfig()
        aiConfigured = AISettingsValidation.connectionError(config.provider, requireModel: true) == nil
        aiTested = AIConnectionEvidenceStore.isSuccessful(config, store: store)
        aiReadinessLoaded = true
    }

    private var todayHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TodayCopy.status(
                needsReply: needsReply.count,
                showingUpdates: showUpdates,
                updateCount: TodayFeed.allUpdatesCount(monitor.inboxItems)
            ))
            .workspaceTitle()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("today.status")

            HStack(spacing: 14) {
                if !mineTasks.isEmpty {
                    Button {
                        panelState.pendingDiscussionScope = .mine
                        navigate(.tasks)
                    } label: {
                        Text(TodayCopy.mineWork(mineTasks.count))
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(CompanionPressStyle())
                    .accessibilityHint("打开待办")
                }
                if !waitingTasks.isEmpty {
                    Button {
                        panelState.pendingDiscussionScope = .theirs
                        navigate(.tasks)
                    } label: {
                        Text(TodayCopy.waitingWork(waitingTasks.count))
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(CompanionPressStyle())
                    .accessibilityHint("打开待办")
                }
                Spacer(minLength: 8)
                if showUpdates {
                    Button {
                        withMotion(CompanionMotion.ease()) { showUpdates = false }
                    } label: {
                        Text(TodayCopy.backToReplies)
                            .workspaceMeta()
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    .buttonStyle(CompanionPressStyle())
                } else if TodayFeed.hasNonReplyUpdates(monitor.inboxItems) {
                    Button {
                        withMotion(CompanionMotion.ease()) { showUpdates = true }
                    } label: {
                        Text(TodayCopy.allUpdates(TodayFeed.allUpdatesCount(monitor.inboxItems)))
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(CompanionPressStyle())
                }
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: showUpdates)
        .companionAnimation(CompanionMotion.ease(), value: needsReply.count)
    }

    private var messageFeed: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }.buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("搜索联系人或消息")
                TextField("搜索联系人或消息", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索联系人或消息")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                } else {
                    Text("⌘ F").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? CompanionPalette.accent.opacity(0.5) : CompanionPalette.border))

            if visible.isEmpty {
                if aiReadinessLoaded {
                    let empty = FirstLaunchGuide.todayEmpty(
                        wechatConnected: wechatConnected,
                        hasTrackedConversations: store.hasWhitelistEntries(),
                        aiConfigured: aiConfigured,
                        aiTested: aiTested,
                        searching: !query.isEmpty,
                        hasOpenTasks: TodayFeed.hasOpenWork(mine: mineTasks, waiting: waitingTasks, upcoming: upcoming),
                        hasOtherInboxItems: !showUpdates && TodayFeed.hasNonReplyUpdates(monitor.inboxItems)
                    )
                    ContentUnavailableView(empty.title, systemImage: query.isEmpty ? "tray" : "magnifyingglass", description: Text(empty.detail))
                        .frame(maxWidth: .infinity).padding(.vertical, 28).companionSurface()
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { item in
                        TodayMessageCard(
                            item: item,
                            expanded: expandedID == item.id || (expandedID == nil && item.id == visible.first?.id),
                            originalRevealed: revealedOriginalIDs.contains(item.id),
                            onToggle: {
                                withMotion(CompanionMotion.rowExpand()) {
                                    let pinned = expandedID == item.id
                                    expandedID = pinned ? "" : item.id
                                }
                            },
                            onRevealOriginal: { isOn in
                                if isOn { revealedOriginalIDs.insert(item.id) }
                                else { revealedOriginalIDs.remove(item.id) }
                            },
                            onReply: {
                                panelState.showChatDetail(chatUsername: item.chatUsername, chatName: item.chatName)
                            },
                            onSnooze: { snooze(item, until: $0) },
                            onHandled: {
                                guard monitor.dismissInboxItem(item) else { return }
                                withMotion(CompanionMotion.complete()) { dismissed = item }
                            }
                        )
                    }
                }
                .companionAnimation(CompanionMotion.ease(), value: showUpdates)
            }
            if let dismissed {
                HStack {
                    Label("已处理 · \(dismissed.chatName)", systemImage: "checkmark.circle.fill")
                        .workspaceBody()
                        .foregroundStyle(CompanionPalette.accent)
                    Spacer()
                    Button("撤销") { if monitor.restoreInboxItem(dismissed) { self.dismissed = nil } }
                        .buttonStyle(CompanionPressStyle())
                }.companionSurface(padding: 14)
                    .transition(.opacity)
            }
            if let snoozeReceipt {
                HStack {
                    Label(snoozeReceipt, systemImage: "checkmark.circle.fill")
                        .workspaceBody()
                        .foregroundStyle(CompanionPalette.jade)
                    Spacer()
                    Button("知道了") { self.snoozeReceipt = nil }
                        .buttonStyle(CompanionPressStyle())
                }.companionSurface(padding: 14)
            }
        }
    }

    private func snooze(_ item: InboxItem, until: Date) {
        guard monitor.snoozeInboxItem(item, until: until) else { return }
        snoozeReceipt = CompanionProductCopy.snoozeReceipt(until: until)
    }

    private var companionRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("接下来").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !upcoming.isEmpty { CompanionBadge(title: "\(upcoming.count) 项") }
                }
                if upcoming.isEmpty {
                    Text("现在没有排上日程的事")
                        .font(.system(size: 13, weight: .medium))
                    Text("答应过的截止时间会按顺序出现在这里。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(upcoming.prefix(3))) { commitment in
                        Button { navigate(.commitments) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(commitment.content).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                                Text(commitment.chatName).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let deadline = commitment.deadlineAt {
                                    Label(deadline.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(deadline < Date() ? Color.orange : CompanionPalette.accent)
                                } else if !commitment.deadlineLabel.isEmpty {
                                    Text(commitment.deadlineLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(CompanionPressStyle())
                        if commitment.id != upcoming.prefix(3).last?.id { Divider() }
                    }
                }
                Button { navigate(.commitments) } label: {
                    HStack { Text("查看我答应的事"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.system(size: 12, weight: .medium))
                }.buttonStyle(.borderless)
            }.companionSurface()
            connectionCard
            VStack(spacing: 0) {
                quickLink("今日小结", subtitle: SettingsView.Tab.dailyReport.subtitle, icon: "doc.text") { navigate(.dailyReport) }
                Divider().padding(.horizontal, 16)
                quickLink("按时间回顾", subtitle: "回到发生过的对话", icon: "calendar") { RetrospectiveWindowManager.shared.showWindow(monitor: monitor) }
            }.companionSurface(padding: 0)
        }
    }

    private func quickLink(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(CompanionPalette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(CompanionPressStyle())
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: syncSymbol).foregroundStyle(syncColor).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncTitle).font(.headline)
                    if let date = monitor.stats.lastSyncAt {
                        Text("最近同步 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("还没连上微信").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("检查连接") { navigate(.system) }
                Button { monitor.refreshNow() } label: { Label("查看新消息", systemImage: "arrow.clockwise") }
                    .disabled(isSyncing)
                Spacer()
            }.controlSize(.small)
            if monitor.classificationPendingCount > 0 {
                HStack {
                    Label(monitor.classificationProcessing ? "正在分析 \(monitor.classificationPendingCount) 条消息" : "\(monitor.classificationPendingCount) 条消息等待分析", systemImage: "sparkles")
                    Spacer()
                    Button("重试分析") {
                        do { try store.retryClassificationMessages(); monitor.drainClassificationQueue() }
                        catch { panelState.showToast("暂时无法重试，请检查本地数据连接") }
                    }.disabled(monitor.classificationProcessing)
                }.font(.callout).foregroundStyle(.secondary)
            }
            if monitor.discussionPendingCount > 0 {
                HStack {
                    Label(monitor.discussionProcessing ? "正在从 \(monitor.discussionPendingCount) 条消息整理待办" : "\(monitor.discussionPendingCount) 条消息等待整理待办", systemImage: "checklist")
                    Spacer()
                    Button("重试整理") {
                        do { try monitor.retryDiscussionExtraction() }
                        catch { panelState.showToast("暂时无法重试整理，请检查本地数据连接") }
                    }.disabled(monitor.discussionProcessing)
                }.font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("关注 \(store.whitelistCount()) 个对话", systemImage: "person.2")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button("关注谁") { navigate(.contacts) }.buttonStyle(.link)
                    Button("设置 AI") { navigate(.aiButler) }.buttonStyle(.link)
                }
            }
            .font(.callout)
        }
        .companionSurface()
    }

    private var isSyncing: Bool { if case .syncing = monitor.stats.syncStatus { return true }; return false }
    private var syncTitle: String {
        switch monitor.stats.syncStatus {
        case .ok: return "正在关注你的对话"
        case .syncing: return "正在同步最新消息"
        case .idle: return "等待首次同步"
        case .stale: return "消息可能不是最新的"
        case .waitingForWeChat: return "等待微信启动"
        case .accountSwitched: return "当前数据目录已失效，请重新连接"
        case .error: return "微信连接需要处理"
        }
    }
    private var syncColor: Color {
        switch monitor.stats.syncStatus { case .ok: return .green; case .syncing, .idle: return .blue; default: return .orange }
    }
    private var syncSymbol: String {
        switch monitor.stats.syncStatus { case .ok: return "checkmark.circle"; case .syncing, .idle: return "arrow.triangle.2.circlepath"; default: return "exclamationmark.triangle" }
    }

}

private struct TodayMessageCard: View {
    let item: InboxItem
    let expanded: Bool
    let originalRevealed: Bool
    let onToggle: () -> Void
    let onRevealOriginal: (Bool) -> Void
    let onReply: () -> Void
    let onSnooze: (Date) -> Void
    let onHandled: () -> Void

    @State private var hovered = false
    @State private var hoverEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    CompanionAvatar(name: item.chatName)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.chatName)
                            .workspaceRowTitle()
                            .foregroundStyle(.primary)
                        Text(item.timestamp, format: .dateTime.hour().minute())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if item.isAtMention { CompanionBadge(title: "@ 我") }
                    if !expanded {
                        Image(systemName: "chevron.right")
                            .workspaceMicro()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(CompanionPressStyle())
            .accessibilityLabel(item.chatName)
            .accessibilityHint(expanded ? "收起这条" : "展开后回复")

            previewLine

            if expanded {
                expandedBody
                    .transition(.islandDetailReveal)
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CompanionPalette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cardWash)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CompanionPalette.border, lineWidth: 1)
        }
        .onHover { inside in
            guard hoverEnabled else { return }
            hovered = inside
        }
        .companionAnimation(CompanionMotion.hover(), value: hovered)
        .companionAnimation(CompanionMotion.rowExpand(), value: expanded)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                hoverEnabled = true
            }
        }
    }

    private var cardWash: Color {
        if expanded { return CompanionPalette.selectedFill }
        if hovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var previewLine: some View {
        let text = item.aiSummary?.isEmpty == false
            ? (expanded ? item.aiSummary! : TodayCopy.collapsedSummary(item.aiSummary!))
            : item.preview
        return Text(text)
            .companionFont(size: expanded ? WorkspaceType.title : WorkspaceType.body, weight: expanded ? .semibold : .regular)
            .lineSpacing(4)
            .textSelection(.enabled)
            .lineLimit(expanded ? 6 : 1)
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let summary = item.aiSummary, !summary.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TodayCopy.aiReading)
                        .workspaceMicro()
                        .foregroundStyle(CompanionPalette.jade)
                    Text(summary)
                        .workspaceBody()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button(originalRevealed ? TodayCopy.originalOpen : TodayCopy.viewOriginal) {
                    onRevealOriginal(true)
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(CompanionPalette.jade)
            }
            DisclosureGroup(isExpanded: Binding(
                get: { originalRevealed },
                set: onRevealOriginal
            )) {
                Text(item.preview)
                    .workspaceBody()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text(TodayCopy.originalSection)
                    .workspaceMeta()
            }
        }
        HStack {
            Button(action: onReply) {
                Label(TodayCopy.reply, systemImage: "text.bubble")
            }
            .buttonStyle(.borderedProminent)
            .tint(CompanionPalette.jade)
            .accessibilityLabel(TodayCopy.reply)
            Menu {
                ForEach(CompanionProductCopy.snoozeChoices()) { choice in
                    Button("\(choice.label)  \(choice.whenLabel)") { onSnooze(choice.until) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("稍后提醒")
            .accessibilityLabel("稍后提醒")
            Spacer()
            Button(TodayCopy.handled, action: onHandled)
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
        }
        .controlSize(.regular)
    }
}

/// One status sentence for 今天. The page has one primary list; these strings
/// are the only chrome that may compete with it.
enum TodayCopy {
    static func status(needsReply: Int, showingUpdates: Bool, updateCount: Int) -> String {
        if showingUpdates {
            return updateCount == 0 ? "现在没有对话更新" : "这些对话有 \(updateCount) 条更新"
        }
        if needsReply == 0 { return "现在没有要回的" }
        return "现在有 \(needsReply) 件需要回复"
    }

    static func mineWork(_ count: Int) -> String { "我要做 \(count)" }
    static func waitingWork(_ count: Int) -> String { "等对方 \(count)" }
    static func allUpdates(_ count: Int) -> String { "全部 \(count) 条" }
    static let backToReplies = "只看需要回复的"
    static let reply = "理解上下文与回复"
    static let handled = "已处理"
    static let viewOriginal = "查看原文"
    static let originalOpen = "原文已展开"
    static let aiReading = "AI 解读"
    static let originalSection = "消息原文"

    static func collapsedSummary(_ summary: String) -> String {
        summary.count > 28 ? String(summary.prefix(28)) + "…" : summary
    }
}

/// Testable 今天 feed rules. The page labels must match these arrays, not a
/// looser mix of FYI @mentions, handled rows, or info memos.
enum TodayFeed {
    static func needsReply(_ items: [InboxItem]) -> [InboxItem] {
        items.filter { item in item.participatesInActionQueue }
    }

    /// Active inbox only. Handled and still-snoozed chats are not in `inboxItems`.
    static func allUpdatesCount(_ items: [InboxItem]) -> Int {
        items.count
    }

    static func hasNonReplyUpdates(_ items: [InboxItem]) -> Bool {
        items.contains { item in !item.participatesInActionQueue }
    }

    static func mineTasks(_ items: [DiscussionItem]) -> [DiscussionItem] {
        mineTasks(items, strictness: .default)
    }

    /// Honours the strictness level so 今天 cannot list work the 待办 page has
    /// been told to hold back. Info memos stay excluded at every level: this
    /// feed is "what needs me today", not a record of what was said.
    static func mineTasks(_ items: [DiscussionItem], strictness: DiscussionStrictness) -> [DiscussionItem] {
        items.filter { item in
            item.status == .pending && !item.kind.isRecord && item.owner == .mine && strictness.admits(item)
        }
    }

    static func waitingTasks(_ items: [DiscussionItem]) -> [DiscussionItem] {
        waitingTasks(items, strictness: .default)
    }

    static func waitingTasks(_ items: [DiscussionItem], strictness: DiscussionStrictness) -> [DiscussionItem] {
        items.filter { item in
            item.status == .pending && !item.kind.isRecord && item.owner == .theirs && strictness.admits(item)
        }
    }

    static func hasOpenWork(mine: [DiscussionItem], waiting: [DiscussionItem], upcoming: [Commitment]) -> Bool {
        !mine.isEmpty || !waiting.isEmpty || !upcoming.isEmpty
    }
}
