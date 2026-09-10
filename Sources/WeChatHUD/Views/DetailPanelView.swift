import SwiftUI

/// Detail panel — routes on `panelState.detailKind`:
/// - `.conversation`: the analysis workbench for a specific chat.
/// - `.autopilot`: the full autopilot control surface (same content the
///   old tab used to render, now living behind the compact-bar indicator).
/// - `nil`: the standalone Settings window (the gear fallback).
struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Inline notification bar for new urgent messages while in detail
                if panelState.currentState == .detail,
                   let top = monitor.inboxItems.first,
                   top.priority != .p2,
                   top.chatUsername != panelState.selectedChatUsername {
                    detailNotificationBar(top)
                }

                // Main content
                switch panelState.detailKind {
                case .conversation(let chatUsername):
                    if let chatName = panelState.selectedChatName {
                        ConversationDetailView(
                            chatUsername: chatUsername,
                            chatName: chatName
                        )
                        .id(chatUsername)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Chat name missing — fall back to empty pane
                        // instead of an opaque crash. Shouldn't happen
                        // in practice (callers always set both).
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .autopilot:
                    AutopilotDetailPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .none:
                    SettingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Explicit close — back to compact pill.
            Button(action: {
                panelState.clearDetail()
                panelState.collapse()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    private func detailNotificationBar(_ item: InboxItem) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(item.priority == .p0 ? Color.red : Color.yellow)
                .frame(width: 6, height: 6)
            Text(item.aiSummary ?? item.preview)
                .islandMeta()
                .foregroundColor(.primary)
                .lineLimit(1)
            if item.isOverdue {
                Text("超时\(item.overdueMinutes)分")
                    .islandMicro()
                    .foregroundColor(.red)
            }
            Spacer()
            Button("[查看]") {
                // Switch to .extended directly — the old "collapse
                // then mouseEntered 0.3s later" dance produced a
                // visible shrink-then-grow flicker.
                panelState.goExtended()
            }
            .islandMicro()
            .buttonStyle(.plain)
            .foregroundColor(CompanionPalette.islandMint)
            .accessibilityLabel("查看这条消息")
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
    }
}

/// Host for the autopilot full-view inside the detail panel. Renders
/// a header consistent with `ConversationDetailView` (back chevron +
/// title) above the existing `AutopilotTabView` content so the two
/// detail kinds feel like siblings.
struct AutopilotDetailPane: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()
                .background(Color.secondary.opacity(0.2))

            ScrollView {
                AutopilotTabView()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: {
                panelState.clearDetail()
                panelState.currentState = .extended
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: monitor.autopilotActive ? "bolt.fill" : "bolt")
                .font(.system(size: 11))
                .foregroundColor(monitor.autopilotActive ? .green : .secondary)

            Text("自动回复")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            if monitor.autopilotActive {
                Text(statusLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var statusLabel: String {
        if monitor.autopilotManuallyPaused { return "· 已手动暂停" }
        if monitor.autopilotPaused { return "· 微信前台 已暂停" }
        return "· 运行中"
    }
}
