import SwiftUI

struct AssistantTodayView: View {
    /// Hit area for the two inline glyph buttons in the search row.
    ///
    /// 22pt is the standard macOS push-button height; it is the smallest target
    /// this app uses anywhere for something the pointer has to find, and it is
    /// deliberately larger than the 13pt glyph it wraps. Before this the
    /// magnifier measured 12×13 — a target the hand cannot reliably hit, in a
    /// row the eye reads as a single control.
    static let inlineIconTarget: CGFloat = 22

    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var panelState: PanelState
    let navigate: (SettingsView.Tab) -> Void
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var showUpdates = false
    @State private var showMissed = false
    @State private var missedWindow: MissedReplyFinder.Window = .last7Days
    @State private var missedCustomStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var missedCustomEnd = Date()
    @State private var dismissed: InboxItem?
    @State private var expandedID: String?
    @State private var snoozeReceipt: String?
    @State private var revealedOriginalIDs: Set<String> = []
    @State private var readiness: OnboardingReadiness?
    @State private var busyInboxID: String?
    @State private var busyInboxKind: InboxBusyKind?

    private enum InboxBusyKind {
        case dismiss, snooze, restore

        var help: String {
            switch self {
            case .dismiss: return "正在标为已处理"
            case .snooze: return "正在保存稍后提醒"
            case .restore: return "正在撤销刚才的操作"
            }
        }
    }

    private var inboxBusy: Bool { busyInboxID != nil }

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

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CompanionSetupCard(navigate: navigate)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            todayScopePills
                            todayJumpPills
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { todayScopePills }
                            HStack(spacing: 8) { todayJumpPills }
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
                .workspacePage(WorkspacePage.wideWidth)
            }
        }
        .onAppear {
            if PreviewRuntime.opensTodayMissedReplies { showMissed = true }
            refreshReadiness()
            if monitor.missedReplies.isEmpty && !monitor.missedReplyLoading {
                let bounds = missedWindow.bounds(customStart: missedCustomStart, customEnd: missedCustomEnd)
                monitor.refreshMissedReplies(start: bounds.start, end: bounds.end)
            }
        }
        // Keep the empty-state copy honest after the user configures/tests AI
        // from the setup card or a sync completes while this page is open.
        // onChange fires only on an actual transition, so the directory scan
        // in refreshReadiness isn't repeated on every monitor publish.
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConfigDidChange)) { _ in refreshReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConnectionEvidenceDidChange).receive(on: RunLoop.main)) { _ in refreshReadiness() }
        .onChange(of: monitor.stats.lastSyncAt) { _, _ in refreshReadiness() }
        .onChange(of: showMissed) { _, showing in
            panelState.todayShowsMissedReplies = showing
        }
        .companionAnimation(CompanionMotion.pageChange(), value: showMissed)
        .onDisappear {
            panelState.todayShowsMissedReplies = false
        }
    }

    private func refreshReadiness() {
        let candidates = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        readiness = OnboardingReadiness.evaluate(monitor: monitor, store: store, candidates: candidates)
    }

    private var messageFeed: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text(showMissed ? "这段时间有人找你" : (showUpdates ? "这些对话有更新" : "先处理这些事")).workspaceTitle()
                Spacer()
                // Closure, not another queue. Every other number on this page
                // counts what is left; without this one the page can only ever
                // report that you are behind. Shown only once there is
                // something to be finished with, so a fresh install is not
                // greeted by a zero.
                if handledTodayCount > 0 && !showMissed {
                    Text(CompanionInteractionCopy.handledToday(handledTodayCount))
                        .workspaceMeta()
                        // On-wash step: this row sits in the band the module
                        // wash covers, where the ordinary secondary style no
                        // longer clears AA.
                        .onWashSecondary()
                    // A divider, because this is a different kind of number
                    // from the queue count beside it: one is history, the
                    // other is an action. Without the rule the two read as
                    // one crowded meta line.
                    Text("·")
                        .workspaceMeta()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if !showMissed {
                    Button { showUpdates.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(showUpdates ? "只看需要回复的" : "全部 \(TodayFeed.allUpdatesCount(monitor.inboxItems)) 条")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CompanionPalette.jadeInk)
                    }
                    .buttonStyle(CompanionPressStyle())
                }
            }
            HStack(spacing: 9) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        // The glyph is 13pt; the target is what the pointer
                        // has to hit. Measured at 12×13 before this frame,
                        // which is under every macOS control metric — the
                        // smallest system control is 16pt and the standard
                        // one 22. The extra area is invisible: it is the same
                        // glyph in the same place, with a hit region that the
                        // hand can actually find.
                        .frame(width: Self.inlineIconTarget, height: Self.inlineIconTarget)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("搜索联系人或消息")
                    .help("搜索联系人或消息（⌘F）")
                TextField("搜索联系人或消息", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索联系人或消息")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: Self.inlineIconTarget, height: Self.inlineIconTarget)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(CompanionIconButtonStyle()).accessibilityLabel("清除搜索")
                        .help("清除搜索")
                } else {
                    Text("⌘ F").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(searchFieldFace)
            .overlay(
                RoundedRectangle(cornerRadius: CompanionElevation.insetRadius, style: .continuous)
                    .strokeBorder(
                        searchFocused ? CompanionPalette.accent.opacity(0.55) : CompanionPalette.border,
                        lineWidth: 1
                    )
            )
            // A field sits *inside* the page rather than on top of it, so it
            // takes a focus halo instead of the card lift. A light source above
            // the page means a well reads as recessed, not raised.
            .shadow(
                color: searchFocused ? CompanionPalette.accent.opacity(0.16) : .clear,
                radius: 10, y: 0
            )
            .companionAnimation(CompanionMotion.hover(), value: searchFocused)

            if showMissed {
                MissedReplyFeed(
                    window: $missedWindow,
                    customStart: $missedCustomStart,
                    customEnd: $missedCustomEnd,
                    query: $query
                )
                .transition(.companionStatusReveal)
            } else if visible.isEmpty {
                if let readiness {
                    let empty = FirstLaunchGuide.todayEmpty(
                        wechatConnected: readiness.hasSuccessfulSync,
                        hasTrackedConversations: readiness.trackedConversationCount > 0,
                        aiConfigured: readiness.aiConfigurationValid,
                        aiTested: readiness.aiConnectionTested,
                        searching: !query.isEmpty,
                        hasOpenTasks: TodayFeed.hasOpenWork(mine: mineTasks, waiting: waitingTasks, upcoming: upcoming),
                        hasOtherInboxItems: !showUpdates && TodayFeed.hasNonReplyUpdates(monitor.inboxItems)
                    )
                    VStack(spacing: 12) {
                    ContentUnavailableView(empty.title, systemImage: query.isEmpty ? "tray" : "magnifyingglass", description: Text(empty.detail))
                        todayEmptyAction(readiness: readiness)
                    }
                        .frame(maxWidth: .infinity).padding(.vertical, 28).companionSurface()
                        .transition(.companionStatusReveal)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { item in
                        messageCard(item, expanded: expandedID == item.id || (expandedID == nil && item.id == visible.first?.id))
                    }
                }
                .transition(.companionStatusReveal)
            }
            if let dismissed {
                HStack {
                    Label("已处理 · \(dismissed.chatName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CompanionPalette.accent)
                    Spacer()
                    Button {
                        commitInboxAction(id: dismissed.id, kind: .restore) {
                            if monitor.restoreInboxItem(dismissed) { self.dismissed = nil }
                        }
                    } label: {
                        Text(busyInboxKind == .restore ? "正在撤销…" : "撤销")
                    }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .disabled(inboxBusy)
                        .help(inboxBusy ? (busyInboxKind?.help ?? "") : "")
                        .accessibilityHint(inboxBusy ? (busyInboxKind?.help ?? "") : "")
                }.font(.callout).companionSurface(padding: 14)
                    .transition(.companionStatusReveal)
            }
            if let error = monitor.inboxActionError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("知道了") { monitor.inboxActionError = nil }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                }.font(.callout).companionSurface(padding: 14)
                    .transition(.companionStatusReveal)
            }
            if let snoozeReceipt {
                HStack {
                    Label(snoozeReceipt, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CompanionPalette.jadeInk)
                    Spacer()
                    Button("知道了") { self.snoozeReceipt = nil }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                }.font(.callout).companionSurface(padding: 14)
                    .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: dismissed?.id)
        .companionAnimation(CompanionMotion.ease(), value: snoozeReceipt)
        .companionAnimation(CompanionMotion.ease(), value: monitor.inboxActionError)
    }

    private func collapsedSummary(_ summary: String) -> String {
        summary.count > 28 ? String(summary.prefix(28)) + "…" : summary
    }

    /// How many items the user has already cleared today. Counts the handled
    /// list rather than a session counter, so it survives a relaunch and means
    /// the same thing on every launch.
    private var handledTodayCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return monitor.handledItems.filter { $0.timestamp >= start }.count
    }

    /// The search well: slightly darker than the card it sits on, lit along
    /// its bottom edge so the top edge reads as the shadowed side.
    private var searchFieldFace: some View {
        let shape = RoundedRectangle(cornerRadius: CompanionElevation.insetRadius, style: .continuous)
        return ZStack {
            shape.fill(CompanionPalette.surface)
            if !CompanionMotion.reduceTransparency {
                shape.fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.10), Color.white.opacity(0.030)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }

    private func snooze(_ item: InboxItem, until: Date) {
        commitInboxAction(id: item.id, kind: .snooze) {
            guard monitor.snoozeInboxItem(item, until: until) else { return }
            snoozeReceipt = CompanionProductCopy.snoozeReceipt(until: until)
        }
    }

    private func commitInboxAction(id: String, kind: InboxBusyKind, _ work: @escaping () -> Void) {
        guard busyInboxID == nil else { return }
        busyInboxID = id
        busyInboxKind = kind
        Task { @MainActor in
            defer {
                busyInboxID = nil
                busyInboxKind = nil
            }
            work()
        }
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
                        }.buttonStyle(CompanionRowPressStyle())
                        if commitment.id != upcoming.prefix(3).last?.id { Divider() }
                    }
                }
                Button { navigate(.commitments) } label: {
                    HStack { Text("查看我答应的事"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.system(size: 12, weight: .medium))
                }.buttonStyle(CompanionRowPressStyle())
            }.companionSurface()
            connectionCard
            VStack(spacing: 0) {
                quickLink("今日小结", subtitle: SettingsView.Tab.dailyReport.subtitle, icon: "doc.text") { navigate(.dailyReport) }
                Divider().padding(.horizontal, 16)
                quickLink("按时间回顾", subtitle: "回到发生过的对话", icon: "calendar") { RetrospectiveWindowManager.shared.showWindow(monitor: monitor) }
            }.companionSurface(padding: 0)
        }
    }

    private func quickLink(_ title: String, subtitle: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(CompanionPalette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(CompanionRowPressStyle())
    }

    @ViewBuilder
    private func todayEmptyAction(readiness: OnboardingReadiness) -> some View {
        if !query.isEmpty {
            Button("清除搜索") { query = "" }
                .buttonStyle(.bordered)
                .accessibilityLabel("清除搜索")
        } else if !readiness.hasSuccessfulSync {
            Button("检查连接") { navigate(.system) }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("检查微信连接")
        } else if readiness.followListUnreadable {
            Button("再试一次") { refreshReadiness() }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
        } else if readiness.trackedConversationCount == 0 {
            Button("关注谁") { navigate(.contacts) }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("去选要关注的对话")
        } else if !showUpdates && TodayFeed.hasNonReplyUpdates(monitor.inboxItems) {
            Button("全部") { withMotion(CompanionMotion.pageChange()) { showUpdates = true } }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("查看全部更新")
        } else if TodayFeed.hasOpenWork(mine: mineTasks, waiting: waitingTasks, upcoming: upcoming) {
            Button("我要做") { navigate(.tasks) }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("打开待办")
        } else if !readiness.aiConfigurationValid || !readiness.aiConnectionTested {
            Button("设置 AI") { navigate(.aiButler) }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("去设置 AI")
        } else {
            Button { monitor.refreshNow() } label: {
                Label(isSyncing ? "正在同步…" : "查看新消息", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CompanionPressStyle())
            .foregroundStyle(CompanionPalette.jadeInk)
            .disabled(isSyncing)
            .help(isSyncing ? "正在读取新消息" : "")
            .accessibilityHint(isSyncing ? "正在读取新消息" : "")
            .accessibilityLabel("查看新消息")
        }
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
                    .buttonStyle(CompanionPressStyle())
                Button { monitor.refreshNow() } label: { Label(isSyncing ? "正在同步…" : "查看新消息", systemImage: "arrow.clockwise") }
                    .buttonStyle(CompanionPressStyle())
                    .disabled(isSyncing)
                    .help(isSyncing ? "正在读取新消息" : "")
                    .accessibilityHint(isSyncing ? "正在读取新消息" : "")
                Spacer()
            }.controlSize(.small)
            if monitor.classificationPendingCount > 0 {
                HStack {
                    Label(monitor.classificationProcessing ? "正在分析 \(monitor.classificationPendingCount) 条消息" : "\(monitor.classificationPendingCount) 条消息等待分析", systemImage: "sparkles")
                    Spacer()
                    Button(monitor.classificationProcessing ? "正在分析…" : "重试分析") {
                        do { try store.retryClassificationMessages(); monitor.drainClassificationQueue() }
                        catch { panelState.showToast("暂时无法重试，请检查本地数据连接") }
                    }
                    .buttonStyle(CompanionPressStyle())
                    .disabled(monitor.classificationProcessing)
                    .help(monitor.classificationProcessing ? "正在分析消息" : "")
                    .accessibilityHint(monitor.classificationProcessing ? "正在分析消息" : "")
                }.font(.callout).foregroundStyle(.secondary)
            }
            if monitor.discussionPendingCount > 0 {
                HStack {
                    Label(monitor.discussionProcessing ? "正在从 \(monitor.discussionPendingCount) 条消息整理待办" : "\(monitor.discussionPendingCount) 条消息等待整理待办", systemImage: "checklist")
                    Spacer()
                    Button(monitor.discussionProcessing ? "正在整理…" : "重试整理") {
                        do { try monitor.retryDiscussionExtraction() }
                        catch { panelState.showToast("暂时无法重试整理，请检查本地数据连接") }
                    }
                    .buttonStyle(CompanionPressStyle())
                    .disabled(monitor.discussionProcessing)
                    .help(monitor.discussionProcessing ? "正在整理待办" : "")
                    .accessibilityHint(monitor.discussionProcessing ? "正在整理待办" : "")
                }.font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("关注 \(store.whitelistCount()) 个对话", systemImage: "person.2")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button("关注谁") { navigate(.contacts) }.buttonStyle(CompanionPressStyle())
                    Button("设置 AI") { navigate(.aiButler) }.buttonStyle(CompanionPressStyle())
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
        case .accountSwitched: return CompanionInteractionCopy.accountSwitched
       case .error: return "微信连接需要处理"
        }
    }
    private var syncColor: Color {
        switch monitor.stats.syncStatus { case .ok: return .green; case .syncing, .idle: return .blue; default: return .orange }
    }
    private var syncSymbol: String {
        switch monitor.stats.syncStatus { case .ok: return "checkmark.circle"; case .syncing, .idle: return "arrow.triangle.2.circlepath"; default: return "exclamationmark.triangle" }
    }

    @ViewBuilder private var todayScopePills: some View {
        // Three glyphs each, like the two jump pills beside them. The row is a
        // single visual unit only while the labels are the same length; at
        // 4/3/3/3 the first chip was measurably wider than its neighbours.
        filterPill("要回复", count: needsReply.count, selected: !showUpdates && !showMissed) {
            showUpdates = false
            showMissed = false
        }
        filterPill("没回的", count: monitor.missedReplies.count, selected: showMissed) {
            showMissed = true
            showUpdates = false
        }
    }

    @ViewBuilder private var todayJumpPills: some View {
        jumpPill("我要做", count: mineTasks.count) {
            panelState.pendingDiscussionScope = .mine
            navigate(.tasks)
        }
        jumpPill("等对方", count: waitingTasks.count) {
            panelState.pendingDiscussionScope = .theirs
            navigate(.tasks)
        }
    }

    private func filterPill(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        // Quiet selected wash in the brand accent. Filters are the current
        // view, not a second primary action.
        CompanionFilterPill(
            title: "\(title) \(count)",
            selected: selected,
            tint: SettingsView.Tab.today.accentColor,
            action: action
        )
        .accessibilityLabel("\(title)，\(count) 项")
    }

    private func jumpPill(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(title) \(count)")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            // Same metrics as CompanionFilterPill: these sit in one row,
            // and the 2pt mismatch made the group look misaligned.
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(CompanionPalette.surface, in: Capsule())
            .overlay(Capsule().companionHairline())
        }
        .buttonStyle(CompanionPressStyle())
        .accessibilityLabel("\(title)，\(count) 项")
        .accessibilityHint("打开待办")
    }

    private func messageCard(_ item: InboxItem, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withMotion(CompanionMotion.rowExpand()) {
                    expandedID = expanded && expandedID == item.id ? "" : item.id
                }
            } label: {
                HStack(spacing: 10) {
                    CompanionAvatar(name: item.chatName, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.chatName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        Text(item.timestamp, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if item.isAtMention { CompanionBadge(title: "@ 我") }
                    if !expanded { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(CompanionPressStyle())

            Text(item.aiSummary?.isEmpty == false ? (expanded ? item.aiSummary! : collapsedSummary(item.aiSummary!)) : item.preview)
                .font(.system(size: expanded ? 16 : 14, weight: expanded ? .semibold : .regular))
                .lineSpacing(4).textSelection(.enabled).lineLimit(expanded ? 6 : 1)

            if expanded {
                if item.aiSummary?.isEmpty == false {
                    // The hero line above *is* this summary. This strip used to
                    // print it again — the same sentence twice in one card, two
                    // sizes apart — and then offer the original through two
                    // controls one line apart (a 「查看原文」 button and a
                    // 「消息原文」 disclosure). What the card needs here is
                    // provenance for the line above, plus one way to read what
                    // the person actually wrote.
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CompanionPalette.jadeInk)
                            .frame(width: 5, height: 5)
                        Text("AI 解读").font(.system(size: 11, weight: .semibold)).foregroundStyle(CompanionPalette.jadeInk)
                        Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Button(revealedOriginalIDs.contains(item.id) ? "收起原文" : "查看消息原文") {
                            withMotion(CompanionMotion.ease()) {
                                if revealedOriginalIDs.contains(item.id) {
                                    revealedOriginalIDs.remove(item.id)
                                } else {
                                    revealedOriginalIDs.insert(item.id)
                                }
                            }
                        }
                        .buttonStyle(CompanionPressStyle())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CompanionPalette.jadeInk)
                        Spacer(minLength: 8)
                    }
                    .padding(.top, 1)

                    if revealedOriginalIDs.contains(item.id) {
                        Text(item.preview).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            .transition(.companionStatusReveal)
                    }
                }
               HStack {
                   Button { panelState.showChatDetail(chatUsername: item.chatUsername, chatName: item.chatName) } label: {
                       Label("理解上下文与回复", systemImage: "text.bubble")
                   }
                   .tint(CompanionPalette.jade)
                   .buttonStyle(.borderedProminent)
                   Menu {
                       ForEach(CompanionProductCopy.snoozeChoices()) { choice in
                            Button("\(choice.label)  \(choice.whenLabel)") { snooze(item, until: choice.until) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("稍后提醒")
                    .disabled(inboxBusy)
                    .help(inboxBusy ? (busyInboxKind?.help ?? "稍后提醒") : "稍后提醒")
                    .accessibilityHint(inboxBusy ? (busyInboxKind?.help ?? "") : "")
                    Spacer()
                    // 「标为已处理」, the same words the inbox row's action uses.
                    // On its own 「已处理」 reads as a status label, and this is a
                    // button that changes the status.
                    Button {
                        commitInboxAction(id: item.id, kind: .dismiss) {
                            if monitor.dismissInboxItem(item) { dismissed = item }
                        }
                    } label: {
                        Text(busyInboxID == item.id && busyInboxKind == .dismiss ? "正在处理…" : "标为已处理")
                    }
                    .buttonStyle(.bordered)
                    .disabled(inboxBusy)
                    .help(inboxBusy ? (busyInboxKind?.help ?? "") : "")
                    .accessibilityHint(inboxBusy ? (busyInboxKind?.help ?? "") : "")
                }
                .controlSize(.regular)
                .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: revealedOriginalIDs.contains(item.id))
        .companionAnimation(CompanionMotion.rowExpand(), value: expanded)
        .companionSurface()
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
