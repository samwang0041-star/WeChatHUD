import SwiftUI
import AppKit

/// Which words the notch band prints. Deliberately a bare category: the number
/// the list header prints comes from `InboxPresentationPolicy.pendingCount`, so
/// the band's reading and the list's count cannot drift apart.
enum InboxHeaderState: Equatable {
    /// ≥1 p0 in the action queue.
    case urgent
    /// Action items, none p0 (privateActionRequired / groupActionRequired).
    case replyNeeded
    case mentioned   // group @mentions
    case updates     // passive updates only
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

/// Which category dominates the list, i.e. what the notch band says.
///
/// It reads the same buckets the list is built from, so the band cannot name a
/// category the rows do not contain: the mention test used to be
/// `messageType == .groupMentionFYI`, which also matched items the user had
/// already dealt with, and the band kept saying 「群里@了你」 over a list with no
/// such row. The number is no longer this function's business — see
/// `InboxPresentationPolicy.pendingCount`.
func inboxHeaderState(_ items: [InboxItem]) -> InboxHeaderState {
    let split = InboxPresentationPolicy.buckets(items)
    if split.action.contains(where: { $0.priority == .p0 }) { return .urgent }
    if !split.action.isEmpty { return .replyNeeded }
    if !split.fyi.isEmpty { return .mentioned }
    if !split.passive.isEmpty { return .updates }
    return .idle
}

/// Unified inbox — shows all messages in a single priority-sorted list
/// with action items on top, an undo bar, and a collapsible handled section.
struct InboxView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    @State private var undoItem: InboxItem? = nil
    @State private var undoAction: String = ""  // "已忽略" or "已贪睡" or "已静音"
    /// The undo window countdown. Pauseable: a lock or display sleep must not
    /// silently eat the user's chance to take back a dismissal.
    @State private var undoDeadline: PauseableDeadline? = nil
    /// Pointer and keyboard focus hold the same clock through one rule: being
    /// on (or in) the bar means reading it. Two separate suspend/resume hooks
    /// would cut each other's holds short.
    @State private var undoHovering = false
    @FocusState private var undoFocused: Bool
    @State private var showHandled = false
    @State private var showAllPassiveUpdates = false
    @State private var restoringHandledID: String?

    var body: some View {
        let activeItems = monitor.inboxItems
        let visibleItems = visibleInboxItems(activeItems, showAllPassive: showAllPassiveUpdates)
        let hiddenPassiveCount = hiddenPassiveUpdateCount(activeItems, showAllPassive: showAllPassiveUpdates)

        VStack(alignment: .leading, spacing: 0) {
            if panelState.islandSurface != .firstLaunch {
                header
            }
            if panelState.autopilotPopoverOpen, panelState.islandSurface != .firstLaunch {
                AutopilotPopoverView(close: {
                    withMotion(CompanionMotion.islandRowExpand()) {
                        panelState.setAutopilotPopoverOpen(false)
                    }
                })
                .padding(.horizontal, IslandMetrics.sectionInset)
                .padding(.bottom, 8)
                .transition(.islandDetailReveal)
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
                islandInboxActionError
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
                            withMotion(CompanionMotion.enter()) { undoItem = item }
                            scheduleUndoExpiry()
                        }, onSnooze: { date in
                            guard monitor.snoozeInboxItem(item, until: date) else { return }
                            undoAction = CompanionProductCopy.snoozeReceipt(until: date)
                            withMotion(CompanionMotion.enter()) { undoItem = item }
                            scheduleUndoExpiry()
                        }, onSilence: {
                            guard monitor.silenceInboxItem(item) else { return }
                            undoAction = "已静音"
                            withMotion(CompanionMotion.enter()) { undoItem = item }
                            scheduleUndoExpiry()
                        })
                    }

if hiddenPassiveCount > 0 || showAllPassiveUpdates {
                        Button(action: { withMotion(CompanionMotion.islandRowExpand()) { showAllPassiveUpdates.toggle() } }) {
                            Text(showAllPassiveUpdates ? "收起普通更新" : "还有 \(hiddenPassiveCount) 条普通更新")
                                .islandMicro()
                                .foregroundColor(IslandInk.meta)
                                .padding(.horizontal, IslandMetrics.sectionInset)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(IslandRowButtonStyle())
                    }

                    let hiddenTotalCount = max(0, activeItems.count - visibleItems.count - hiddenPassiveCount)
                    if hiddenTotalCount > 0 {
                        Button(action: { panelState.showDetail() }) {
                            // Same destination as the bottom-bar 查看全部: the
                            // companion workspace, not an in-place expansion.
                            Text("+\(hiddenTotalCount) 更多 — 查看全部")
                                .islandMicro()
                                .foregroundColor(IslandInk.meta)
                                .padding(.horizontal, IslandMetrics.sectionInset)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(IslandRowButtonStyle())
                        .help(CompanionProductCopy.openCompanion)
                        .accessibilityLabel(CompanionProductCopy.openCompanion)
                    }

                    // Undo bar
                    if let undo = undoItem {
                        undoBar(item: undo, action: undoAction)
                    } else if let snooze = panelState.islandSnoozeUndo {
                        undoBar(item: snooze.item, action: CompanionProductCopy.snoozeReceipt(until: snooze.until))
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
        .companionAnimation(CompanionMotion.islandRowExpand(), value: panelState.autopilotPopoverOpen)
        .companionAnimation(CompanionMotion.ease(), value: monitor.inboxActionError)
    }

    /// List header. Replaces the 24pt bold "现在有 N 件事需要你" headline:
    /// the panel is 560pt wide — a headline that size is what made the HUD
    /// read as a phone app for a much smaller screen. The sync state moved here
    /// from the bottom bar, where it competed with the buttons for attention.
    ///
    /// The count lives *here*, beside the list it counts, and mirrors the
    /// 「已处理 (N)」 footer label. It is the total the list stands for — action
    /// rows, group @s and the folded 「还有 N 条普通更新」 tail — because a number
    /// that counts only one of those disagreed with the rows printed under it.
    private var islandSectionRow: some View {
        HStack(spacing: 8) {
            Text("待处理 (\(InboxPresentationPolicy.pendingCount(monitor.inboxItems)))")
                .islandSection()
                .foregroundStyle(IslandInk.meta)
            Spacer(minLength: 8)
            // Sync state lives in this fixed slot — the "正在同步" indicator
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
                   Text("正在同步")
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
                .companionFont(size: 13, weight: .semibold)
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
                // A light rather than a warning triangle: the island already
                // uses the triangle in the compact wing for the same state,
                // and repeating the icon inside the panel it opens made the
                // same failure look like two different problems.
                CompanionStatusDot(tint: .orange, level: .attention, pulsing: false, size: 7)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                   // Fact, then the move. The button below is the action, so
                   // the sentence names what state WeChat has to be in rather
                   // than repeating the button verb.
                    Text(islandConnectionFact)
                    if let last = monitor.stats.lastSyncAt {
                        // syncLabel already carries the "同步" suffix
                        // ("270 分钟前同步"), so prefixing it here read as
                        // "上次同步 270 分钟前同步". This line owns the
                        // "上次同步" wording, so it takes the bare label.
                        Text("上次同步 \(RelativeTimeFormatter.relativeLabel(last))")
                            .foregroundStyle(IslandInk.tertiary)
                    }
                    Button(islandConnectionMove) {
                        panelState.pendingSettingsTab = "system"
                        panelState.showDetail()
                    }
                    .buttonStyle(IslandRowButtonStyle())
                    .foregroundStyle(CompanionPalette.islandMint)
                    .help(islandConnectionHelp)
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

    @ViewBuilder
    private var islandInboxActionError: some View {
        if let error = monitor.inboxActionError {
            HStack(alignment: .top, spacing: 8) {
                Text(error)
                    .islandRowBody()
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("知道了") { monitor.inboxActionError = nil }
                    .buttonStyle(IslandRowButtonStyle())
                    .islandMicro()
                    .foregroundStyle(CompanionPalette.islandMint)
                    .accessibilityLabel("知道了")
            }
            .padding(.horizontal, IslandMetrics.sectionInset)
            .padding(.vertical, 9)
            .transition(.companionStatusReveal)
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 10) {
Button {
                withMotion(CompanionMotion.islandRowExpand()) { panelState.islandSurface = .tasks }
            } label: {
                barAction(glyph: "checklist", title: "待办", ink: IslandInk.secondary)
            }
            .buttonStyle(IslandIconButtonStyle())
            .help("查看待办")
            .accessibilityLabel("查看待办")

            Button {
                panelState.pendingSettingsTab = "today"
                panelState.showDetail()
            } label: {
                barAction(glyph: "macwindow", title: "查看全部", ink: IslandInk.tertiary)
            }
            .buttonStyle(IslandIconButtonStyle())
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

    /// A bottom-bar jump, named. Two bare glyphs on a 560 pt bar asked the user
    /// to hover a tooltip before acting, and the bar is the one piece of island
    /// chrome that is always on screen.
    ///
    /// The 22pt square used to be the pointer target; with a title the whole
    /// label is the target, which is wider than the glyph frame ever was.
    private func barAction(glyph: String, title: String, ink: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .companionFont(size: 11)
            Text(title)
                .companionFont(size: 11)
        }
        .foregroundColor(ink)
        .frame(minHeight: InboxView.barIconTarget)
        .contentShape(Rectangle())
    }

    /// Minimum height for the island's bottom-bar jumps.
    ///
    /// 22pt is the standard macOS push-button height. The island cannot afford
    /// much more than that in a 32pt-tall bar, but it should not ask the pointer
    /// for 12pt precision either.
    static let barIconTarget: CGFloat = 22

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
                case .urgent:
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("有急事要处理")
                        .islandMicro()
                        .foregroundColor(IslandInk.primary)
                case .replyNeeded:
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("等你回复")
                        .islandMicro()
                        .foregroundColor(IslandInk.secondary)
                case .mentioned:
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                    Text("群里@了你")
                        .islandMicro()
                        .foregroundColor(IslandInk.meta)
                case .updates:
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text("普通更新")
                        .islandMicro()
                        .foregroundColor(IslandInk.meta)
                case .idle:
                    Circle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 5, height: 5)
                   Text("没有待处理")
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
                        .companionFont(size: 11)
                        .foregroundColor(IslandInk.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandIconButtonStyle())
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
                CompanionMotion.performCommitTick()
                withMotion(CompanionMotion.exit()) {
                    undoItem = nil
                    panelState.islandSnoozeUndo = nil
                }
                undoDeadline?.cancel()
            }
            .islandMicro()
            .buttonStyle(IslandRowButtonStyle())
            .foregroundColor(CompanionPalette.islandMint)
            .accessibilityLabel("撤销")
            .focused($undoFocused)
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 7)
        .background(IslandInk.hover)
        // Same top-anchored scale as every other island disclosure. A bottom
        // slide was a layout-property animation and left/entered a different
        // edge from the toast that hangs off this same island.
        .transition(.islandDetailReveal)
        // Pointing at the bar — or sitting on its button with the keyboard —
        // means reading it: freeze the undo window until both are clear.
        .onHover { hovering in
            undoHovering = hovering
            applyUndoClockHold()
        }
        .onChange(of: undoFocused) { applyUndoClockHold() }
    }

    private func applyUndoClockHold() {
        if undoHovering || undoFocused {
            undoDeadline?.suspend()
        } else {
            undoDeadline?.resume()
        }
    }

    // MARK: - Handled Section

    private var handledSection: some View {
        VStack(alignment: .leading, spacing: 0) {
// Section header (tap to expand/collapse)
            Button(action: { withMotion(CompanionMotion.islandRowExpand()) { showHandled.toggle() } }) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                   Text("已处理 (\(monitor.handledItems.count))")
                       .islandMicro()
                        .foregroundColor(IslandInk.meta)
                    Image(systemName: "chevron.down")
                        .companionFont(size: 10, weight: .semibold)
                        .foregroundColor(IslandInk.quaternary)
.rotationEffect(.degrees(showHandled ? 180 : 0))
                        .companionAnimation(CompanionMotion.islandRowExpand(), value: showHandled)
                    Rectangle()
                        .fill(IslandInk.divider)
                        .frame(height: 1)
                }
                .padding(.horizontal, IslandMetrics.sectionInset)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandRowButtonStyle())

            if showHandled {
                ForEach(monitor.handledItems) { item in
                    handledRow(item)
                        .transition(.islandDetailReveal)
                }
            }
}
        .companionAnimation(CompanionMotion.islandRowExpand(), value: showHandled)
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
            Button {
                guard restoringHandledID == nil else { return }
                restoringHandledID = item.id
                monitor.restoreInboxItem(item)
                restoringHandledID = nil
            } label: {
                Group {
                    if restoringHandledID == item.id {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                            .companionFont(size: 10, weight: .medium)
                            .foregroundColor(IslandInk.tertiary)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandIconButtonStyle())
            .disabled(restoringHandledID != nil)
            .help(restoringHandledID != nil ? "正在恢复这条消息" : "恢复这条消息")
            .accessibilityLabel(restoringHandledID == item.id ? "正在恢复这条消息" : "恢复这条消息")
            .accessibilityHint(restoringHandledID != nil ? "正在恢复这条消息" : "")
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
            .islandMicro()
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
            if let move = islandEmptyMove {
                Button(move.title, action: move.run)
                    .buttonStyle(IslandRowButtonStyle())
                    .foregroundStyle(CompanionPalette.islandMint)
                    .help(move.hint)
                    .accessibilityLabel(move.title)
                    .accessibilityHint(move.hint)
            }
if !monitor.handledItems.isEmpty {
                Button("查看已处理") { withMotion(CompanionMotion.islandRowExpand()) { showHandled = true } }
                    .buttonStyle(IslandRowButtonStyle())
                    .foregroundStyle(CompanionPalette.islandMint)
                    .controlSize(.small)
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
        .accessibilityElement(children: .contain)
    }

    /// The two AI facts the empty-state copy branches on. They used to be
    /// `true` literals at the call site below, so a user with no AI set up got
    /// 「没有待处理的事 / 没有新消息。」 instead of the 「摘要和草稿还没准备好」
    /// that is actually true for them — and the island has no other place that
    /// says so.
    private var aiReadiness: (configured: Bool, tested: Bool) {
        let configuration = monitor.store.loadAIConfig()
        return (
            AISettingsValidation.connectionError(configuration.provider, requireModel: true) == nil,
            AIConnectionEvidenceStore.isSuccessful(configuration, store: monitor.store)
        )
    }

    /// Whether anything is still open in 待办 or 承诺. This reached
    /// `todayEmpty` as a default `false`, so the island answered
    /// 「没有待处理的事」 while work was sitting in the user's own list.
    /// The predicates are the 今日 page's own statics — the island does not
    /// get to decide a second time what "open" means.
    private var hasOpenWorkForIsland: Bool {
        let strictness = monitor.discussionStrictness
        let items = monitor.discussionItems
        return TodayFeed.hasOpenWork(
            mine: TodayFeed.mineTasks(items, strictness: strictness),
            waiting: TodayFeed.waitingTasks(items, strictness: strictness),
            upcoming: monitor.commitments.filter { $0.status == .pending || $0.status == .overdue }
        )
    }

    /// The island's own second line. It used to borrow
    /// `FirstLaunchGuide.todayEmpty`, whose sentences describe the 今日 page
    /// (「…在右侧」, the 我要做/等对方 tab names) — true there, false on a 36px
    /// bar. Same order of checks, per-surface wording, and no claim the island
    /// cannot verify.
    private var islandEmptyDetail: String? {
        switch monitor.stats.syncStatus {
        case .syncing, .error, .waitingForWeChat, .accountSwitched:
            return nil
        default:
            break
        }
        if monitor.stats.lastSyncAt == nil { return "连上微信之后才会开始整理消息。" }
        if !monitor.store.hasWhitelistEntries() { return "先选一个联系人或群聊，只整理你选中的对话。" }
        let ai = aiReadiness
        if !ai.configured { return "没有 AI 也能看微信原文；配上服务之后才会出摘要和回复建议。" }
        if !ai.tested { return "AI 配置已填，测通一次才会出摘要和草稿。" }
        if hasOpenWorkForIsland { return "待办和答应过的事还没清完。" }
        return nil
    }

    /// One next step, matching the empty copy. The banner already owns
    /// 检查连接 for WeChat errors, so this stays off that path.
    private var islandEmptyMove: (title: String, hint: String, run: () -> Void)? {
        switch monitor.stats.syncStatus {
        case .syncing, .error, .waitingForWeChat, .accountSwitched:
            return nil
        default:
            break
        }
        if monitor.stats.lastSyncAt == nil {
            return (
                title: "连接微信",
                hint: "打开连接引导",
                run: { NotificationCenter.default.post(name: .hudShowOnboarding, object: nil) }
            )
        }
        if !monitor.store.hasWhitelistEntries() {
            return (
                title: "关注谁",
                hint: "选择要整理的对话",
                run: {
                    panelState.pendingSettingsTab = "contacts"
                    panelState.showDetail()
                }
            )
        }
        let ai = aiReadiness
        if !ai.configured || !ai.tested {
            return (
                title: "设置 AI",
                hint: "配置并测试 AI 服务",
                run: {
                    panelState.pendingSettingsTab = "aiButler"
                    panelState.showDetail()
                }
            )
        }
        if hasOpenWorkForIsland {
            return (
                title: "查看待办",
                hint: "打开岛内待办",
run: {
                    withMotion(CompanionMotion.islandRowExpand()) { panelState.islandSurface = .tasks }
                }
            )
        }
        return nil
    }

   private var islandStatusBannerShowsCopy: Bool {
       switch monitor.stats.syncStatus {
       case .error, .waitingForWeChat, .accountSwitched: return true
       default: return false
       }
   }

    private var islandConnectionSwitched: Bool {
        if case .accountSwitched = monitor.stats.syncStatus { return true }
        return false
    }

    private var islandConnectionFact: String {
        islandConnectionSwitched
            ? CompanionInteractionCopy.accountSwitched
            : CompanionInteractionCopy.wechatUnreadable
    }

    private var islandConnectionMove: String {
        islandConnectionSwitched ? "选定当前账号" : "检查连接"
    }

    private var islandConnectionHelp: String {
        islandConnectionSwitched
            ? CompanionInteractionCopy.accountSwitchedEmpty
            : CompanionInteractionCopy.needWeChatRunning
    }

   private var islandEmptyCopy: String {
       switch monitor.stats.syncStatus {
      case .syncing:
          return "正在同步…"
        case .accountSwitched:
            return CompanionInteractionCopy.accountSwitchedEmpty
        case .error, .waitingForWeChat:
            return CompanionInteractionCopy.wechatUnreadableEmpty
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
        if undoDeadline == nil {
            undoDeadline = PauseableDeadline {
                withMotion(CompanionMotion.exit()) { undoItem = nil }
            }
        }
        undoDeadline?.start(3)
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
    @State private var isUndoing = false
    @State private var undoError: String?

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
                    withMotion(CompanionMotion.islandRowExpand()) { panelState.islandSurface = .inbox }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandIconButtonStyle())
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
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandIconButtonStyle())
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
                    }
                    .buttonStyle(IslandPillButtonStyle(emphasized: scope == value))
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }
            if items.isEmpty {
                Text(scope == .mine ? "没有我要做的事。" : (scope == .theirs ? "没有在等对方的事。" : "这一栏暂时是空的。"))
                    .islandRowBody()
                    .foregroundStyle(IslandInk.tertiary)
                    .padding(.vertical, 8)
                islandTaskEmptyMove
            } else {
                ForEach(items.prefix(4)) { item in
                    islandTaskRow(item)
                }
            }
            if let receipt {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.islandMint)
                    Text(receipt).islandRowBody().foregroundStyle(IslandInk.primary)
                    if let undoError {
                        Text(undoError)
                            .islandRowBody()
                            .foregroundStyle(Color.orange)
                            .transition(.companionStatusReveal)
                    }
                    Spacer()
                    if let undo {
                        Button {
                            guard !isUndoing else { return }
                            isUndoing = true
                            Task { @MainActor in
                                defer { isUndoing = false }
                                do {
                                    try monitor.setDiscussionItemStatus(id: undo.id, status: undo.status)
                                    self.undo = nil
                                    self.receipt = nil
                                    undoError = nil
                                } catch {
                                    undoError = "撤销没有成功，请重试。"
                                }
                            }
                        } label: {
                            Text(isUndoing ? "正在撤销…" : "撤销")
                        }
                        .foregroundStyle(CompanionPalette.islandMint)
                        .buttonStyle(IslandRowButtonStyle())
                        .disabled(isUndoing)
                        .help(isUndoing ? "正在撤销刚才的操作" : "")
                        .accessibilityHint(isUndoing ? "正在撤销刚才的操作" : "")
                    }
                }
                .padding(8)
                .background(CompanionPalette.jade.opacity(0.85), in: Capsule())
                .transition(.companionStatusReveal)
            }
            Button("查看全部待办") { openWorkspace() }
                .buttonStyle(IslandRowButtonStyle())
                .islandButton()
                .foregroundStyle(CompanionPalette.islandMint)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.bottom, 12)
        .companionAnimation(CompanionMotion.ease(), value: receipt)
        .companionAnimation(CompanionMotion.ease(), value: undoError)
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
        .sheet(item: $sourceItem, onDismiss: {
            // onDismiss is owned by the presentation machinery and survives
            // view teardown — a plain onChange could die with the view and
            // wedge islandTextInputActive on forever.
            panelState.islandTextInputActive = false
        }) { item in
            DiscussionSourceView(item: item, onClose: { sourceItem = nil })
                .environmentObject(monitor)
                .environmentObject(reader)
        }
        // The sheet hosts text/controls — the island must accept keyboard
        // input for its cancel-action and focus to work (same latch the
        // rename sheet uses).
        .onChange(of: sourceItem != nil) { _, open in
            if open { panelState.islandTextInputActive = true }
        }
        .onDisappear {
            // Backstop: if this surface unmounts with ITS sheet still up,
            // don't leave the island latched into key-input mode. Only
            // clear when this view's sheet was the writer — another
            // surface's open sheet must keep its latch.
            if sourceItem != nil {
                panelState.islandTextInputActive = false
            }
        }
    }

    private func islandTaskRow(_ item: DiscussionItem) -> some View {
        let expanded = expandedID == item.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { complete(item) } label: {
                    Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(CompanionPalette.islandMint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandIconButtonStyle())
                .accessibilityLabel("标记完成")
Button {
                    withMotion(CompanionMotion.islandRowExpand()) {
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
                .buttonStyle(IslandRowButtonStyle())
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundStyle(IslandInk.quaternary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
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
                        .tint(CompanionPalette.jade)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                }
                .transition(.islandDetailReveal)
            }
        }
        .padding(9)
        .background(IslandInk.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            if expanded {
                Capsule().fill(CompanionPalette.jade).frame(width: 3).padding(.vertical, 8)
            }
}
        .companionAnimation(CompanionMotion.islandRowExpand(), value: expanded)
    }

    private var islandOtherScopeWithItems: DiscussionScope? {
        let candidates: [DiscussionScope]
        switch scope {
        case .mine: candidates = [.theirs, .shared]
        case .theirs: candidates = [.mine, .shared]
        default: candidates = [.mine, .theirs]
        }
        for candidate in candidates {
            if !itemsCache.items(surfacedDiscussionItems, scope: candidate, query: "", history: false).isEmpty {
                return candidate
            }
        }
        return nil
    }

    @ViewBuilder
    private var islandTaskEmptyMove: some View {
        let hidden = monitor.discussionStrictness.hidden(from: monitor.discussionItems)
        let other = islandOtherScopeWithItems
        if let other {
            Button(other.rawValue) {
                withMotion(CompanionMotion.pageChange()) {
                    scope = other
                    expandedID = itemsCache.items(surfacedDiscussionItems, scope: other, query: "", history: false).first?.id
                }
            }
            .buttonStyle(IslandRowButtonStyle())
            .foregroundStyle(CompanionPalette.islandMint)
            .accessibilityLabel("去\(other.rawValue)")
        } else if !hidden.isEmpty {
            Button("切到「全记」") {
                withMotion(CompanionMotion.pageChange()) {
                    monitor.setDiscussionStrictness(.everything)
                }
            }
            .buttonStyle(IslandRowButtonStyle())
            .foregroundStyle(CompanionPalette.islandMint)
            .accessibilityLabel("切到全记，查看收起的待办")
        } else if monitor.stats.lastSyncAt == nil {
            Button("连接微信") {
                NotificationCenter.default.post(name: .hudShowOnboarding, object: nil)
            }
            .buttonStyle(IslandRowButtonStyle())
            .foregroundStyle(CompanionPalette.islandMint)
            .accessibilityLabel("打开连接引导")
        } else if !monitor.store.hasWhitelistEntries() {
            Button("关注谁") {
                panelState.pendingSettingsTab = "contacts"
                panelState.showDetail()
            }
            .buttonStyle(IslandRowButtonStyle())
            .foregroundStyle(CompanionPalette.islandMint)
            .accessibilityLabel("选择要整理的对话")
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

struct IslandFirstLaunchView: View {
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
                .islandDisplay()
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
            }
            .buttonStyle(IslandInboxRowButtonStyle(
                highlighted: false,
                resting: CompanionPalette.jade,
                cornerRadius: 10
            ))
            .accessibilityIdentifier("island.firstLaunch.connect")
            Button(FirstLaunchGuide.skipCTA) {
                panelState.islandSurface = .inbox
                panelState.collapse()
            }
            .buttonStyle(IslandRowButtonStyle())
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
