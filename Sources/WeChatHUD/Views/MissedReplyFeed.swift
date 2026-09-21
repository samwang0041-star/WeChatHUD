import SwiftUI

/// Historical unreplied private messages and group @-mentions for a chosen
/// window. Lives on 「今天」 so it is the same job as 需要回复, just looking
/// backward instead of at the live queue.
struct MissedReplyFeed: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @Binding var window: MissedReplyFinder.Window
    @Binding var customStart: Date
    @Binding var customEnd: Date
    @Binding var query: String
    @State private var expandedID: String?

    private var visible: [MissedReplyFinder.Item] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.missedReplies.filter {
            text.isEmpty || [$0.chatName, $0.senderName, $0.preview].contains {
                $0.localizedCaseInsensitiveContains(text)
            }
        }
    }

    /// What the walk did not cover, if anything. Rendered once per state: the
    /// empty card folds it into its own explanation, a non-empty list gets the
    /// line above it.
    private var coverageCaveat: String? { monitor.missedReplyCoverage?.caveat }

    private var widerMissedWindow: MissedReplyFinder.Window? {
        switch window {
        case .today: return .last3Days
        case .last3Days: return .last7Days
        case .last7Days, .custom: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rangePills
            if window == .custom {
                HStack(spacing: 12) {
                    DatePicker("从", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("开始日期")
                    Text("到").workspaceMeta().foregroundStyle(.secondary)
                    DatePicker("到", selection: $customEnd, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("结束日期")
                }
                .controlSize(.small)
                .transition(.companionStatusReveal)
            }
            if !visible.isEmpty, let caveat = coverageCaveat {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(caveat)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            content
        }
        .onAppear(perform: reload)
        .companionAnimation(CompanionMotion.drawer(), value: window)
        .companionAnimation(CompanionMotion.ease(), value: monitor.missedReplyError)
        .onChange(of: window) { _, _ in reload() }
        .onChange(of: customStart) { _, _ in if window == .custom { reload() } }
        .onChange(of: customEnd) { _, _ in if window == .custom { reload() } }
    }

    private var rangePills: some View {
        HStack(spacing: 8) {
            ForEach(MissedReplyFinder.Window.allCases) { value in
                CompanionFilterPill(
                    title: value.label,
                    selected: window == value,
                    tint: CompanionPalette.accent
                ) { window = value }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if monitor.missedReplyLoading && monitor.missedReplies.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(CompanionInteractionCopy.readingMissedReplies)
                    .workspaceBody()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .companionSurface()
        } else if let error = monitor.missedReplyError {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "没读完",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Button("再试一次") { reload() }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .disabled(monitor.missedReplyLoading)
                    .help(monitor.missedReplyLoading ? "正在读取没回的消息" : "")
                    .accessibilityHint(monitor.missedReplyLoading ? "正在读取没回的消息" : "")
                    .accessibilityLabel(monitor.missedReplyLoading ? "正在读取没回的消息" : "再试一次读取没回的消息")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .companionSurface()
            .transition(.companionStatusReveal)
        } else if visible.isEmpty {
            // 「没有遗漏」 is a completeness claim; it may only be made when the
            // walk actually covered everything. A search that matched nothing is
            // a different fact and keeps its own explanation.
            let caveat = coverageCaveat
            VStack(spacing: 12) {
                ContentUnavailableView(
                    !query.isEmpty
                        ? "没有匹配的消息"
                        : (caveat == nil
                            ? CompanionInteractionCopy.missedRepliesAllClear
                            : CompanionInteractionCopy.missedRepliesPartial),
                    systemImage: !query.isEmpty
                        ? "magnifyingglass"
                        : (caveat == nil ? "checkmark.bubble" : "exclamationmark.bubble"),
                    description: Text(
                        !query.isEmpty
                            ? "试试联系人姓名或消息里的关键词。"
                            : (caveat ?? CompanionInteractionCopy.missedRepliesEmpty)
                    )
                )
                if !query.isEmpty {
                    Button("清除搜索") { query = "" }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("清除搜索")
                }
                else if let wider = widerMissedWindow {
                    Button(wider.label) {
                        withMotion(CompanionMotion.pageChange()) { window = wider }
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .accessibilityLabel("看\(wider.label)没回的消息")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .companionSurface()
        } else {
            LazyVStack(spacing: 12) {
                ForEach(visible) { item in
                    card(item, expanded: expandedID == item.id || (expandedID == nil && item.id == visible.first?.id))
                }
            }
        }
    }

    private func card(_ item: MissedReplyFinder.Item, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withMotion(CompanionMotion.rowExpand()) {
                    expandedID = expanded && expandedID == item.id ? "" : item.id
                }
            } label: {
                HStack(spacing: 10) {
                    CompanionAvatar(name: item.chatName, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.chatName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(item.timestamp, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if item.isAtMention { CompanionBadge(title: "@ 我") }
                    if item.repliedWithAckOnly {
                        // Same words the inbox uses for this exact case, so the
                        // two surfaces do not describe one fact two ways.
                        CompanionBadge(title: ReplyDebtReasonCode.unsubstantiveReply.label)
                    }
                    if item.unrepliedCount > 1 {
                        CompanionBadge(title: "\(item.unrepliedCount) 条")
                    }
                    if !expanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(CompanionPressStyle())

            Text(item.preview)
                .font(.system(size: expanded ? 16 : 14, weight: expanded ? .semibold : .regular))
                .lineSpacing(4)
                .textSelection(.enabled)
                .lineLimit(expanded ? 6 : 1)

            if expanded {
                HStack {
                    Button {
                        panelState.showChatDetail(
                            chatUsername: item.chatUsername,
                            chatName: item.chatName,
                            focus: item.transcriptFocus
                        )
                    } label: {
                        Label("理解上下文与回复", systemImage: "text.bubble")
                    }
                    .tint(CompanionPalette.jade)
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Text(item.senderName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .controlSize(.regular)
                .transition(.companionStatusReveal)
            }
        }
        .companionSurface()
        .companionAnimation(CompanionMotion.rowExpand(), value: expanded)
    }

    private func reload() {
        let bounds = window.bounds(customStart: customStart, customEnd: customEnd)
        monitor.refreshMissedReplies(start: bounds.start, end: bounds.end)
    }
}
