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
    let query: String
    @State private var expandedID: String?

    private var visible: [MissedReplyFinder.Item] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.missedReplies.filter {
            text.isEmpty || [$0.chatName, $0.senderName, $0.preview].contains {
                $0.localizedCaseInsensitiveContains(text)
            }
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
            }
            content
        }
        .onAppear(perform: reload)
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
            ContentUnavailableView(
                "没读完",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .companionSurface()
        } else if visible.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "没有没回的消息" : "没有匹配的消息",
                systemImage: query.isEmpty ? "checkmark.bubble" : "magnifyingglass",
                description: Text(
                    query.isEmpty
                    ? CompanionInteractionCopy.missedRepliesEmpty
                    : "试试联系人姓名或消息里的关键词。"
                )
            )
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
            .buttonStyle(.plain)

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
                    .buttonStyle(.borderedProminent)
                    .tint(CompanionPalette.jade)
                    Spacer()
                    Text(item.senderName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .controlSize(.regular)
            }
        }
        .companionSurface()
    }

    private func reload() {
        let bounds = window.bounds(customStart: customStart, customEnd: customEnd)
        monitor.refreshMissedReplies(start: bounds.start, end: bounds.end)
    }
}
