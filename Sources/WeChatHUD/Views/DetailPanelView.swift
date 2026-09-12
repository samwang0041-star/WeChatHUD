import SwiftUI

/// Detail panel — routes on `panelState.detailKind`:
/// - `.conversation`: the analysis workbench for a specific chat. When the
///   chat name never reached `selectedChatName`, the pane falls back to
///   `MissingChatPane` — a named dead end with a way back to the inbox, not
///   the blank `Color.clear` pane this used to be.
/// - `.autopilot`: the in-island 「待确认回复」 workspace, opened from the
///   extended header's autopilot popover (「浮窗内查看」).
/// - `nil`: the standalone Settings window (the gear fallback).
struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    /// Identity of the inline notice the user closed. View state owned by this
    /// view (never persisted); injectable so a test can watch the 关闭 receipt.
    @StateObject private var noticeState: DetailNoticeState

    @MainActor
    init(noticeState: DetailNoticeState? = nil) {
        _noticeState = StateObject(wrappedValue: noticeState ?? DetailNoticeState())
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Inline notification bar for new urgent messages while in
                // detail. Its 关闭 button writes noticeState only, so hiding the
                // bar never touches the message's inbox status.
                if let top = inlineNoticeItem {
                    DetailNoticeBar(item: top) { noticeState.close(Self.noticeKey(top)) }
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
                        // Chat name missing — name the problem and offer the
                        // exit instead of an anonymous blank pane.
                        MissingChatPane()
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

    /// The urgent message the inline notice is about, or nil when the notice is
    /// hidden: only in .detail, only for a non-P2 message from another chat, and
    /// never once the user has closed that message's notice.
    private var inlineNoticeItem: InboxItem? {
        Self.noticeItem(
            top: monitor.inboxItems.first,
            selectedChatUsername: panelState.selectedChatUsername,
            isDetail: panelState.currentState == .detail,
            closedKey: noticeState.closedKey
        )
    }

    /// Visibility rule for the inline notice, kept as a pure function so the
    /// suppression behaviour can be asserted without hosting SwiftUI: only the
    /// top item is ever noticed, and closing one notice hides that message
    /// alone.
    static func noticeItem(
        top: InboxItem?,
        selectedChatUsername: String?,
        isDetail: Bool,
        closedKey: String?
    ) -> InboxItem? {
        guard isDetail,
              let top,
              top.priority != .p2,
              top.chatUsername != selectedChatUsername,
              closedKey != noticeKey(top)
        else { return nil }
        return top
    }

    /// Notice identity is the message, so closing one notice does not silence
    /// the next message from the same chat.
    static func noticeKey(_ item: InboxItem) -> String {
        item.contextNotification?.messageID ?? item.id
    }
}

/// The inline notice at the top of the detail panel: a new urgent message from
/// another chat, plus the two things a user can do about it (查看 / 关闭).
/// Extracted from DetailPanelView so its click contract can be hosted on its
/// own — 关闭 is a real button, not a variant of the 查看 action.
struct DetailNoticeBar: View {
    @EnvironmentObject var panelState: PanelState
    let item: InboxItem
    let onClose: () -> Void

    var body: some View {
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
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭这条提醒")
            .help("关掉这条提醒；消息仍在收件箱里")
        }
        .padding(.horizontal, IslandMetrics.sectionInset)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
    }
}

/// Transient state for the detail panel's inline notice: which message the user
/// closed. It lives only as long as the detail view, so the next detail visit
/// starts with the notice visible again and nothing is written to disk.
@MainActor
final class DetailNoticeState: ObservableObject {
    @Published private(set) var closedKey: String?

    func close(_ key: String) { closedKey = key }

    func shows(_ key: String) -> Bool { closedKey != key }
}

/// Copy for the detail panel's empty state, kept as a value so the words the
/// user is supposed to read can be asserted (rendered SwiftUI text cannot be
/// read back).
enum MissingChatPaneCopy {
    static let title = "会话信息缺失"
    static let detail = "这条对话的名字没能读出来。返回收件箱再打开一次即可。"
    static let action = "返回收件箱"
}

/// Routing for the detail panel's dead ends. Kept out of the views so the route
/// can be driven against a real PanelState without hosting SwiftUI.
@MainActor
enum DetailPanelRouting {
    /// The empty state's only exit. The pane this replaced (Color.clear) had
    /// none, which is what made the blank panel a dead end.
    static func returnToInbox(_ panelState: PanelState) {
        panelState.clearDetail()
        panelState.goExtended()
    }
}

/// Shown when a .conversation detail is routed without its chat name.
struct MissingChatPane: View {
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
            Text(MissingChatPaneCopy.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text(MissingChatPaneCopy.detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(MissingChatPaneCopy.action) {
                DetailPanelRouting.returnToInbox(panelState)
            }
            .buttonStyle(.plain)
            .foregroundColor(CompanionPalette.islandMint)
            .accessibilityLabel(MissingChatPaneCopy.action)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Host for the autopilot full-view inside the detail panel. Renders
/// a header consistent with ConversationDetailView (back chevron +
/// title) above ApprovalWorkspaceView, so 「浮窗内查看」 in the extended
/// header's autopilot popover reviews 待确认回复 inside the island
/// instead of opening the separate Settings window.
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

            ApprovalWorkspaceView(showsSessionToggle: false)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            Button(action: { monitor.toggleAutopilot() }) {
                HStack(spacing: 4) {
                    Image(systemName: monitor.autopilotActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(monitor.autopilotActive ? "停止" : "开始整理")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(monitor.autopilotActive ? .red : .green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((monitor.autopilotActive ? Color.red : Color.green).opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(monitor.autopilotActive ? "停止整理回复" : "开始整理回复")
            .accessibilityHint(monitor.autopilotActive ? "停止当前自动整理" : "开始整理该回的消息；发不发仍由自动回复设置决定")
        }
    }

    private var statusLabel: String {
        if monitor.autopilotManuallyPaused { return "· 已手动暂停" }
        if monitor.autopilotPaused { return "· 微信前台 已暂停" }
        return "· 运行中"
    }
}
