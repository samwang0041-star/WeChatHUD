import SwiftUI

/// A single row in the unified inbox list.
/// Shows priority dot, contact info, status labels, and hover actions.
struct InboxRowView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var reader: WeChatReader
    let item: InboxItem
    var islandCatalog: Bool = false
    let onDismiss: () -> Void
    var onSnooze: ((Date) -> Void)? = nil
    var onSilence: (() -> Void)? = nil

    @State private var hovered = false
    // Expansion is owned by PanelState so only one row is open at a time.
    @State private var showSnoozeMenu = false
    @State private var snoozeHoverClose: DispatchWorkItem?
    @State private var renamingChat: InboxItem?
    /// Un-following clears the chat's commitments, todos, mute and snooze
    /// state with it and cannot be undone from here, so the menu item only
    /// arms the confirmation.
    @State private var confirmUntrack = false
    @State private var isUntracking = false
    @State private var untrackError: String?
    @State private var busyAction: InboxRowBusy?

    private enum InboxRowBusy {
        case dismiss, snooze, silence

        var help: String {
            switch self {
            case .dismiss: return "正在标为已处理"
            case .snooze: return "正在保存稍后提醒"
            case .silence: return "正在保存静音"
            }
        }
    }

    private var isRowBusy: Bool { busyAction != nil || isUntracking }
    /// The inbox often opens under the pointer (menu "查看新消息", hover
    /// expand). Treating that as hover puts clock/✕ on the first row and
    /// reads as a stuck notification banner. Wait until a later hover event.
    @State private var hoverEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withMotion(CompanionMotion.islandRowExpand()) {
                    if panelState.expandedInboxItemID == item.id {
                        panelState.expandedInboxItemID = nil
                    } else {
                        panelState.expandedInboxItemID = item.id
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    if islandCatalog {
                        CompanionAvatar(name: item.chatName, size: IslandMetrics.avatar)
                    } else {
                        priorityDot
                            .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        firstLine
                        if islandCatalog {
                            catalogTitle
                        } else {
                            secondLine
                            inlineBriefingLine
                        }
                    }
                }
                .padding(.horizontal, IslandMetrics.rowInset)
                .padding(.vertical, IslandMetrics.rowPadding)
            }
            .buttonStyle(IslandInboxRowButtonStyle(
                highlighted: hovered || showSnoozeMenu || confirmUntrack
            ))
            .overlay(alignment: .topTrailing) {
                // Overlay, not in-flow: hover actions slide in over the
                // timestamp/chevron they replace instead of pushing the
                // whole row left — in-flow placement re-laid-out the row
                // on every hover and read as a flicker.
                //
                // The buttons stay MOUNTED when not hovered — conditionally
                // removing them drops them from the accessibility tree, so a
                // VoiceOver user (no pointer to hover with) could never
                // reach 稍后提醒 / 标为已处理. Opacity keeps them invisible;
                // hit-testing stays off so they can't eat phantom clicks.
                hoverButtons
                    .padding(.leading, 8)
                    .background(CompanionPalette.island, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 4)
                    .padding(.trailing, IslandMetrics.rowInset)
                    .opacity(hovered || showSnoozeMenu || confirmUntrack || busyAction != nil ? 1 : 0)
                    .allowsHitTesting(hovered || showSnoozeMenu || confirmUntrack || busyAction != nil)
            }
            .overlay {
                // Dedicated VoiceOver expand/collapse control: invisible and
                // never pointer-hit, but a real Button in the AX tree —
                // an .accessibilityAction on the row container is dropped
                // because .contain makes the row itself a non-element.
                Button(panelState.expandedInboxItemID == item.id ? "收起详情" : "展开详情") {
                    withMotion(CompanionMotion.islandRowExpand()) {
                        panelState.expandedInboxItemID =
                            panelState.expandedInboxItemID == item.id ? nil : item.id
                    }
                }
                .opacity(0)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(false)
            }
            .accessibilityElement(children: .contain)
            .contextMenu {
                contextMenuContent
            }
            .sheet(item: $renamingChat, onDismiss: {
                panelState.islandTextInputActive = false
            }) { target in
                ChatRenameSheet(
                    chatUsername: target.chatUsername,
                    currentName: monitor.displayName(for: target.chatUsername),
                    memberNames: reader.groupMemberNames(for: target.chatUsername)
                )
                .onAppear { panelState.islandTextInputActive = true }
            }

            if showSnoozeMenu {
                IslandSnoozeMenu { date in
                    showSnoozeMenu = false
                    panelState.setSnoozeMenuExpanded(false)
                    runInboxAction(.snooze) { onSnooze?(date) }
                }
                .padding(.horizontal, IslandMetrics.rowInset)
                .padding(.bottom, IslandMetrics.rowPadding)
                .transition(.islandDetailReveal)
            }

            if confirmUntrack {
                IslandUntrackConfirm(
                    chatName: item.chatName,
                    isUntracking: isUntracking,
                    error: untrackError,
                    onCancel: {
                        guard !isUntracking else { return }
                        confirmUntrack = false
                        untrackError = nil
                    },
                    onConfirm: confirmUntrackNow
                )
                .padding(.horizontal, IslandMetrics.rowInset)
                .padding(.bottom, IslandMetrics.rowPadding)
                .transition(.islandDetailReveal)
            }

            if panelState.expandedInboxItemID == item.id {
                ActionPanelView(item: item)
                    .transition(.islandDetailReveal)
            }
        }
        .onHover { inside in
            guard hoverEnabled else { return }
            hovered = inside
            snoozeHoverClose?.cancel()
            if inside { return }
            let work = DispatchWorkItem {
                guard showSnoozeMenu else { return }
                showSnoozeMenu = false
                panelState.setSnoozeMenuExpanded(false)
            }
            snoozeHoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                hoverEnabled = true
            }
        }
        .onChange(of: showSnoozeMenu) { _, open in
            panelState.setSnoozeMenuExpanded(open)
        }
        .onDisappear {
            // The deferred close must die with the row — a pending work
            // item firing after unmount calls setSnoozeMenuExpanded(false),
            // which can unlatch a snooze menu another surface just opened.
            snoozeHoverClose?.cancel()
            snoozeHoverClose = nil
            if showSnoozeMenu {
                showSnoozeMenu = false
                panelState.setSnoozeMenuExpanded(false)
            }
        }
        .companionAnimation(CompanionMotion.hover(), value: hovered)
        .companionAnimation(CompanionMotion.islandRowExpand(), value: showSnoozeMenu)
        .companionAnimation(CompanionMotion.islandRowExpand(), value: panelState.expandedInboxItemID)
        .companionAnimation(CompanionMotion.islandRowExpand(), value: confirmUntrack)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(item.actionRequired ? "标为已处理" : "隐藏这条更新") {
            runInboxAction(.dismiss, onDismiss)
        }
        Menu("稍后提醒") {
            ForEach(CompanionProductCopy.snoozeChoices()) { choice in
                Button("\(choice.label)  \(choice.whenLabel)") { runInboxAction(.snooze) { onSnooze?(choice.until) } }
            }
        }
        Button("静音此对话") {
            runInboxAction(.silence) { onSilence?() }
        }

        Divider()

        Button("重命名此对话…") {
            renamingChat = item
        }
        Button("在微信中打开") {
            monitor.openWeChatChat(item.chatUsername)
        }
        Button("查看对话详情") {
            panelState.showChatDetail(chatUsername: item.chatUsername,
                                      chatName: monitor.displayName(for: item.chatUsername))
        }
        Button("复制消息原文") {
            copyInboxText(item.preview)
        }
        if let summary = item.aiSummary, !summary.isEmpty {
            Button("复制 AI 摘要") {
                copyInboxText(summary)
            }
        }

        Divider()

        if item.isWhitelisted {
            if item.isVIP {
                Button("降为普通关注") {
                    applyFollowChange { monitor.setInboxItemVIP(item, isVIP: false) }
                }
            } else {
                Button("设为 VIP") {
                    applyFollowChange { monitor.setInboxItemVIP(item, isVIP: true) }
                }
            }
            Button("取消关注此对话", role: .destructive) {
                showSnoozeMenu = false
                panelState.setSnoozeMenuExpanded(false)
                untrackError = nil
                confirmUntrack = true
            }
        } else {
            Button(item.isGroup ? "关注此群聊" : "关注此联系人") {
                applyFollowChange { monitor.setInboxItemVIP(item, isVIP: !item.isGroup) }
            }
        }

        if item.isGroup, !item.senderName.isEmpty {
            Divider()
            Button("忽略 \(item.senderName) 的消息") {
                applyFollowChange { monitor.ignoreInboxItemSender(item) }
            }
        }
    }

    // MARK: - First Line

    private var firstLine: some View {
        HStack(spacing: 6) {
            Text(item.displayReason.isEmpty
                 ? item.chatName
                : "\(item.chatName) · \(item.displayReason)")
                .islandRowTitle()
                .foregroundColor(IslandInk.primary)
                .lineLimit(1)

            if item.isVIP, let mood = item.moodEmoji, !mood.isEmpty {
                Text(mood)
                    .islandMeta()
            }

            Spacer()

            // Hidden on hover: the action chip overlays this corner and a
            // half-covered timestamp reads as two UIs stacked on each other.
            // opacity(0) keeps the layout width so nothing reflows.
            Text(relativeTime(item.timestamp))
                .islandMeta()
                .foregroundColor(IslandInk.tertiary)
                .opacity(hovered || showSnoozeMenu ? 0 : 1)
            if islandCatalog {
                Image(systemName: "chevron.right")
                    .companionFont(size: 12, weight: .semibold)
                    .foregroundColor(IslandInk.quaternary)
                    .opacity(hovered || showSnoozeMenu ? 0 : 1)
            }
        }
    }

    private var catalogTitle: some View {
        Text(item.aiSummary?.isEmpty == false ? item.aiSummary! : item.preview)
            .islandRowBody()
            .foregroundColor(IslandInk.secondary)
            .lineLimit(2)
    }

    private var reasonTagColor: Color {
        switch item.messageType {
        case .privateActionRequired, .groupActionRequired:
            return item.priority == .p0 ? .red : (item.priority == .p1 ? .orange : .white)
        case .privateVIPRisk:
            return .orange
        case .groupMentionFYI:
            return .blue
        default:
            return IslandInk.secondary
        }
    }

    // MARK: - Second Line

    private var secondLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Primary: original message preview (always visible)
            HStack(spacing: 0) {
                if item.isGroup, !item.senderName.isEmpty {
                    Text(item.senderName + ": ")
                        .islandMeta()
                        .foregroundColor(IslandInk.tertiary)
                }
                Text(item.preview)
                    .islandRowBody()
                    .foregroundColor(IslandInk.secondary)
                    .lineLimit(1)
            }

            // Secondary: AI summary (marked with sparkle to distinguish from original)
            if let summary = item.aiSummary, !summary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .islandMicro()
                        .foregroundColor(.orange.opacity(0.7))
                    Text(summary)
                        .islandMeta()
                        .foregroundColor(IslandInk.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Tier 2: inline briefing

    /// Find the HUDNotification that corresponds to this inbox item.
    /// Inbox items are keyed by chatUsername, so a row for a group
    /// @mention matches the most recent @mention notification for that
    /// chat in `recentNotifications` (which is capped to ~10 items).
    private var matchingNotification: HUDNotification? {
        guard item.isGroup, item.isAtMention else { return nil }
        // Prefer the notification this row was actually built from. Searching
        // recentNotifications by chatUsername alone can return a *different*
        // @ for the same group, so the "他想你…" briefing line ends up
        // explaining another message than the preview/timestamp on this row.
        if let ctx = item.contextNotification,
           ctx.chatUsername == item.chatUsername, ctx.canExplainContext {
            return ctx
        }
        return monitor.recentNotifications.first {
            $0.chatUsername == item.chatUsername && $0.canExplainContext
        }
    }

    /// Rendered "他想你: ..." inline briefing, or a compact "正在分析"
   /// placeholder while the briefing is in flight. Returns nil (row
    /// doesn't render this region) when the item isn't a group
    /// @mention or when no briefing activity has been started yet —
    /// keeps rows that don't need this feature visually unchanged.
    @ViewBuilder
    private var inlineBriefingLine: some View {
        if let notif = matchingNotification {
            let state = monitor.groupContextState(for: notif)
            if state.isLoading && state.briefing == nil {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .islandMicro()
                        .foregroundColor(.orange.opacity(0.7))
                    Text("正在分析…")
                       .islandMeta()
                        .foregroundColor(IslandInk.tertiary)
                }
            } else if let briefing = state.briefing {
                // Only true action rows get the actionable line. FYI
                // mentions stay neutral so a plain @ does not become
                // "需要你处理" by copy alone.
                let summaryText: String = {
                    if item.semanticState == .groupActionRequired,
                       let action = briefing.deepSuggestedAction,
                       !action.isEmpty {
                        return action
                    }
                    return briefing.whyMentioned
                }()
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .islandMicro()
                        .foregroundColor(.orange.opacity(0.85))
                    Text(summaryText)
                        .islandMeta()
                        .foregroundColor(IslandInk.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Priority Dot

    private var priorityDot: some View {
        PriorityPulseDot(color: priorityColor, isUrgent: item.priority == .p0, level: item.priority)
    }

    private var priorityColor: Color {
        switch item.semanticState {
        case .privateActionRequired, .privateVIPRisk, .groupActionRequired:
            switch item.priority {
            case .p0: return .red
            case .p1: return .yellow
            case .p2: return .white.opacity(0.35)
            }
        case .groupMentionFYI, .groupDecisionOnly:
            return .blue.opacity(0.75)
        default:
            return .white.opacity(0.2)
        }
    }

    // MARK: - Hover Buttons

    private var hoverButtons: some View {
        HStack(spacing: 6) {
            if !item.replied {
                Button(action: {
                    withMotion(CompanionMotion.islandRowExpand()) {
                        showSnoozeMenu.toggle()
                        if showSnoozeMenu {
                            confirmUntrack = false
                            untrackError = nil
                        }
                    }
                }) {
                    // SF Symbol, not the ⏰ emoji — the emoji renders in
                    // full colour and fights the monochrome chrome.
                    Group {
                        if busyAction == .snooze {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "clock")
                                .islandButton()
                                .foregroundColor(showSnoozeMenu ? IslandInk.primary : IslandInk.tertiary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandIconButtonStyle())
                .disabled(isRowBusy)
                .help(busyAction == .snooze ? InboxRowBusy.snooze.help : "稍后提醒")
                .accessibilityLabel(busyAction == .snooze ? InboxRowBusy.snooze.help : "稍后提醒")
            }

            Button {
                runInboxAction(.dismiss, onDismiss)
            } label: {
                Group {
                    if busyAction == .dismiss {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "xmark")
                            .islandMicro()
                            .foregroundColor(IslandInk.tertiary)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandIconButtonStyle())
            .disabled(isRowBusy)
            .help(busyAction == .dismiss ? InboxRowBusy.dismiss.help : (item.actionRequired ? "标为已处理" : "隐藏这条更新"))
            .accessibilityLabel(busyAction == .dismiss ? InboxRowBusy.dismiss.help : (item.actionRequired ? "标为已处理" : "隐藏这条更新"))
        }
    }

    // MARK: - Helpers

    /// Named copy has to inspect the pasteboard write. The menu vanishes as
    /// soon as the click lands, so the receipt is the island toast — same
    /// contract as `WeChatLauncher.copyText`.
    private func copyInboxText(_ text: String) {
        let ok = CompanionClipboard.write(text)
        panelState.showToast(ok ? CompanionInteractionCopy.copied : CompanionInteractionCopy.copyFailed)
    }

    /// Context menus vanish on click, so a failed follow/VIP/ignore write has
    /// to land as a toast — the same receipt path as copy.
    private func applyFollowChange(_ work: () -> Bool) {
        guard !work() else { return }
        panelState.showToast(monitor.inboxActionError ?? CompanionInteractionCopy.followLevelFailed)
    }

    private func runInboxAction(_ action: InboxRowBusy, _ work: @escaping () -> Void) {
        guard !isRowBusy else { return }
        busyAction = action
        Task { @MainActor in
            defer { busyAction = nil }
            work()
        }
    }

    private func confirmUntrackNow() {
        guard !isUntracking else { return }
        isUntracking = true
        untrackError = nil
        Task { @MainActor in
            let ok = monitor.untrackInboxItem(item)
            isUntracking = false
            if ok {
                confirmUntrack = false
            } else {
                untrackError = CompanionInteractionCopy.untrackFailed
            }
        }
    }
    // NOTE: timestamps use the shared relativeTime(_:) in ViewHelpers.swift
    // ("5分前" style) so every surface formats recency the same way.
}

// MARK: - Priority Pulse Dot

/// Priority dot with an optional expanding pulse ring for p0 items —
/// draws the eye in peripheral vision without being obnoxious
/// (shared `CompanionMotion.pulse()` breathe, low opacity).
private struct PriorityPulseDot: View {
    let color: Color
    let isUrgent: Bool
    let level: InboxPriority
    @State private var pulseOn = false

    /// The island separates P0 / P1 / P2 by hue alone, which is precisely the
    /// cue 「不同颜色也能区分」 asks software to stop relying on. Under that
    /// switch the three levels take three silhouettes in the same 8 pt
    /// footprint, matching the vocabulary the status glyph already uses
    /// (`CompanionMaterial` disc / ring / diamond).
    private enum Silhouette { case disc, ring, diamond }

    private var silhouette: Silhouette {
        guard CompanionAccessibility.differentiateWithoutColor else { return .disc }
        switch level {
        case .p0: return .diamond
        case .p1: return .ring
        default: return .disc
        }
    }

    @ViewBuilder private var marker: some View {
        switch silhouette {
        case .ring:
            Circle()
                .strokeBorder(color, lineWidth: 2)
                .frame(width: 8, height: 8)
        case .diamond:
            Rectangle()
                .fill(color)
                .frame(width: 6.5, height: 6.5)
                .rotationEffect(.degrees(45))
        case .disc:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    /// Fixed 14×14 slot for every row, urgent or not.
    ///
    /// The ring used to animate its *frame* (8→14 pt) with a 1.4 s
    /// repeatForever. A frame change is a layout change: every pulse tick
    /// re-laid-out the row, re-fired the inbox measurement pipe and bent the
    /// window-frame spring — forever, on every urgent row, including while
    /// the expand/collapse animation was running. The ring now animates only
    /// scale + opacity inside a fixed box (compositor-only, zero layout), so
    /// the pulse can never move a pixel of layout again. The uniform slot
    /// also keeps urgent and quiet rows on the same leading alignment instead
    /// of the dot column breathing with the pulse.
    ///
    /// The breathe itself uses the house pulse (easeInOut, autoreverses),
    /// not a one-shot ease-out that restarts from the small ring every
    /// cycle. A restart is a jump; a reverse is a breath.
    var body: some View {
        ZStack {
            if isUrgent, !CompanionMotion.reduceMotion {
                Circle()
                    .stroke(color.opacity(pulseOn ? 0.35 : 0.0), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulseOn ? 1.0 : 0.57)
            }
            marker
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard isUrgent, !CompanionMotion.reduceMotion else { return }
            withMotion(CompanionMotion.pulse()) {
                pulseOn = true
            }
        }
    }
}

// MARK: - Snooze Popover Content

struct IslandSnoozeMenu: View {
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(CompanionProductCopy.snoozeChoices().enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Divider().background(IslandInk.divider)
                }
                Button {
                    onSelect(choice.until)
                } label: {
                    HStack {
                        Text(choice.label)
                            .islandRowTitle()
                            .foregroundStyle(IslandInk.primary)
                        Spacer(minLength: 12)
                        Text(choice.whenLabel)
                            .islandMeta()
                            .foregroundStyle(IslandInk.tertiary)
                    }
                    .padding(.horizontal, IslandMetrics.rowInset - 4)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandRowButtonStyle(cornerRadius: 7))
                .accessibilityLabel(choice.label)
                .accessibilityHint(choice.whenLabel)
                .accessibilityIdentifier("companion.snooze.\(choice.label)")
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("稍后提醒时间")
    }
}

private struct IslandUntrackConfirm: View {
    let chatName: String
    let isUntracking: Bool
    let error: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("取消关注「\(chatName)」？")
                .islandRowTitle()
                .foregroundStyle(IslandInk.primary)
            Text("同时清掉这个对话的承诺、待办、静音和稍后提醒设置，无法撤销。")
                .islandMeta()
                .foregroundStyle(IslandInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .islandMeta()
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.companionStatusReveal)
            }
            HStack {
                Spacer()
                Button("先不", action: onCancel)
                    .buttonStyle(IslandRowButtonStyle())
                    .foregroundStyle(IslandInk.secondary)
                    .companionBusyHold(isUntracking, "正在取消关注")
                Button(action: onConfirm) {
                    Text(isUntracking ? "正在取消关注…" : "取消关注并清空")
                }
                .buttonStyle(IslandRowButtonStyle())
                .foregroundStyle(.red)
                .disabled(isUntracking)
                .help(isUntracking ? "正在取消关注" : "")
                .accessibilityHint(isUntracking ? "正在取消关注" : "")
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("取消关注确认")
        .companionAnimation(CompanionMotion.ease(), value: error)
    }
}

struct SnoozePopoverContent: View {
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(CompanionProductCopy.snoozeChoices().enumerated()), id: \.element.id) { index, choice in
                if index > 0 { Divider().opacity(0.2) }
                snoozeButton(label: "\(choice.label)  \(choice.whenLabel)", date: choice.until, name: choice.label)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 220)
    }

    private func snoozeButton(label: String, date: Date, name: String) -> some View {
        Button(action: { onSelect(date) }) {
            Text(label)
                .islandButton()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandRowButtonStyle())
        .accessibilityLabel(name)
        .accessibilityHint(label)
    }
}
