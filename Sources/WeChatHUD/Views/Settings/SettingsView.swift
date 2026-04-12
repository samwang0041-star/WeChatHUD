import SwiftUI

/// macOS System Settings–style layout: sidebar on the left with colored
/// rounded-square icon + label rows, content pane on the right with a hero
/// header (icon + title + description) followed by the tab body.
struct SettingsView: View {
    @State private var selectedTab: Tab = .contacts

    enum Tab: Hashable, CaseIterable {
        case contacts
        case aiEngine
        case autopilot
        case roleConfig
        case notification
        case data
        case sync
        case ignored

        var label: String {
            switch self {
            case .contacts:     return "联系人"
            case .aiEngine:     return "AI 引擎"
            case .autopilot:    return "自动托管"
            case .roleConfig:   return "角色配置"
            case .notification: return "通知"
            case .data:         return "数据"
            case .sync:         return "同步"
            case .ignored:      return "忽略列表"
            }
        }

        var icon: String {
            switch self {
            case .contacts:     return "person.2.fill"
            case .aiEngine:     return "cpu"
            case .autopilot:    return "robot"
            case .roleConfig:   return "slider.horizontal.3"
            case .notification: return "bell.badge.fill"
            case .data:         return "tray.full.fill"
            case .sync:         return "arrow.triangle.2.circlepath"
            case .ignored:      return "person.crop.circle.badge.xmark"
            }
        }

        var tint: Color {
            switch self {
            case .contacts:     return .blue
            case .aiEngine:     return .purple
            case .autopilot:    return .cyan
            case .roleConfig:   return .indigo
            case .notification: return .red
            case .data:         return .green
            case .sync:         return .teal
            case .ignored:      return .orange
            }
        }

        var subtitle: String {
            switch self {
            case .contacts:     return "管理四级联系人：VIP 全域追踪、白名单按需分析、灰名单低优先级、陌生人忽略。"
            case .aiEngine:     return "配置本地 AI 模型端点、分类器参数、审计日志与准确度监控。"
            case .autopilot:    return "配置自动回复托管：信心阈值、频率限制、VIP 忙碌通知模板。"
            case .roleConfig:   return "为每种身份角色设定回复窗口、通知级别、分类严格度与回复语气。"
            case .notification: return "决定哪些消息弹出通知、通知时长与勿扰时段。"
            case .data:         return "查看撤回消息记录、你的承诺追踪、待决事项管理。"
            case .sync:         return "管理微信数据源、解密缓存策略与同步节奏。"
            case .ignored:      return "管理被你直接忽略、不再计入未读和 VIP 提醒的人。"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)

            Divider()

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
                    .foregroundColor(.primary)
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
        .background(Color(nsColor: .controlBackgroundColor))
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
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
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
                case .contacts:
                    ContactsSettingsView()
                case .aiEngine:
                    SettingsCard { AISettingsView() }
                case .autopilot:
                    SettingsCard { AutopilotSettingsView() }
                case .roleConfig:
                    RoleConfigSettingsView()
                case .notification:
                    SettingsCard { NotificationSettingsBody() }
                case .data:
                    DataSettingsView()
                case .sync:
                    SettingsCard { SyncSettingsView() }
                case .ignored:
                    SettingsCard { IgnoredSendersSettingsView() }
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
                    .foregroundColor(.primary)
                Text(selectedTab.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Grouped card wrapper

/// Wraps a settings subview in the native "rounded grouped section" look:
/// system control background fill, 10 pt corner radius, subtle border.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - Notification settings body

/// Notification settings with persistent toggles.
struct NotificationSettingsBody: View {
    @EnvironmentObject private var store: HUDStore

    @State private var atMention = true
    @State private var vipMessage = true
    @State private var whitelistMessage = false
    @State private var durationSeconds = 3
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("@提到我时弹出通知", isOn: $atMention)
                .onChange(of: atMention) { save() }
            Toggle("VIP 消息弹出通知", isOn: $vipMessage)
                .onChange(of: vipMessage) { save() }
            Toggle("白名单消息也弹出", isOn: $whitelistMessage)
                .onChange(of: whitelistMessage) { save() }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("通知停留时长")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $durationSeconds) {
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("8 秒").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .onChange(of: durationSeconds) { save() }
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.primary)
        .toggleStyle(.switch)
        .onAppear {
            if !didLoad {
                if let cfg = store.getSettingJSON("notification", as: NotificationConfig.self) {
                    atMention = cfg.atMention
                    vipMessage = cfg.important
                    whitelistMessage = cfg.allWhitelist
                    durationSeconds = cfg.durationSeconds
                }
                didLoad = true
            }
        }
    }

    private func save() {
        let cfg = NotificationConfig(
            atMention: atMention,
            important: vipMessage,
            allWhitelist: whitelistMessage,
            durationSeconds: durationSeconds
        )
        try? store.setSettingJSON("notification", value: cfg)
    }
}
