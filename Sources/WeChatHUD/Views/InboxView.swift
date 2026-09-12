import SwiftUI
import AppKit

enum InboxHeaderState: Equatable {
    case urgent(Int)        // p0 action items
    case replyNeeded(Int)   // p1/p2 action items (privateActionRequired / groupActionRequired)
    case mentioned(Int)     // group @mentions
    case updates(Int)       // passive updates only
    case idle
}

func visibleInboxItems(_ items: [InboxItem], showAllPassive: Bool = false, passiveLimit: Int = 3, limit: Int = 10) -> [InboxItem] {
    InboxPresentationPolicy.visibleItems(
        items,
        showAllPassive: showAllPassive,
        passiveLimit: passiveLimit,
        limit: limit
    )
}

func hiddenPassiveUpdateCount(_ items: [InboxItem], showAllPassive: Bool = false, passiveLimit: Int = 3, limit: Int = 10) -> Int {
    InboxPresentationPolicy.hiddenPassiveUpdateCount(
        items,
        showAllPassive: showAllPassive,
        passiveLimit: passiveLimit,
        limit: limit
    )
}

func inboxHeaderState(_ items: [InboxItem]) -> InboxHeaderState {
    let actionItems = items.filter { $0.participatesInActionQueue }
    let urgentCount = actionItems.filter { $0.priority == .p0 }.count
    if urgentCount > 0 { return .urgent(urgentCount) }

    let replyCount = actionItems.filter { $0.priority != .p0 }.count
    if replyCount > 0 { return .replyNeeded(replyCount) }

    let mentionCount = items.filter { $0.messageType == .groupMentionFYI }.count
    if mentionCount > 0 { return .mentioned(mentionCount) }

    let passiveCount = items.filter { $0.isAggregatablePassiveUpdate }.count
    if passiveCount > 0 { return .updates(passiveCount) }

    return .idle
}

/// Unified inbox — shows all messages in a single priority-sorted list
/// with action items on top, an undo bar, and a collapsible handled section.
struct InboxView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    @State private var undoItem: InboxItem? = nil
    @State private var undoAction: String = ""  // "已忽略" or "已贪睡" or "已静音"
    @State private var undoTimer: Timer? = nil
    @State private var showHandled = false
    @State private var showAllPassiveUpdates = false

    var body: some View {
        let activeItems = monitor.inboxItems
        let visibleItems = visibleInboxItems(activeItems, showAllPassive: showAllPassiveUpdates)
        let hiddenPassiveCount = hiddenPassiveUpdateCount(activeItems, showAllPassive: showAllPassiveUpdates)

        VStack(alignment: .leading, spacing: 0) {
            if panelState.islandSurface != .firstLaunch {
                header
            }
            if panelState.islandSurface == .inbox {
                // The brand block is an invitation, not chrome. It shows
                // only when there is nothing to act on; above a populated
                // list it pushed the first row ~200pt down and repeated the
                // product promise on every single open.
                if visibleItems.isEmpty {
                    islandBrandStrip
                } else {
                    islandSectionRow
                }
                islandStatusBanner
            }

            if panelState.islandSurface == .firstLaunch {
                IslandFirstLaunchView()
            } else if panelState.islandSurface == .tasks {
                IslandTaskPreview()
            } else if visibleItems.isEmpty {
                if !islandStatusBannerShowsCopy {
                    emptyState
                }
                if let snooze = panelState.islandSnoozeUndo {
                    undoBar(item: snooze.item, action: CompanionProductCopy.snoozeReceipt(until: snooze.until))
                }
                if !monitor.handledItems.isEmpty {
                    handledSection
                }
            } else {
                Divider().background(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleItems) { item in
                        InboxRowView(item: item, islandCatalog: true, onDismiss: {
                            guard monitor.dismissInboxItem(item) else { return }
                            undoAction = "已忽略"
                            withMotion(CompanionMotion.easeOut(0.25)) { undoItem = item }
                            scheduleUndoExpiry()
                        }, onSnooze: { date in
                            guard monitor.snoozeInboxItem(item, until: date) else { return }
                            undoAction = CompanionProductCopy.snoozeReceipt(until: date)
                            withMotion(CompanionMotion.easeOut(0.25)) { undoItem = item }
                            scheduleUndoExpiry()
                        }, onSilence: {
                            guard monitor.silenceInboxItem(item) else { return }
                            undoAction = "已静音"
                            withMotion(CompanionMotion.easeOut(0.25)) { undoItem = item }
                            scheduleUndoExpiry()
                        })
                    }

                    if hiddenPassiveCount > 0 || showAllPassiveUpdates {
                        Button(action: { showAllPassiveUpdates.toggle() }) {
                            Text(showAllPassiveUpdates ? "收起普通更新" : "还有 \(hiddenPassiveCount) 条普通更新")
                                .islandMicro()
                                .foregroundColor(IslandInk.tertiary)
                                .padding(.horizontal, IslandMetrics.sectionInset)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    let hiddenTotalCount = max(0, activeItems.count - visibleItems.count - hiddenPassiveCount)
                    if hiddenTotalCount > 0 {
                        Button(action: { panelState.showDetail() }) {
                            // This opens the separate detail window, not an
                            // in-place expansion, so the label says so.
                            Text("+\(hiddenTotalCount) 更多 — 查看全部（新窗口）")
                                .islandMicro()
                                .foregroundColor(IslandInk.tertiary)
                                .padding(.horizontal, IslandMetrics.sectionInset)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Undo bar
                    if let undo = undoItem {
                        undoBar(item: undo, action: undoAction)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let snooze = panelState.islandSnoozeUndo {
                        undoBar(item: snooze.item, action: CompanionProductCopy.snoozeReceipt(until: snooze.until))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Handled section (collapsed by default)
                    if !monitor.handledItems.isEmpty {
                        handledSection
                    }
                }
            }
            if panelState.islandSurface == .inbox {
                workspaceBar
            }
        }
    }

    /// List header. Replaces the 24pt bold "现在有 N 件事需要你" headline:
    /// the count already sits in the notch band, and the panel is 560pt
    /// wide — a headline that size is what made the HUD read as a phone app
    /// for a much smaller screen. The sync state moved here from the bottom
    /// bar, where it competed with the buttons for attention.
    private var islandSectionRow: some View {
        HStack(spacing: 8) {
            Text("需要你处理")
                .islandSection()
                .foregroundStyle(IslandInk.tertiary)
            Spacer(minLength: 8)
            // Sync state lives in this fixed slot — the "同步中" indicator
            // occupies exactly where the fresh-sync label sits, so a refresh starting
            // or finishing never changes the panel's measured height. The
            // old syncing banner was a whole row that popped in and out,
            // and every insertion moved the window.
            if case .syncing = monitor.stats.syncStatus {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 8, height: 8)
                   Text("同步中")
                       .islandMicro()
                        // Tertiary/quaternary are chrome only (IslandInk doc):
                        // sync state is something the user reads, so it stays
                        // on the `meta` step.
                        .foregroundStyle(IslandInk.meta)
                        .lineLimit(1)
                }
            } else if let syncAt = monitor.stats.lastSyncAt {
               Text(syncLabel(syncAt))
                   .islandMicro()
                    .foregroundStyle(IslandInk.meta)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var islandBrandStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CompanionPalette.islandMint)
            VStack(alignment: .leading, spacing: 2) {
                Text(CompanionProductCopy.brandName)
                    .islandBrand()
                    .foregroundStyle(IslandInk.primary)
                if !CompanionProductCopy.brandPromise.isEmpty {
                    Text(CompanionProductCopy.brandPromise)
                        .islandMeta()
                        .foregroundStyle(IslandInk.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.top, 11)
    }

    @ViewBuilder
    private var islandStatusBanner: some View {
        switch monitor.stats.syncStatus {
        case .error, .waitingForWeChat, .accountSwitched:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂时读不到新消息。请确认微信已经打开并登录。")
                    if let last = monitor.stats.lastSyncAt {
                        // syncLabel already carries the "同步" suffix
                        // ("270 分钟前同步"), so prefixing it here read as
                        // "上次同步 270 分钟前同步". This line owns the
                        // "上次同步" wording, so it takes the bare label.
                        Text("上次同步 \(RelativeTimeFormatter.relativeLabel(last))")
                            .foregroundStyle(IslandInk.tertiary)
                    }
                    Button("检查连接") {
                        panelState.pendingSettingsTab = "system"
                        panelState.showDetail()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.islandMint)
                }
            }
            .islandRowBody()
            .foregroundStyle(IslandInk.secondary)
            .padding(.horizontal, IslandMetrics.sectionInset)
            .padding(.vertical, 9)
        default:
            EmptyView()
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 14) {
            Button {
                panelState.islandSurface = .tasks
            } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundColor(IslandInk.secondary)
            }
            .buttonStyle(.plain)
            .help("查看待办")
            .accessibilityLabel("查看待办")

            Button {
                panelState.pendingSettingsTab = "today"
                panelState.showDetail()
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
                    .foregroundColor(IslandInk.tertiary)
            }
            .buttonStyle(.plain)
            .help(CompanionProductCopy.openCompanion)
            .accessibilityLabel(CompanionProductCopy.openCompanion)

            Spacer(minLength: 12)
            PixelBuddyView(mood: extendedBuddyMood)
                .frame(width: IslandMetrics.buddy, height: IslandMetrics.buddy)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 8)
        .background(IslandInk.bar)
    }

    // MARK: - Header

    private var extendedBuddyMood: BuddyMood {
        let activeCount = monitor.inboxItems.filter(\.participatesInActionQueue).count
        return deriveExtendedMood(actionItemCount: activeCount, isAIProcessing: false)
    }

    /// Top row of the extended panel — lives in the notch-height
    /// band so the island's "wings" remain visible around the
    /// cutout even after expansion (matching how the iOS Dynamic
    /// Island keeps its compact content visible when it blooms).
    /// Left wing: priority summary. Right wing: sync label + gear.
    /// Middle: notch gap (aligned with hardware on notched Macs,
    /// a small breathing gap on external displays).
    private var header: some View {
        return HStack(spacing: 0) {
            // Left wing — priority status
            HStack(spacing: 6) {
                switch inboxHeaderState(monitor.inboxItems) {
                case .urgent(let count):
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("\(count) 条紧急")
                        .islandMicro()
                        .foregroundColor(IslandInk.primary)
                case .replyNeeded(let count):
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("\(count) 条等你回复")
                        .islandMicro()
                        .foregroundColor(IslandInk.secondary)
                case .mentioned(let count):
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                    Text("\(count) 条 @了你")
                        .islandMicro()
                        .foregroundColor(IslandInk.tertiary)
                case .updates(let count):
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text("\(count) 条更新")
                        .islandMicro()
                        .foregroundColor(IslandInk.tertiary)
                case .idle:
                    Circle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 5, height: 5)
                   Text("一切正常")
                       .islandMicro()
                        .foregroundColor(IslandInk.meta)
                }
            }
            .padding(.leading, IslandMetrics.sectionInset)

            // Middle — notch cutout space
            Spacer(minLength: liveNotchWidth)

            // Right wing — autopilot indicator + sync label + gear.
            // Autopilot lives here because the compact-bar twin is only
            // glanceable (hovering the pill flips to extended), so the
            // actionable instance must live inside the extended view's
            // persistent header band.
            HStack(spacing: 8) {
                AutopilotIndicator()

                Button(action: { panelState.showDetail() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundColor(IslandInk.tertiary)
                }
                .buttonStyle(.plain)
                .help(CompanionProductCopy.openCompanion)
                .accessibilityLabel(CompanionProductCopy.openCompanion)
            }
            .padding(.trailing, IslandMetrics.sectionInset)
        }
        .frame(height: liveNotchHeight)
    }

    /// Live notch geometry from the running panel. Falls back to
    /// reasonable defaults in previews or early render paths.
    private var liveNotchWidth: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchWidth
        }
        return 16
    }

    private var liveNotchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }

    // MARK: - Undo Bar

    private func undoBar(item: InboxItem, action: String) -> some View {
        HStack(spacing: 8) {
            Text("\(item.chatName) · \(action)")
                .islandMicro()
                .foregroundColor(IslandInk.secondary)
                .lineLimit(1)
            Spacer()
            Button("撤销") {
                guard monitor.restoreInboxItem(item) else { return }
                withMotion(CompanionMotion.easeIn(0.2)) {
                    undoItem = nil
                    panelState.islandSnoozeUndo = nil
                }
                undoTimer?.invalidate()
                undoTimer = nil
            }
            .islandMicro()
            .buttonStyle(.plain)
            .foregroundColor(CompanionPalette.islandMint)
            .accessibilityLabel("撤销")
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 7)
        .background(IslandInk.hover)
    }

    // MARK: - Handled Section

    private var handledSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header (tap to expand/collapse)
            Button(action: { withMotion(CompanionMotion.rowExpand()) { showHandled.toggle() } }) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                   Text("已处理 (\(monitor.handledItems.count))")
                       .islandMicro()
                        .foregroundColor(IslandInk.meta)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(IslandInk.quaternary)
                        .rotationEffect(.degrees(showHandled ? 180 : 0))
                        .companionAnimation(CompanionMotion.rowExpand(), value: showHandled)
                    Rectangle()
                        .fill(IslandInk.divider)
                        .frame(height: 1)
                }
                .padding(.horizontal, IslandMetrics.sectionInset)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHandled {
                ForEach(monitor.handledItems) { item in
                    handledRow(item)
                }
            }
        }
    }

    private func handledRow(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(IslandInk.divider)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.chatName)
                    .islandMeta()
                    .foregroundColor(IslandInk.tertiary)
                    .lineLimit(1)
                if let summary = item.aiSummary, !summary.isEmpty {
                    Text(summary)
                        .islandMicro()
                        .foregroundColor(IslandInk.meta)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusLabel(item)
            Button(action: { monitor.restoreInboxItem(item) }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(IslandInk.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复这条消息")
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 5)
    }

    private func statusLabel(_ item: InboxItem) -> some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case .dismissed: return ("已忽略", .white.opacity(0.25))
            case .silenced: return ("已静音", .red.opacity(0.4))
            case .active, .snoozed: return ("", .clear)
            }
        }()
        return Text(text)
            .font(.system(size: 9))
            .foregroundColor(color)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        // No brand mark here: the empty inbox already renders the brand
        // block above this, and two copies of the same glyph is what made
        // the empty state read as a stretched-out placeholder.
        VStack(spacing: 6) {
            Spacer(minLength: 4)
            Text(islandEmptyCopy)
                .islandDisplay()
                .foregroundColor(IslandInk.primary)
                .multilineTextAlignment(.center)
            if let islandEmptyDetail {
                Text(islandEmptyDetail)
                    .islandRowBody()
                    .foregroundColor(IslandInk.tertiary)
                    .multilineTextAlignment(.center)
            }
            if !monitor.handledItems.isEmpty {
                Button("查看已处理") { showHandled = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
            }
            if let syncAt = monitor.stats.lastSyncAt {
               Label(syncLabel(syncAt), systemImage: "arrow.triangle.2.circlepath")
                   .islandMicro()
                    .foregroundColor(IslandInk.meta)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(islandEmptyCopy + (islandEmptyDetail.map { " \($0)" } ?? ""))
    }

    private var islandEmptyDetail: String? {
        switch monitor.stats.syncStatus {
        case .syncing, .error, .waitingForWeChat, .accountSwitched:
            return nil
        default:
            return FirstLaunchGuide.todayEmpty(
                wechatConnected: monitor.stats.lastSyncAt != nil,
                hasTrackedConversations: monitor.store.hasWhitelistEntries(),
                aiConfigured: true,
                aiTested: true,
                searching: false
            ).detail
        }
    }

    private var islandStatusBannerShowsCopy: Bool {
        switch monitor.stats.syncStatus {
        case .error, .waitingForWeChat, .accountSwitched: return true
        default: return false
        }
    }

    private var islandEmptyCopy: String {
        switch monitor.stats.syncStatus {
        case .syncing:
            return "正在同步…"
        case .error, .waitingForWeChat, .accountSwitched:
            return "暂时读不到新消息。请确认微信已经打开并登录。"
        default:
            return FirstLaunchGuide.compactEmpty(
                wechatConnected: monitor.stats.lastSyncAt != nil,
                hasTrackedConversations: monitor.store.hasWhitelistEntries()
            )
        }
    }

    // MARK: - Helpers

    private func syncLabel(_ date: Date) -> String {
        // One relative-time vocabulary for the whole panel; the suffix is
        // the only thing this slot adds: fresh, or N minutes/hours plus 同步.
        RelativeTimeFormatter.relativeLabel(date, suffix: "同步")
    }

    private func scheduleUndoExpiry() {
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                withMotion(CompanionMotion.easeIn(0.2)) { undoItem = nil }
                undoTimer = nil
            }
        }
    }
}

private struct IslandTaskPreview: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var reader: WeChatReader
    @State private var scope: DiscussionScope = .mine
    @State private var expandedID: Int64?
    @State private var sourceItem: DiscussionItem?
    @State private var receipt: String?
    @State private var undo: (id: Int64, status: DiscussionItemStatus)?
    @State private var itemsCache = DiscussionItemsCache()

    /// Resolved once per body evaluation; reading it from a row would re-sort
    /// the whole pending corpus for every row drawn.
    private var items: [DiscussionItem] {
        // Same level as the 待办 page: the island is a preview of that list, so
        // showing items the page has been told to hold back would make the two
        // disagree about how much work exists.
        itemsCache.items(surfacedDiscussionItems, scope: scope, query: "", history: false)
    }

    /// The corpus every island read goes through, so the level is applied once
    /// and cannot be forgotten at one of the five call sites.
    private var surfacedDiscussionItems: [DiscussionItem] {
        monitor.discussionItems.filter { monitor.discussionStrictness.admits($0) }
    }

    var body: some View {
        let items = self.items

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Back chevron returns to the inbox; "待办" is the title
                // of THIS surface — labelling the back button with the
                // current page's name read as navigating to itself.
                Button {
                    panelState.islandSurface = .inbox
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .islandRowTitle()
                .foregroundStyle(IslandInk.primary)
                .accessibilityLabel("返回收件箱")
                Text("待办")
                    .islandRowTitle()
                    .foregroundStyle(IslandInk.primary)
                Spacer()
                Text(items.count > 4 ? "共 \(items.count) 件" : "\(items.count) 件")
                    .islandMeta()
                    .foregroundStyle(CompanionPalette.islandMint)
                Button {
                    openWorkspace()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("打开待办")
            }
            HStack(spacing: 8) {
                ForEach([DiscussionScope.mine, .theirs], id: \.self) { value in
                    Button {
                        scope = value
                        expandedID = itemsCache.items(surfacedDiscussionItems, scope: value, query: "", history: false).first?.id
                    } label: {
                        Text(value.rawValue)
                            .companionFont(size: IslandType.meta, weight: scope == value ? .semibold : .regular)
                            .foregroundStyle(scope == value ? Color.white : IslandInk.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(scope == value ? CompanionPalette.jade : IslandInk.hover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }
            if items.isEmpty {
                Text(scope == .mine ? "没有我要做的事。" : (scope == .theirs ? "没有在等对方的事。" : "这一栏暂时是空的。"))
                    .islandRowBody()
                    .foregroundStyle(IslandInk.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(items.prefix(4)) { item in
                    islandTaskRow(item)
                }
            }
            if let receipt {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.islandMint)
                    Text(receipt).islandRowBody().foregroundStyle(IslandInk.primary)
                    Spacer()
                    if let undo {
                        Button("撤销") {
                            try? monitor.setDiscussionItemStatus(id: undo.id, status: undo.status)
                            self.undo = nil
                            self.receipt = nil
                        }
                        .foregroundStyle(CompanionPalette.islandMint)
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(CompanionPalette.jade.opacity(0.85), in: Capsule())
            }
            Button("查看全部待办") { openWorkspace() }
                .buttonStyle(.plain)
                .islandButton()
                .foregroundStyle(CompanionPalette.islandMint)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.bottom, 12)
        .onAppear {
            // The cache keeps these lookups to one sort per distinct scope.
            if itemsCache.items(surfacedDiscussionItems, scope: scope, query: "", history: false).isEmpty {
                let theirs = itemsCache.items(surfacedDiscussionItems, scope: .theirs, query: "", history: false)
                if !theirs.isEmpty {
                    scope = .theirs
                } else {
                    let shared = itemsCache.items(surfacedDiscussionItems, scope: .shared, query: "", history: false)
                    if !shared.isEmpty { scope = .shared }
                }
            }
            expandedID = itemsCache.items(surfacedDiscussionItems, scope: scope, query: "", history: false).first?.id
        }
        .sheet(item: $sourceItem) { item in
            DiscussionSourceView(item: item, onClose: { sourceItem = nil })
                .environmentObject(monitor)
                .environmentObject(reader)
        }
    }

    private func islandTaskRow(_ item: DiscussionItem) -> some View {
        let expanded = expandedID == item.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { complete(item) } label: {
                    Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(CompanionPalette.islandMint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("标记完成")
                Button {
                    withMotion(CompanionMotion.rowExpand()) {
                        expandedID = expanded ? nil : item.id
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DiscussionPresentation.dueLabel(item.dueAt)) \(item.content) · \(item.chatName)")
                            .companionFont(size: IslandType.rowTitle, weight: .medium)
                            .foregroundStyle(IslandInk.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandInk.quaternary)
            }
            if expanded {
                if let detail = item.detail, !detail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下一步").islandMeta().foregroundStyle(IslandInk.tertiary)
                        Text(detail).islandRowBody().foregroundStyle(IslandInk.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("查看原文") { sourceItem = item }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Button("标记完成") { complete(item) }
                        .buttonStyle(.borderedProminent)
                        .tint(CompanionPalette.jade)
                        .controlSize(.mini)
                }
            }
        }
        .padding(9)
        .background(IslandInk.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            if expanded {
                Capsule().fill(CompanionPalette.jade).frame(width: 3).padding(.vertical, 8)
            }
        }
    }

    private func openWorkspace() {
        panelState.pendingSettingsTab = "tasks"
        panelState.pendingDiscussionScope = scope
        panelState.showDetail()
    }

    private func complete(_ item: DiscussionItem) {
        do {
            try monitor.setDiscussionItemStatus(id: item.id, status: .done)
            undo = (item.id, .pending)
            receipt = "\(item.content)已标记完成"
        } catch {
            receipt = "没有保存成功，请重试"
            undo = nil
        }
    }
}

private struct IslandFirstLaunchView: View {
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(CompanionPalette.islandMint)
                Text(CompanionProductCopy.brandName)
                    .islandBrand()
                    .foregroundStyle(IslandInk.primary)
                Spacer()
            }
            Text(FirstLaunchGuide.islandConnectTitle)
                .companionFont(size: IslandType.display + 2, weight: .semibold)
                .foregroundStyle(IslandInk.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(FirstLaunchGuide.islandConnectDetail)
                .islandRowBody()
                .foregroundStyle(IslandInk.secondary)
            Button {
                NotificationCenter.default.post(name: .hudShowOnboarding, object: nil)
            } label: {
                Label("连接微信", systemImage: "bubble.left.and.bubble.right.fill")
                    .islandButton()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(CompanionPalette.jade, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("island.firstLaunch.connect")
            Button(FirstLaunchGuide.skipCTA) {
                panelState.islandSurface = .inbox
                panelState.collapse()
            }
            .buttonStyle(.plain)
            .islandMeta()
            .foregroundStyle(IslandInk.tertiary)
            .frame(maxWidth: .infinity)
            Divider().background(IslandInk.divider)
            VStack(alignment: .leading, spacing: 8) {
                Label(FirstLaunchGuide.islandConnectPrivacy[0], systemImage: "bubble.left")
                Label(FirstLaunchGuide.islandConnectPrivacy[1], systemImage: "checkmark.shield")
            }
            .islandMeta()
            .foregroundStyle(IslandInk.tertiary)
        }
        .padding(18)
    }
}
