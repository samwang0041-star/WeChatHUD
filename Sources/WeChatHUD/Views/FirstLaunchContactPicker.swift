import SwiftUI

/// Compact first-run conversation picker that stays inside the introduction.
struct FirstLaunchContactPicker: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var query = ""
    @State private var errorMessage: String?
    @State private var refreshID = 0
    @State private var busyUsername: String?

    @State private var sessions: [SessionInfo] = []
    @State private var isLoadingSessions = false
    @State private var sessionLoadError: String?

    private var isWriting: Bool { busyUsername != nil }

    private var followListUnreadable: Bool {
        _ = refreshID
        if case .unreadable = store.whitelistAllRead() { return true }
        return false
    }

    private var tracked: Set<String> {
        _ = refreshID
        if case .value(let entries) = store.whitelistAllRead() {
            return Set(entries.map(\.id))
        }
        return []
    }

    private var candidates: [SessionInfo] {
        _ = refreshID
        let source = PreviewRuntime.isEnabled ? previewSessions() : sessions
        let suggested = FirstLaunchGuide.suggestedConversations(from: source, excluding: [])
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return suggested }
        return suggested.filter { session in
            displayName(for: session).localizedCaseInsensitiveContains(text)
                || session.username.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索联系人或群聊", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索联系人或群聊")
            if isLoadingSessions && sessions.isEmpty && query.isEmpty {
                ProgressView("正在读取最近的对话…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.companionStatusReveal)
            } else if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(emptyHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if sessionLoadError != nil {
                        Button {
                            Task { await loadSessions() }
                        } label: {
                            Text(isLoadingSessions ? "正在读取…" : "再试一次")
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .disabled(isLoadingSessions)
                        .help(isLoadingSessions ? "正在读取最近的对话" : "")
                        .accessibilityLabel(isLoadingSessions ? "正在读取最近的对话" : "再试一次读取最近的对话")
                        .accessibilityHint(isLoadingSessions ? "正在读取最近的对话" : "")
                    } else if !query.isEmpty {
                        Button("清除搜索") { query = "" }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("清除搜索")
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(candidates.prefix(8), id: \.username) { session in
                        candidateRow(session)
                    }
                    .disabled(followListUnreadable)
                }
            }
            if followListUnreadable {
                Text("暂时读不到关注名单，已选数量先不要采信。")
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                Text("已选 \(candidates.filter { tracked.contains($0.username) }.count) 个对话")
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            if let sessionLoadError, !sessions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sessionLoadError)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button {
                        Task { await loadSessions() }
                    } label: {
                        Text(isLoadingSessions ? "正在读取…" : "再试一次")
                    }
                    .controlSize(.small)
                    .disabled(isLoadingSessions)
                    .help(isLoadingSessions ? "正在读取最近的对话" : "")
                    .accessibilityHint(isLoadingSessions ? "正在读取最近的对话" : "")
                }
                .transition(.companionStatusReveal)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .transition(.companionStatusReveal)
            }
        }
        .task { await loadSessions() }
        .companionAnimation(CompanionMotion.ease(), value: errorMessage)
        .companionAnimation(CompanionMotion.ease(), value: busyUsername)
        .companionAnimation(CompanionMotion.ease(), value: sessionLoadError)
        .companionAnimation(CompanionMotion.ease(), value: isLoadingSessions)
    }

    private func rowDetail(for session: SessionInfo, following: Bool) -> String {
        if busyUsername == session.username { return "正在保存关注…" }
        if following { return "已关注，之后还能改" }
        if PreviewRuntime.isEnabled {
            if session.username == "preview-xu" { return "日常工作沟通" }
            if session.isGroup { return "6 位成员 · 产品讨论与进展" }
            return "产品合作、需求沟通"
        }
        return session.isGroup ? "群聊" : "联系人"
    }

    private var emptyHint: String {
        if !query.isEmpty { return "没有匹配的对话。换个名字试试。" }
        if PreviewRuntime.isEnabled { return "演示里可以用下面的示例对话，或稍后再选。" }
        if let sessionLoadError { return sessionLoadError }
        return "连接微信后，这里会出现最近的对话。也可以稍后再选。"
    }

    private func candidateRow(_ session: SessionInfo) -> some View {
        let following = tracked.contains(session.username)
        return Button {
            commit(session)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(following ? CompanionPalette.jade : Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                    if session.isGroup {
                        Image(systemName: "person.2.fill")
                            .companionFont(size: 13, weight: .semibold)
                            .foregroundStyle(following ? Color.white : CompanionPalette.jadeInk)
                    } else {
                        Text(String(displayName(for: session).prefix(1)))
                            .companionFont(size: 14, weight: .semibold)
                            .foregroundStyle(following ? Color.white : CompanionPalette.jadeInk)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: session))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(rowDetail(for: session, following: following))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: following ? "checkmark.square.fill" : "square")
                    .companionFont(size: WorkspaceType.title, weight: .medium)
                    .foregroundStyle(following ? CompanionPalette.jadeInk : .secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(following ? CompanionPalette.selectedFill : CompanionPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(following ? CompanionPalette.jade.opacity(0.35) : CompanionPalette.border, lineWidth: CompanionAccessibility.cardEdgeWidth)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CompanionPressStyle())
        .disabled(isWriting)
        .help(isWriting ? "正在保存关注范围" : "")
        .accessibilityHint(isWriting ? "正在保存关注范围" : "")
        .accessibilityLabel(busyUsername == session.username
                            ? "正在保存关注"
                            : (following ? "取消关注 \(displayName(for: session))" : "关注 \(displayName(for: session))"))
    }

    private func displayName(for session: SessionInfo) -> String {
        if PreviewRuntime.isEnabled {
            switch session.username {
            case "preview-project": return "项目协作群"
            case "preview-xu": return "许宁"
            default: return "林晓 · 产品同事"
            }
        }
        let name = monitor.reader.displayName(for: session.username)
        return name.isEmpty ? session.username : name
    }

    private func commit(_ session: SessionInfo) {
        guard !followListUnreadable else {
            errorMessage = CompanionInteractionCopy.followListUnreadableEdit
            return
        }
        guard busyUsername == nil else { return }
        busyUsername = session.username
        Task { @MainActor in
            defer { busyUsername = nil }
            toggle(session)
        }
    }

    private func toggle(_ session: SessionInfo) {
        do {
            if tracked.contains(session.username) {
                try store.removeFromWhitelist(username: session.username)
            } else {
                try store.addToWhitelist(
                    username: session.username,
                    displayName: displayName(for: session),
                    isGroup: session.isGroup,
                    category: .other
                )
            }
            errorMessage = nil
            refreshID += 1
        } catch {
            errorMessage = "关注范围没有保存成功，请重试。"
        }
    }

    private func previewSessions() -> [SessionInfo] {
        [
            SessionInfo(username: "preview-colleague", isGroup: false, unreadCount: 1, lastTimestamp: 3),
            SessionInfo(username: "preview-xu", isGroup: false, unreadCount: 0, lastTimestamp: 2),
            SessionInfo(username: "preview-project", isGroup: true, unreadCount: 1, lastTimestamp: 1)
        ]
    }

    @MainActor
    private func loadSessions() async {
        if PreviewRuntime.isEnabled {
            sessions = previewSessions()
            sessionLoadError = nil
            return
        }
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        let readerActor = WeChatReaderActor(monitor.reader)
        do {
            sessions = try await readerActor.sessions()
            sessionLoadError = nil
        } catch {
            sessionLoadError = "最近的对话没读到。请确认微信已经打开，再试一次。"
        }
    }
}
