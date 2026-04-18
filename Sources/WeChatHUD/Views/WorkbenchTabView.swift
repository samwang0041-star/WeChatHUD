import SwiftUI

/// 工作台 tab — bidirectional discussion items extracted from all
/// whitelisted conversations. Filters by kind + ownership + status,
/// grouped visually by chat so the user can see at a glance:
///
/// - "我要做" → todos the user owes
/// - "对方要做" → todos someone else owes the user
/// - "待决策" → things discussed but not decided
/// - "信息点" → facts worth remembering (prices, addresses, names)
/// - "时间地点" → specific meeting slots
/// - "待确认" → unanswered questions
///
/// Each row supports one-click done / dismiss / archive + "open chat"
/// to jump back into WeChat for context. The source message anchor
/// links each item back to the originating conversation window.
struct WorkbenchTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    /// Which ownership bucket is currently visible. "全部" shows
    /// everything; "我要做" and "对方要做" mirror the weekly-report
    /// slicing the user asked for.
    @State private var ownerFilter: OwnerFilter = .all
    /// Which item kind is currently visible. `nil` = all kinds.
    @State private var kindFilter: DiscussionItemKind? = nil
    /// Only pending items by default — done/dismissed tucked away
    /// behind a toggle so the active list stays uncluttered.
    @State private var showCompleted: Bool = false

    enum OwnerFilter: String, CaseIterable, Identifiable {
        case all, mine, theirs, shared
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:    return "全部"
            case .mine:   return "我要做"
            case .theirs: return "对方要做"
            case .shared: return "双方"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterBar
            Divider().background(Color.white.opacity(0.06))
            if filteredItems.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
    }

    // MARK: - Filtering

    private var filteredItems: [DiscussionItem] {
        monitor.discussionItems.filter { item in
            if !showCompleted && item.status != .pending { return false }
            if ownerFilter != .all {
                switch ownerFilter {
                case .mine where item.owner != .mine: return false
                case .theirs where item.owner != .theirs: return false
                case .shared where item.owner != .shared: return false
                default: break
                }
            }
            if let k = kindFilter, item.kind != k { return false }
            return true
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Owner row — who owes the item
            HStack(spacing: 4) {
                ForEach(OwnerFilter.allCases) { owner in
                    filterChip(
                        label: owner.label,
                        selected: ownerFilter == owner,
                        action: { ownerFilter = owner }
                    )
                }
                Spacer()
                Button(action: { showCompleted.toggle() }) {
                    Label(showCompleted ? "隐藏已完成" : "显示已完成",
                          systemImage: showCompleted ? "eye.slash" : "eye")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.55))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
            }
            // Kind row — what type of item. "所有" clears the filter.
            HStack(spacing: 4) {
                filterChip(
                    label: "所有类型",
                    selected: kindFilter == nil,
                    action: { kindFilter = nil }
                )
                ForEach(DiscussionItemKind.allCases, id: \.self) { kind in
                    filterChip(
                        label: kind.label,
                        icon: kind.iconName,
                        selected: kindFilter == kind,
                        action: { kindFilter = kind }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func filterChip(
        label: String,
        icon: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundColor(selected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredItems) { item in
                WorkbenchRowView(item: item)
                    .environmentObject(monitor)
                Divider().background(Color.white.opacity(0.04))
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.25))
            Text(emptyMessage)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Text("聊天中的待办 / 决策 / 信息点会自动归到这里")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var emptyMessage: String {
        if ownerFilter == .mine { return "没有我负责的事项" }
        if ownerFilter == .theirs { return "没有等对方处理的事项" }
        if kindFilter != nil { return "没有这类事项" }
        return "暂无提取到的事项"
    }
}

/// One row in the workbench list. Compact by default — tap toggles a
/// detail expand that shows the secondary description + anchor jump.
private struct WorkbenchRowView: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: DiscussionItem

    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.kind.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(kindColor)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.content)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(item.status == .done ? 0.4 : 0.9))
                            .strikethrough(item.status == .done)
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: expanded)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        ownerChip
                        Text(item.chatName)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                        if let due = item.dueAt {
                            Text("· " + relativeDue(due))
                                .font(.system(size: 9))
                                .foregroundColor(overdueColor(due))
                        }
                        Spacer(minLength: 0)
                    }
                    if expanded, let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.top, 2)
                    }
                }

                if hovered || expanded {
                    actionButtons
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { expanded.toggle() }
        }
    }

    private var ownerChip: some View {
        Text(item.owner.label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(ownerColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(ownerColor.opacity(0.15))
            .cornerRadius(3)
    }

    private var ownerColor: Color {
        switch item.owner {
        case .mine:   return .orange
        case .theirs: return .blue
        case .shared: return .gray
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .todo:      return .orange
        case .decision:  return .yellow
        case .info:      return .cyan
        case .timePlace: return .purple
        case .question:  return .pink
        }
    }

    private func overdueColor(_ due: Date) -> Color {
        Date() > due ? .red : .white.opacity(0.4)
    }

    private func relativeDue(_ due: Date) -> String {
        let now = Date()
        let seconds = due.timeIntervalSince(now)
        if seconds < 0 {
            let overdueHours = Int(-seconds / 3600)
            if overdueHours < 24 { return "已过期 \(overdueHours)h" }
            return "已过期 \(overdueHours / 24)d"
        }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h 内" }
        return "\(hours / 24)d 内"
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if item.status == .pending {
                Button(action: markDone) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.green.opacity(0.8))
                .help("标记完成")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.4))
                .help("不是待办")
            } else {
                Button(action: reopen) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.5))
                .help("恢复")
            }
            Button(action: openChat) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.5))
            .help("在微信中打开")
        }
        .padding(.top, 2)
    }

    private func markDone() {
        monitor.updateDiscussionItemStatus(id: item.id, status: .done)
    }
    private func dismiss() {
        monitor.updateDiscussionItemStatus(id: item.id, status: .dismissed)
    }
    private func reopen() {
        monitor.updateDiscussionItemStatus(id: item.id, status: .pending)
    }
    private func openChat() {
        WeChatLauncher.openChat(named: item.chatName)
    }
}
