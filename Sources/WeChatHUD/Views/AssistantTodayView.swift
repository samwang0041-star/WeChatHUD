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

    private var actions: [InboxItem] { monitor.inboxItems.filter(\.participatesInActionQueue) }
    private var visible: [InboxItem] {
        let items = showUpdates ? monitor.inboxItems : monitor.inboxItems.filter { $0.participatesInActionQueue || $0.isAtMention }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { text.isEmpty || [$0.chatName, $0.preview, $0.aiSummary ?? ""].contains { $0.localizedCaseInsensitiveContains(text) } }
    }
    private var pending: [DiscussionItem] { monitor.discussionItems.filter { $0.status == .pending && $0.kind != .info } }

    private var upcoming: [Commitment] {
        monitor.commitments.filter { $0.status == .pending || $0.status == .overdue }
            .sorted { ($0.deadlineAt ?? .distantFuture) < ($1.deadlineAt ?? .distantFuture) }
    }

    private var wechatConnected: Bool {
        guard monitor.stats.lastSyncAt != nil else { return false }
        if case .ok = monitor.stats.syncStatus { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CompanionSetupCard(navigate: navigate)
                    HStack(spacing: 8) {
                        filterPill("需要回复", count: actions.count, selected: !showUpdates) {
                            showUpdates = false
                        }
                        filterPill("我要做", count: pending.filter { $0.owner == .mine }.count, selected: false) {
                            panelState.pendingDiscussionScope = .mine
                            navigate(.tasks)
                        }
                        filterPill("等对方", count: pending.filter { $0.owner == .theirs }.count, selected: false) {
                            panelState.pendingDiscussionScope = .theirs
                            navigate(.tasks)
                        }
                    }
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
    }

    private var messageFeed: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("先处理这些事").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { showUpdates.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(showUpdates ? "只看需要回复的" : "全部 \(monitor.inboxItems.count) 条")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompanionPalette.jade)
                }
                .buttonStyle(.plain)
            }
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
                let empty = FirstLaunchGuide.todayEmpty(
                    wechatConnected: wechatConnected,
                    hasTrackedConversations: !store.getWhitelist().isEmpty,
                    aiConfigured: AISettingsValidation.connectionError(store.loadAIConfig().provider, requireModel: true) == nil,
                    aiTested: AIConnectionEvidenceStore.isSuccessful(store.loadAIConfig(), store: store),
                    searching: !query.isEmpty
                )
                ContentUnavailableView(empty.title, systemImage: query.isEmpty ? "tray" : "magnifyingglass", description: Text(empty.detail))
                    .frame(maxWidth: .infinity).padding(.vertical, 28).companionSurface()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { item in
                        messageCard(item, expanded: expandedID == item.id || (expandedID == nil && item.id == visible.first?.id))
                    }
                }
            }
            if let dismissed {
                HStack {
                    Label("已处理 · \(dismissed.chatName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CompanionPalette.accent)
                    Spacer()
                    Button("撤销") { if monitor.restoreInboxItem(dismissed) { self.dismissed = nil } }
                }.font(.callout).companionSurface(padding: 14)
                    .transition(.opacity)
            }
            if let snoozeReceipt {
                HStack {
                    Label(snoozeReceipt, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CompanionPalette.jade)
                    Spacer()
                    Button("知道了") { self.snoozeReceipt = nil }
                }.font(.callout).companionSurface(padding: 14)
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
                                Text(monitor.displayName(for: commitment.chatUsername)).font(.system(size: 11)).foregroundStyle(.secondary)
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
                quickLink("今日小结", subtitle: "今天做了什么、还剩什么", icon: "doc.text") { navigate(.dailyReport) }
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
                Label("关注 \(store.getWhitelist().count) 个对话", systemImage: "person.2")
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

    private func filterPill(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? CompanionPalette.jade : CompanionPalette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : CompanionPalette.border))
        }
        .buttonStyle(CompanionPressStyle())
        .accessibilityLabel("\(title)，\(count) 项")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func messageCard(_ item: InboxItem, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withMotion(CompanionMotion.rowExpand()) {
                    expandedID = expanded && expandedID == item.id ? "" : item.id
                }
            } label: {
                HStack(spacing: 10) {
                    CompanionAvatar(name: monitor.displayName(for: item.chatUsername), size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.displayName(for: item.chatUsername)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        Text(item.timestamp, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if item.isAtMention { CompanionBadge(title: "@ 我") }
                    if !expanded { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(.plain)

            Text(item.aiSummary?.isEmpty == false ? (expanded ? item.aiSummary! : String(item.aiSummary!.prefix(28))) : item.preview)
                .font(.system(size: expanded ? 16 : 14, weight: expanded ? .semibold : .regular))
                .lineSpacing(4).textSelection(.enabled).lineLimit(expanded ? 6 : 1)

            if expanded {
                if let summary = item.aiSummary, !summary.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AI 解读").font(.system(size: 11, weight: .semibold)).foregroundStyle(CompanionPalette.jade)
                            Text(summary).font(.system(size: 13)).foregroundStyle(.primary).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button("查看原文") { expandedID = item.id }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    .padding(12)
                    .background(CompanionPalette.selectedFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    DisclosureGroup("消息原文") {
                        Text(item.preview).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                }
                HStack {
                    Button { panelState.showChatDetail(chatUsername: item.chatUsername, chatName: item.chatName) } label: {
                        Label("理解上下文与回复", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    Menu {
                        ForEach(CompanionProductCopy.snoozeChoices()) { choice in
                            Button("\(choice.label)  \(choice.whenLabel)") { snooze(item, until: choice.until) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .help("稍后提醒")
                    .accessibilityLabel("稍后提醒")
                    Spacer()
                    Button("已处理") { if monitor.dismissInboxItem(item) { dismissed = item } }.buttonStyle(.bordered)
                }
                .controlSize(.regular)
            }
        }
        .companionSurface()
    }
}
