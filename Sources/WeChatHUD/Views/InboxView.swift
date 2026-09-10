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
                islandBrandStrip
                hoverHeadline(count: visibleItems.count)
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
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    let hiddenTotalCount = max(0, activeItems.count - visibleItems.count - hiddenPassiveCount)
                    if hiddenTotalCount > 0 {
                        Button(action: { panelState.showDetail() }) {
                            Text("+\(hiddenTotalCount) 更多 — 查看详情")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
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

    private func hoverHeadline(count: Int) -> some View {
        Group {
            if count > 0 {
                Text("现在有 \(count) 件事需要你")
                    .companionFont(size: 24, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
        }
    }

    private var islandBrandStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CompanionPalette.islandMint)
            VStack(alignment: .leading, spacing: 3) {
                Text(CompanionProductCopy.brandName)
                    .companionFont(size: 16, weight: .semibold)
                    .foregroundStyle(.white)
                Text(CompanionProductCopy.brandPromise)
                    .companionFont(size: 13)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var islandStatusBanner: some View {
        switch monitor.stats.syncStatus {
        case .syncing:
            Label("正在读取你关注的聊天。你可以先去忙，整理好后在这里查看。", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 14))
                .foregroundStyle(CompanionPalette.islandMint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        case .error, .waitingForWeChat, .accountSwitched:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂时读不到新消息。请确认微信已经打开并登录。")
                    if let last = monitor.stats.lastSyncAt {
                        Text("上次同步 \(syncLabel(last))")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Button("检查连接") {
                        panelState.pendingSettingsTab = "system"
                        panelState.showDetail()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.islandMint)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        default:
            EmptyView()
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 10) {
            Button {
                panelState.islandSurface = .tasks
            } label: {
                Label("查看待办", systemImage: "checklist")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(CompanionPalette.jade, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                panelState.pendingSettingsTab = "today"
                panelState.showDetail()
            } label: {
                Label(CompanionProductCopy.openCompanion, systemImage: "macwindow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 16)
            if let syncAt = monitor.stats.lastSyncAt {
                Label(syncLabel(syncAt), systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .layoutPriority(0)
            }
            PixelBuddyView(mood: extendedBuddyMood)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.035))
    }

    // MARK: - Header

    private var extendedBuddyMood: BuddyMood {
        let activeCount = monitor.inboxItems.count
        let isProcessing = { if case .syncing = monitor.stats.syncStatus { return true }; return false }()
        return deriveExtendedMood(actionItemCount: activeCount, isAIProcessing: isProcessing)
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
                let compactCount = monitor.inboxItems.filter(\.surfacesInCompact).count
                if compactCount > 0 {
                    Circle()
                        .fill(CompanionPalette.islandMint)
                        .frame(width: 7, height: 7)
                    Text("\(compactCount) 项待处理")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                } else {
                switch inboxHeaderState(monitor.inboxItems) {
                case .urgent(let count):
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("\(count) 条紧急")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                case .replyNeeded(let count):
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    Text("\(count) 条等你回复")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                case .mentioned(let count):
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text("\(count) 条 @了你")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.75))
                case .updates(let count):
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text("\(count) 条更新")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                case .idle:
                    Circle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 6, height: 6)
                    Text("一切正常")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                }
            }
            .padding(.leading, 12)

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
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(CompanionProductCopy.openCompanion)
                .accessibilityLabel(CompanionProductCopy.openCompanion)
            }
            .padding(.trailing, 10)
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
            Text("\(item.chatName) \(action)")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
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
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Handled Section

    private var handledSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header (tap to expand/collapse)
            Button(action: { withMotion(CompanionMotion.ease(0.2)) { showHandled.toggle() } }) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                    Text("已处理 (\(monitor.handledItems.count))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.25))
                        .rotationEffect(.degrees(showHandled ? 180 : 0))
                        .companionAnimation(CompanionMotion.ease(0.2), value: showHandled)
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
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
                .fill(Color.white.opacity(0.1))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.chatName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                if let summary = item.aiSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }
            Spacer()
            statusLabel(item)
            Button(action: { monitor.restoreInboxItem(item) }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复这条消息")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
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
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22))
                .foregroundStyle(CompanionPalette.islandMint)
            Text(islandEmptyCopy)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            if let islandEmptyDetail {
                Text(islandEmptyDetail)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
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
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
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
        case .syncing, .error, .waitingForWeChat, .accountSwitched: return true
        default: return false
        }
    }

    private var islandEmptyCopy: String {
        switch monitor.stats.syncStatus {
        case .syncing:
            return "正在读取你关注的聊天。你可以先去忙，整理好后在这里查看。"
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
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚同步" }
        return "\(seconds / 60)分钟前同步"
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

    private var items: [DiscussionItem] {
        DiscussionPresentation.items(monitor.discussionItems, scope: scope, query: "", history: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    panelState.islandSurface = .inbox
                } label: {
                    Label("待办", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                Spacer()
                Text("还有 \(items.count) 件事")
                    .font(.system(size: 12))
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
                        expandedID = items.first?.id
                    } label: {
                        Text(value.rawValue)
                            .font(.system(size: 12, weight: scope == value ? .semibold : .regular))
                            .foregroundStyle(scope == value ? Color.white : .white.opacity(0.65))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(scope == value ? CompanionPalette.jade : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }
            if items.isEmpty {
                Text("现在没有需要你处理的事。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 8)
            } else {
                ForEach(items.prefix(4)) { item in
                    islandTaskRow(item)
                }
            }
            if let receipt {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.islandMint)
                    Text(receipt).font(.system(size: 12)).foregroundStyle(.white)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CompanionPalette.islandMint)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear {
            if items.isEmpty {
                if !DiscussionPresentation.items(monitor.discussionItems, scope: .theirs, query: "", history: false).isEmpty {
                    scope = .theirs
                } else {
                    scope = .all
                }
            }
            expandedID = items.first?.id
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if expanded {
                if let detail = item.detail, !detail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下一步").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
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
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(CompanionPalette.islandMint)
                Text(CompanionProductCopy.brandName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text(FirstLaunchGuide.islandConnectTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(FirstLaunchGuide.islandConnectDetail)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.65))
            Button {
                NotificationCenter.default.post(name: .hudShowOnboarding, object: nil)
            } label: {
                Label("连接微信", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(CompanionPalette.jade, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("island.firstLaunch.connect")
            Button(FirstLaunchGuide.skipCTA) {
                panelState.islandSurface = .inbox
                panelState.collapse()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            Divider().background(Color.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 8) {
                Label(FirstLaunchGuide.islandConnectPrivacy[0], systemImage: "bubble.left")
                Label(FirstLaunchGuide.islandConnectPrivacy[1], systemImage: "checkmark.shield")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(18)
    }
}
