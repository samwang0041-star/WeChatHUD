import SwiftUI

/// Compact first-run conversation picker that stays inside the introduction.
struct FirstLaunchContactPicker: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var query = ""
    @State private var errorMessage: String?
    @State private var refreshID = 0

    private var tracked: Set<String> {
        _ = refreshID
        return Set(store.getWhitelist().map(\.id))
    }

    private var candidates: [SessionInfo] {
        _ = refreshID
        let sessions: [SessionInfo]
        if PreviewRuntime.isEnabled {
            sessions = [
                SessionInfo(username: "preview-colleague", isGroup: false, unreadCount: 1, lastTimestamp: 3),
                SessionInfo(username: "preview-xu", isGroup: false, unreadCount: 0, lastTimestamp: 2),
                SessionInfo(username: "preview-project", isGroup: true, unreadCount: 1, lastTimestamp: 1)
            ]
        } else {
            sessions = (try? monitor.reader.getSessions()) ?? []
        }
        let suggested = FirstLaunchGuide.suggestedConversations(from: sessions, excluding: [])
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
            if candidates.isEmpty {
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(candidates.prefix(8), id: \.username) { session in
                        candidateRow(session)
                    }
                }
            }
            Text("已选 \(candidates.filter { tracked.contains($0.username) }.count) 个对话")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func rowDetail(for session: SessionInfo, following: Bool) -> String {
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
        return "连接微信后，这里会出现最近的对话。也可以稍后再选。"
    }

    private func candidateRow(_ session: SessionInfo) -> some View {
        let following = tracked.contains(session.username)
        return Button {
            toggle(session)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(following ? CompanionPalette.jade : Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                    if session.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(following ? Color.white : CompanionPalette.jade)
                    } else {
                        Text(String(displayName(for: session).prefix(1)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(following ? Color.white : CompanionPalette.jade)
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(following ? CompanionPalette.jade : .secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(following ? CompanionPalette.selectedFill : CompanionPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(following ? CompanionPalette.jade.opacity(0.35) : CompanionPalette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "取消关注 \(displayName(for: session))" : "关注 \(displayName(for: session))")
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
}
