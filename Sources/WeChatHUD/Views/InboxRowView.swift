import SwiftUI
import AppKit

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .background(hovered || showSnoozeMenu ? IslandInk.hover : Color.clear)
            .overlay(alignment: .topTrailing) {
                // Overlay, not in-flow: hover actions slide in over the
                // timestamp/chevron they replace instead of pushing the
                // whole row left — in-flow placement re-laid-out the row
                // on every hover and read as a flicker.
                if hovered || showSnoozeMenu {
                    hoverButtons
                        .padding(.leading, 8)
                        .background(CompanionPalette.island, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.top, 4)
                        .padding(.trailing, IslandMetrics.rowInset)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withMotion(CompanionMotion.rowExpand()) {
                    if panelState.expandedInboxItemID == item.id {
                        panelState.expandedInboxItemID = nil
                    } else {
                        panelState.expandedInboxItemID = item.id
                    }
                }
            }
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
                    onSnooze?(date)
                }
                .padding(.horizontal, IslandMetrics.rowInset)
                .padding(.bottom, IslandMetrics.rowPadding)
            }

            if panelState.expandedInboxItemID == item.id {
                ActionPanelView(item: item)
                    .transition(.islandDetailReveal)
            }
        }
        .onHover { inside in
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
        .onChange(of: showSnoozeMenu) { _, open in
            panelState.setSnoozeMenuExpanded(open)
        }
        .onDisappear {
            if showSnoozeMenu {
                showSnoozeMenu = false
                panelState.setSnoozeMenuExpanded(false)
            }
        }
        .companionAnimation(CompanionMotion.hover(), value: hovered)
        .companionAnimation(CompanionMotion.rowExpand(), value: showSnoozeMenu)
        .companionAnimation(CompanionMotion.rowExpand(), value: panelState.expandedInboxItemID)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(item.actionRequired ? "标为已处理" : "隐藏这条更新") {
            onDismiss()
        }
        Menu("稍后提醒") {
            ForEach(CompanionProductCopy.snoozeChoices()) { choice in
                Button("\(choice.label)  \(choice.whenLabel)") { onSnooze?(choice.until) }
            }
        }
        Button("静音此对话") {
            onSilence?()
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.preview, forType: .string)
        }
        if let summary = item.aiSummary, !summary.isEmpty {
            Button("复制 AI 摘要") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            }
        }

        Divider()

        if item.isWhitelisted {
            if item.isVIP {
                Button("降为普通关注") {
                    monitor.setInboxItemVIP(item, isVIP: false)
                }
            } else {
                Button("设为 VIP") {
                    monitor.setInboxItemVIP(item, isVIP: true)
                }
            }
            Button("取消关注此对话", role: .destructive) {
                monitor.untrackInboxItem(item)
            }
        } else {
            Button(item.isGroup ? "关注此群聊" : "关注此联系人") {
                monitor.setInboxItemVIP(item, isVIP: !item.isGroup)
            }
        }

        if item.isGroup, !item.senderName.isEmpty {
            Divider()
            Button("忽略 \(item.senderName) 的消息") {
                monitor.ignoreInboxItemSender(item)
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
        return monitor.recentNotifications.first {
            $0.chatUsername == item.chatUsername && $0.canExplainContext
        }
    }

    /// Rendered "他想你: ..." inline briefing, or a compact "分析中"
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
                    Text("分析中…")
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
        PriorityPulseDot(color: priorityColor, isUrgent: item.priority == .p0)
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
                    showSnoozeMenu.toggle()
                }) {
                    // SF Symbol, not the ⏰ emoji — the emoji renders in
                    // full colour and fights the monochrome chrome.
                    Image(systemName: "clock")
                        .islandButton()
                        .foregroundColor(showSnoozeMenu ? IslandInk.primary : IslandInk.tertiary)
                }
                .buttonStyle(.plain)
                .help("稍后提醒")
                .accessibilityLabel("稍后提醒")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .islandMicro()
                    .foregroundColor(IslandInk.tertiary)
            }
            .buttonStyle(.plain)
            .help(item.actionRequired ? "标为已处理" : "隐藏这条更新")
        }
    }

    // MARK: - Helpers
    // NOTE: timestamps use the shared relativeTime(_:) in ViewHelpers.swift
    // ("5分前" style) so every surface formats recency the same way.
}

// MARK: - Priority Pulse Dot

/// Priority dot with an optional expanding pulse ring for p0 items —
/// draws the eye in peripheral vision without being obnoxious
/// (1.4s period, low opacity).
private struct PriorityPulseDot: View {
    let color: Color
    let isUrgent: Bool
    @State private var pulseOn = false

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
    var body: some View {
        ZStack {
            if isUrgent, !CompanionMotion.reduceMotion {
                Circle()
                    .stroke(color.opacity(pulseOn ? 0.35 : 0.0), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulseOn ? 1.0 : 0.57)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard isUrgent, !CompanionMotion.reduceMotion else { return }
            withMotion(CompanionMotion.easeOut(1.4).map { $0.repeatForever(autoreverses: false) }) {
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
                    .padding(.horizontal, IslandMetrics.rowInset)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityHint(choice.whenLabel)
                .accessibilityIdentifier("companion.snooze.\(choice.label)")
            }
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("稍后提醒时间")
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
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint(label)
    }
}
