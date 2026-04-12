import SwiftUI

/// macOS System Settings–style layout: sidebar on the left with colored
/// rounded-square icon + label rows, content pane on the right with a hero
/// header (icon + title + description) followed by the tab body.
struct SettingsView: View {
    @State private var selectedTab: Tab = .whitelist

    enum Tab: Hashable, CaseIterable {
        case whitelist
        case ignored
        case ai
        case sync
        case notification

        var label: String {
            switch self {
            case .whitelist:    return "白名单"
            case .ignored:      return "忽略列表"
            case .ai:           return "AI 配置"
            case .sync:         return "数据同步"
            case .notification: return "通知"
            }
        }

        var icon: String {
            switch self {
            case .whitelist:    return "person.crop.circle.badge.checkmark"
            case .ignored:      return "person.crop.circle.badge.xmark"
            case .ai:           return "cpu"
            case .sync:         return "arrow.triangle.2.circlepath"
            case .notification: return "bell.badge.fill"
            }
        }

        var tint: Color {
            switch self {
            case .whitelist:    return .blue
            case .ignored:      return .orange
            case .ai:           return .purple
            case .sync:         return .teal
            case .notification: return .red
            }
        }

        var subtitle: String {
            switch self {
            case .whitelist:    return "配置白名单和 VIP：白名单负责跟踪分析，VIP 负责强提醒。"
            case .ignored:      return "管理被你直接忽略、不再计入未读和 VIP 提醒的人。"
            case .ai:           return "配置本地或远程的 OpenAI 兼容 AI 服务。"
            case .sync:         return "管理微信数据源、解密缓存策略与同步节奏。"
            case .notification: return "决定哪些消息会让胶囊自动展开并弹出预览。"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)

            Divider()
                .background(Color.white.opacity(0.08))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Title header
            HStack {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Tab rows
            VStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    sidebarRow(tab)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .background(Color.white.opacity(0.025))
    }

    private func sidebarRow(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tab.tint)
                        .frame(width: 20, height: 20)
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(tab.label)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroHeader

                // The tab body lives directly below the hero — each tab view
                // renders its own controls. We wrap AI / sync / notification in
                // a grouped card to get the native "rounded section" look.
                // Whitelist has its own full list UI so it opts out of the card.
                switch selectedTab {
                case .whitelist:
                    WhitelistSettingsView()
                case .ignored:
                    SettingsCard { IgnoredSendersSettingsView() }
                case .ai:
                    SettingsCard { AISettingsView() }
                case .sync:
                    SettingsCard { SyncSettingsView() }
                case .notification:
                    SettingsCard { NotificationSettingsBody() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heroHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedTab.tint)
                    .frame(width: 44, height: 44)
                Image(systemName: selectedTab.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTab.label)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Text(selectedTab.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Grouped card wrapper

/// Wraps a settings subview in the native "rounded grouped section" look:
/// dark translucent fill, 10 pt corner radius, hairline separator border.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            )
    }
}

// MARK: - Notification settings body

/// Inline subview — currently placeholder toggles, same as before but
/// lifted out of SettingsView so the new layout can reuse it cleanly.
struct NotificationSettingsBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("@提到我时弹出通知", isOn: .constant(true))
            Toggle("VIP 消息弹出通知", isOn: .constant(true))
            Toggle("白名单消息也弹出", isOn: .constant(false))
        }
        .font(.system(size: 12))
        .foregroundColor(.white)
        .toggleStyle(.switch)
    }
}
