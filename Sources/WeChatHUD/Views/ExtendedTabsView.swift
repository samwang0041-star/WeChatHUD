import SwiftUI
import AppKit

/// Hover-expanded pill content. Three actionable tabs:
///
/// - **关注**: tracked-source activity. VIP lives inside this feed as
///   the strong-reminder subset of the whitelist.
/// - **未读** (only shown when there's actual unread state): items are
///   pulled from `session.db` so the counter matches WeChat's own.
/// - **待回**: cross-chat reply debt ledger.
///
/// Unlike the old `HistoryListView`, this is tab-driven and session-aware.
struct ExtendedTabsView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    let vipNotifications: [HUDNotification]
    let unreadItems: [UnreadItem]
    let suppressedItems: [UnreadItem]
    let replyDebtItems: [ReplyDebtItem]
    @State private var selectedTab: Tab
    @State private var unreadFilter: UnreadFilter = .needsReply

    enum Tab {
        case vip
        case unread
        case replyDebt
        case catchup
        case commitments
        case dailyReport
        case autopilot
        case insight
    }

    /// Sub-filter inside the 未读 tab. Default `.needsReply` — the most
    /// actionable bucket. `.suppressed` lists items the user muted or
    /// snoozed so they can be restored.
    enum UnreadFilter: Hashable {
        case needsReply   // status == .pending
        case overdue      // status == .overdue
        case answered     // status == .answered
        case suppressed   // silenced / snoozed
        case all
    }

    init(
        vipNotifications: [HUDNotification],
        unreadItems: [UnreadItem],
        suppressedItems: [UnreadItem],
        replyDebtItems: [ReplyDebtItem]
    ) {
        self.vipNotifications = vipNotifications
        self.unreadItems = unreadItems
        self.suppressedItems = suppressedItems
        self.replyDebtItems = replyDebtItems
        _selectedTab = State(
            initialValue: Self.defaultTab(
                vipNotifications: vipNotifications,
                unreadItems: unreadItems,
                suppressedItems: suppressedItems,
                replyDebtItems: replyDebtItems
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Smart Digest banner — shown after > 30 min idle
            if panelState.showSmartDigest {
                smartDigestBanner
            }
            tabBar
            Divider()
                .background(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .vip:         vipContent
                    case .unread:      unreadContent
                    case .replyDebt:   replyDebtContent
                    case .catchup:     CatchupTabView()
                    case .commitments: CommitmentTabView()
                    case .dailyReport: DailyReportTabView()
                    case .autopilot:   AutopilotTabView()
                    case .insight:
                        Color.clear
                            .frame(height: 0)
                            .onAppear { panelState.onShowInsight?() }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hudSwitchTab)) { notif in
                guard let index = notif.userInfo?["index"] as? Int else { return }
                let tabs: [Tab] = [.vip, .replyDebt, .unread, .catchup, .dailyReport]
                if index < tabs.count {
                    selectedTab = tabs[index]
                }
            }
        }
    }

    private static func defaultTab(
        vipNotifications: [HUDNotification],
        unreadItems: [UnreadItem],
        suppressedItems: [UnreadItem],
        replyDebtItems: [ReplyDebtItem]
    ) -> Tab {
        if replyDebtItems.contains(where: { $0.priority != .p2 }) {
            return .replyDebt
        }
        if !vipNotifications.isEmpty {
            return .vip
        }
        if !replyDebtItems.isEmpty {
            return .replyDebt
        }
        if !unreadItems.isEmpty || !suppressedItems.isEmpty {
            return .unread
        }
        return .vip
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.vip, label: "关注", count: vipNotifications.count)
            if !replyDebtItems.isEmpty {
                tabButton(.replyDebt, label: "待回", count: replyDebtItems.count)
            }
            // Surface the 未读 tab if there's either an active unread
            // item or something waiting in the suppressed list — the
            // user still needs access to 恢复 even when nothing is live.
            if !unreadItems.isEmpty || !suppressedItems.isEmpty {
                tabButton(.unread, label: "未读", count: unreadItems.count)
            }
            tabButton(.catchup, label: "追赶", count: 0)
            if !monitor.commitments.isEmpty {
                tabButton(.commitments, label: "承诺", count: monitor.commitments.filter { $0.status == .pending || $0.status == .overdue }.count)
            }
            tabButton(.dailyReport, label: "日报", count: 0)
            tabButton(.insight, label: "洞察", count: 0)
            tabButton(.autopilot, label: monitor.autopilotActive ? "🤖托管" : "托管", count: monitor.autopilotSessionPending)
            Spacer()
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

    private func tabButton(_ tab: Tab, label: String, count: Int) -> some View {
        let selected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                    .cornerRadius(3)
            }
            .foregroundColor(selected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Color.white.opacity(0.12) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Smart Digest banner

    private var smartDigestBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("你离开了一段时间")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                let summary = digestSummary
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: {
                selectedTab = .catchup
                panelState.showSmartDigest = false
            }) {
                Text("查看追赶")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            Button(action: { panelState.showSmartDigest = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var digestSummary: String {
        var parts: [String] = []
        if !unreadItems.isEmpty { parts.append("\(unreadItems.count)条未读") }
        if !replyDebtItems.isEmpty { parts.append("\(replyDebtItems.count)条待回") }
        let pendingCommitments = monitor.commitments.filter { $0.status == .pending }.count
        if pendingCommitments > 0 { parts.append("\(pendingCommitments)个承诺") }
        return parts.joined(separator: "、")
    }

    // MARK: - Follow content

    private var vipContent: some View {
        let vipItems = vipNotifications.filter(\.isVIP)
        let watchItems = vipNotifications.filter { !$0.isVIP }

        return VStack(alignment: .leading, spacing: 0) {
            if vipNotifications.isEmpty {
                emptyState("暂无关注动态。白名单和 VIP 的最新消息会显示在这里。")
            } else {
                if !vipItems.isEmpty {
                    sectionHeader("VIP", count: vipItems.count)
                    ForEach(vipItems) { notif in
                        MessageRow(notification: notif)
                    }
                }
                if !watchItems.isEmpty {
                    sectionHeader("白名单", count: watchItems.count)
                    ForEach(watchItems) { notif in
                        MessageRow(notification: notif)
                    }
                }

                let notifiableRecalls = monitor.recalledMessages.filter { $0.aiShouldNotify == true }
                if !notifiableRecalls.isEmpty {
                    sectionHeader("撤回消息", count: notifiableRecalls.count)
                    ForEach(notifiableRecalls, id: \.id) { recalled in
                        RecalledMessageRow(recalled: recalled)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Unread content

    private var unreadContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            unreadFilterBar
            if filteredUnread.isEmpty {
                emptyState(emptyMessageForCurrentFilter)
            } else {
                ForEach(filteredUnread) { item in
                    UnreadRow(item: item, isSuppressedView: unreadFilter == .suppressed)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Reply debt content

    private var replyDebtContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if replyDebtItems.isEmpty {
                emptyState("没有待回复的聊天")
            } else {
                ForEach(replyDebtItems) { item in
                    ReplyDebtRow(item: item)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var emptyMessageForCurrentFilter: String {
        switch unreadFilter {
        case .needsReply: return "没有需要回复的消息"
        case .overdue:    return "没有超时未回复的消息"
        case .answered:   return "没有已回复的未读消息"
        case .suppressed: return "没有静默或延后的消息"
        case .all:        return "没有未读消息"
        }
    }

    /// Counts per filter. `needs` / `over` / `ans` come from the live
    /// unread list; `suppressed` comes from the separate suppressed list.
    private var unreadCounts: (all: Int, needsReply: Int, overdue: Int, answered: Int, suppressed: Int) {
        var needs = 0, over = 0, ans = 0
        for item in unreadItems {
            switch item.status {
            case .pending:  needs += 1
            case .overdue:  over += 1
            case .answered: ans += 1
            }
        }
        return (unreadItems.count, needs, over, ans, suppressedItems.count)
    }

    private var filteredUnread: [UnreadItem] {
        switch unreadFilter {
        case .all:        return unreadItems
        case .needsReply: return unreadItems.filter { $0.status == .pending }
        case .overdue:    return unreadItems.filter { $0.status == .overdue }
        case .answered:   return unreadItems.filter { $0.status == .answered }
        case .suppressed: return suppressedItems
        }
    }

    private var unreadFilterBar: some View {
        let c = unreadCounts
        return HStack(spacing: 4) {
            unreadFilterChip(.needsReply, label: "需要回复", count: c.needsReply)
            unreadFilterChip(.overdue,    label: "已超时",   count: c.overdue, accent: .red)
            unreadFilterChip(.answered,   label: "已回复",   count: c.answered)
            if c.suppressed > 0 {
                unreadFilterChip(.suppressed, label: "已处理", count: c.suppressed)
            }
            unreadFilterChip(.all,        label: "全部",     count: c.all)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func unreadFilterChip(
        _ filter: UnreadFilter,
        label: String,
        count: Int,
        accent: Color = .white
    ) -> some View {
        let selected = unreadFilter == filter
        return Button(action: { unreadFilter = filter }) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundColor(selected ? accent : .white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(selected ? Color.white.opacity(0.12) : Color.clear)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared bits

    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }
}

// MARK: - Message row (shared between VIP and unread)

private struct MessageRow: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    let notification: HUDNotification
    @State private var hovered = false
    @State private var showInsight = false

    var body: some View {
        VStack(spacing: 0) {
            FirstMouseRowHost {
                HStack(spacing: 8) {
                    kindIcon.frame(width: 18, height: 18)
                    content.lineLimit(1).truncationMode(.tail)
                    if notification.isVIP {
                        miniBadge("VIP", color: .yellow)
                    }
                    if notification.isVIP,
                       let insight = monitor.vipInsights[notification.chatUsername] {
                        VIPInlineTags(insight: insight)
                    }
                    if notification.canExplainContext {
                        GroupContextBriefingButton(notification: notification)
                    }
                    Spacer(minLength: 0)
                    Text(relativeTime(notification.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(height: notification.canExplainContext ? 34 : 30)
                .background(hovered ? Color.white.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        WeChatLauncher.copyText("\(notification.senderName): \(notification.snippet)")
                    } else if NSEvent.modifierFlags.contains(.option) {
                        panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                    } else if notification.isVIP,
                              monitor.vipInsights[notification.chatUsername] != nil {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showInsight.toggle()
                        }
                    } else {
                        WeChatLauncher.openChat(named: notification.chatName)
                    }
                }
                .contextMenu {
                Button {
                    WeChatLauncher.openChat(named: notification.chatName)
                } label: {
                    Label("在微信中打开", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                } label: {
                    Label("详细分析", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    WeChatLauncher.copyText("\(notification.senderName): \(notification.snippet)")
                } label: {
                    Label("复制消息", systemImage: "doc.on.doc")
                }

                Divider()

                Button {
                    monitor.updateWhitelistAttention(
                        username: notification.chatUsername,
                        displayName: notification.chatName,
                        isGroup: notification.chatUsername.contains("@chatroom"),
                        fallbackCategory: notification.chatUsername.contains("@chatroom") ? .work : .life,
                        attentionLevel: notification.isVIP ? .watch : .vip
                    )
                } label: {
                    Label(
                        notification.isVIP ? "降为白名单" : "设为 VIP",
                        systemImage: notification.isVIP ? "arrow.down.circle" : "star.fill"
                    )
                }

                Button {
                    monitor.ignoreSender(
                        chatUsername: notification.chatUsername,
                        chatName: notification.chatName,
                        senderUsername: notification.senderUsername,
                        senderName: notification.senderName
                    )
                } label: {
                    Label("忽略此人消息", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if showInsight, let insight = monitor.vipInsights[notification.chatUsername] {
            VIPInsightCardView(insight: insight, vipName: notification.senderName, chatUsername: notification.chatUsername)
        }
        }
    }

    @ViewBuilder
    private var kindIcon: some View {
        switch notification.kind {
        case .privateChat:
            kindBadge(color: .blue, symbol: "person.fill", size: 9)
        case .groupAt:
            kindBadge(color: .red, symbol: "at", size: 11)
        case .groupMessage:
            kindBadge(color: .orange, symbol: "person.3.fill", size: 8)
        }
    }

    private func kindBadge(color: Color, symbol: String, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.85))
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func miniBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private var content: Text {
        let sep = Text(" · ").foregroundColor(.white.opacity(0.35))
        let colon = Text(": ").foregroundColor(.white.opacity(0.7))
        let snippet = Text(notification.snippet).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
        let sender = Text(notification.senderName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

        switch notification.kind {
        case .privateChat:
            return sender + colon + snippet
        case .groupAt:
            let group = Text(notification.chatName).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
            let at = Text("@").font(.system(size: 11, weight: .bold)).foregroundColor(.red)
            return group + sep + at + sender + colon + snippet
        case .groupMessage:
            let group = Text(notification.chatName).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
            return group + sep + sender + colon + snippet
        }
    }
}

// MARK: - Unread row

private struct UnreadRow: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: UnreadItem
    /// When rendered inside the 已处理 filter, the context menu collapses
    /// to a single 恢复显示 action — silence/snooze would be a no-op.
    let isSuppressedView: Bool

    @State private var hovered = false

    var body: some View {
        FirstMouseRowHost {
            HStack(spacing: 8) {
                kindIcon.frame(width: 18, height: 18)
                content.lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if hovered && !isSuppressedView {
                    quickActions
                } else {
                    statusBadge
                    if !item.isWhitelisted,
                       let suggestion = monitor.whitelistSuggestions[item.chatUsername] {
                        WhitelistSuggestionBadge(chatUsername: item.chatUsername, suggestion: suggestion)
                    }
                }
                Text(relativeTime(item.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(height: 30)
            .background(rowBackground(hovered: hovered))
            .overlay(leftAccent, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture {
                guard !isSuppressedView else { return }
                if NSEvent.modifierFlags.contains(.command) {
                    WeChatLauncher.copyText("\(item.senderName): \(item.preview)")
                } else {
                    WeChatLauncher.openChat(named: item.chatName)
                }
            }
            .contextMenu { contextMenuContent }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if isSuppressedView {
            // Suppressed rows only have one meaningful action: put it
            // back. Silence-again or snooze-again makes no sense here.
            Button {
                if item.isIgnored {
                    monitor.unignoreSender(
                        chatUsername: item.chatUsername,
                        senderUsername: item.senderUsername,
                        senderName: item.senderName
                    )
                } else {
                    monitor.clearChatAction(item.chatUsername)
                }
            } label: {
                Label(
                    item.isIgnored ? "取消忽略此人" : "恢复显示",
                    systemImage: item.isIgnored ? "person.crop.circle.badge.checkmark" : "arrow.uturn.backward"
                )
            }
        } else {
            Button {
                WeChatLauncher.openChat(named: item.chatName)
            } label: {
                Label("在微信中打开", systemImage: "bubble.left.and.bubble.right")
            }
            Button {
                WeChatLauncher.copyText("\(item.senderName): \(item.preview)")
            } label: {
                Label("复制消息", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                monitor.silenceChat(item.chatUsername)
            } label: {
                Label("静默处理（看过了）", systemImage: "eye.slash")
            }

            if item.isWhitelisted && !item.isVIP {
                Button {
                    monitor.updateWhitelistAttention(
                        username: item.chatUsername,
                        displayName: item.chatName,
                        isGroup: item.chatUsername.contains("@chatroom"),
                        fallbackCategory: item.chatUsername.contains("@chatroom") ? .work : .life,
                        attentionLevel: .vip
                    )
                } label: {
                    Label("设为 VIP", systemImage: "star.fill")
                }
            }

            Button {
                monitor.ignoreSender(
                    chatUsername: item.chatUsername,
                    chatName: item.chatName,
                    senderUsername: item.senderUsername,
                    senderName: item.senderName
                )
            } label: {
                Label("忽略此人消息", systemImage: "person.crop.circle.badge.xmark")
            }

            Menu("延后提醒") {
                Button("30 分钟") { monitor.snoozeChat(item.chatUsername, minutes: 30) }
                Button("2 小时")  { monitor.snoozeChat(item.chatUsername, minutes: 120) }
                Button("今晚 20:00") { monitor.snoozeChat(item.chatUsername, until: snoozeTarget(hour: 20, nextDay: false)) }
                Button("明早 9:00")  { monitor.snoozeChat(item.chatUsername, until: snoozeTarget(hour: 9,  nextDay: true)) }
            }

            if !item.isWhitelisted {
                Divider()
                Button {
                    monitor.addUnreadToWhitelist(item)
                } label: {
                    Label("加入白名单", systemImage: "star")
                }
            }
        }
    }

    /// Overdue rows get a red tint so the user can spot them in
    /// peripheral vision. Everything else gets a hover highlight.
    @ViewBuilder
    private func rowBackground(hovered: Bool) -> some View {
        if item.status == .overdue {
            Color.red.opacity(hovered ? 0.2 : 0.12)
        } else if hovered {
            Color.white.opacity(0.08)
        } else {
            Color.clear
        }
    }

    /// 2pt accent bar on the left for overdue items — an extra visual
    /// cue for quick scanning even when the row is partially offscreen.
    @ViewBuilder
    private var leftAccent: some View {
        if item.status == .overdue {
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 2)
        } else if item.isVIP {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 2)
        } else {
            Color.clear.frame(width: 2)
        }
    }

    /// Inline quick action buttons shown on hover.
    private var quickActions: some View {
        HStack(spacing: 3) {
            quickActionButton(icon: "eye.slash", tip: "静默处理") {
                monitor.silenceChat(item.chatUsername)
            }
            quickActionButton(icon: "clock", tip: "延后30分钟") {
                monitor.snoozeChat(item.chatUsername, minutes: 30)
            }
            quickActionButton(icon: "bubble.left.and.bubble.right", tip: "打开微信") {
                WeChatLauncher.openChat(named: item.chatName)
            }
        }
    }

    private func quickActionButton(icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 20, height: 18)
                .background(Color.white.opacity(0.1))
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .overdue:
            Text("超时")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.8))
                .cornerRadius(2)
        case .answered:
            Text("已回复")
                .font(.system(size: 9))
                .foregroundColor(.green.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.15))
                .cornerRadius(2)
        case .pending:
            EmptyView()
        }
    }

    @ViewBuilder
    private var kindIcon: some View {
        let color: Color = item.kind == .groupAt ? .red : .blue
        let symbol = item.kind == .groupAt ? "at" : "envelope.fill"
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.85))
            Image(systemName: symbol)
                .font(.system(size: item.kind == .groupAt ? 11 : 9, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var content: Text {
        let colon = Text(": ").foregroundColor(.white.opacity(0.7))
        let snippet = Text(item.preview).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
        let sender = Text(item.senderName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

        switch item.kind {
        case .privateChat:
            return sender + colon + snippet
        case .groupAt:
            let group = Text(item.chatName).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
            let sep = Text(" · ").foregroundColor(.white.opacity(0.35))
            let at = Text("@").font(.system(size: 11, weight: .bold)).foregroundColor(.red)
            return group + sep + at + sender + colon + snippet
        case .groupMessage:
            let group = Text(item.chatName).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
            let sep = Text(" · ").foregroundColor(.white.opacity(0.35))
            return group + sep + sender + colon + snippet
        }
    }
}

// MARK: - Reply debt row

private struct ReplyDebtRow: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: ReplyDebtItem

    @State private var hovered = false
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            FirstMouseRowHost {
                HStack(alignment: .top, spacing: 8) {
                    priorityBadge
                        .frame(width: 26, height: 18)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.chatName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if item.isGroup {
                                Text("群聊")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.45))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(3)
                            }

                            Spacer(minLength: 0)

                            Text(relativeTime(item.timestamp))
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                                .monospacedDigit()
                        }

                        Text("\(item.senderName): \(item.preview)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            ForEach(Array(item.reasons.prefix(2))) { reason in
                                reasonChip(reason.label)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 42)
                .background(rowBackground)
                .overlay(leftAccent, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        WeChatLauncher.copyText("\(item.senderName): \(item.preview)")
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    }
                }
                .contextMenu { contextMenuContent }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                ReplyDebtExpandedView(item: item)
            }
        }
    }

    private var contextMenuContent: some View {
        Group {
            Button {
                WeChatLauncher.openChat(named: item.chatName)
            } label: {
                Label("在微信中打开", systemImage: "bubble.left.and.bubble.right")
            }

            Button {
                withAnimation { isExpanded = true }
            } label: {
                Label("AI 回复建议", systemImage: "sparkles")
            }

            Button {
                WeChatLauncher.copyText("\(item.senderName): \(item.preview)")
            } label: {
                Label("复制消息", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                monitor.silenceChat(item.chatUsername)
            } label: {
                Label("静默处理（看过了）", systemImage: "eye.slash")
            }

            Menu("延后提醒") {
                Button("30 分钟") { monitor.snoozeChat(item.chatUsername, minutes: 30) }
                Button("2 小时") { monitor.snoozeChat(item.chatUsername, minutes: 120) }
                Button("今晚 20:00") { monitor.snoozeChat(item.chatUsername, until: snoozeTarget(hour: 20, nextDay: false)) }
                Button("明早 9:00") { monitor.snoozeChat(item.chatUsername, until: snoozeTarget(hour: 9, nextDay: true)) }
            }
        }
    }

    private func reasonChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .cornerRadius(3)
    }

    private var priorityBadge: some View {
        Text(item.priority.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.9))
            .cornerRadius(4)
    }

    private var rowBackground: some View {
        if item.priority == .p0 {
            return AnyView(Color.red.opacity(hovered ? 0.2 : 0.12))
        }
        if item.priority == .p1 {
            return AnyView(Color.orange.opacity(hovered ? 0.18 : 0.1))
        }
        if hovered {
            return AnyView(Color.white.opacity(0.08))
        }
        return AnyView(Color.clear)
    }

    private var leftAccent: some View {
        Rectangle()
            .fill(priorityColor.opacity(0.8))
            .frame(width: 2)
    }

    private var priorityColor: Color {
        switch item.priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .white
        }
    }
}

/// Rows inside SwiftUI's `ScrollView` sit under deeper AppKit views than
/// the root window host, so they need their own first-mouse-capable
/// hosting view. Without this wrapper, AppKit can consume the first click
/// as "activate the panel" and the row's tap gesture only fires on click 2.
private struct FirstMouseRowHost<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> FirstMouseHostingView<Content> {
        let view = FirstMouseHostingView(rootView: content)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: FirstMouseHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

// relativeTime(_:) and snoozeTarget(hour:nextDay:) are defined in ViewHelpers.swift
