import SwiftUI

/// macOS System Settings–style layout: sidebar on the left with colored
/// rounded-square icon + label rows, content pane on the right with a hero
/// header (icon + title + description) followed by the tab body.
struct SettingsView: View {
    @EnvironmentObject var panelState: PanelState
    @State private var selectedTab: Tab = .contacts

    enum Tab: Hashable, CaseIterable {
        // Settings
        case contacts
        case aiButler
        case autopilot
        case system
        // Dashboards
        case insight
        case dailyReport
        case commitments
        case autopilotDashboard

        var label: String {
            switch self {
            case .contacts:           return "联系人"
            case .aiButler:           return "AI 管家"
            case .autopilot:          return "自动托管"
            case .system:             return "系统"
            case .insight:            return "洞察"
            case .dailyReport:        return "日报"
            case .commitments:        return "承诺"
            case .autopilotDashboard: return "托管日志"
            }
        }

        var icon: String {
            switch self {
            case .contacts:           return "person.2.fill"
            case .aiButler:           return "brain.head.profile"
            case .autopilot:          return "arrow.triangle.2.circlepath"
            case .system:             return "gearshape.2.fill"
            case .insight:            return "waveform.badge.magnifyingglass"
            case .dailyReport:        return "doc.text.fill"
            case .commitments:        return "checkmark.circle.fill"
            case .autopilotDashboard: return "list.bullet.rectangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .contacts:           return .blue
            case .aiButler:           return .purple
            case .autopilot:          return .cyan
            case .system:             return .green
            case .insight:            return .orange
            case .dailyReport:        return .mint
            case .commitments:        return .pink
            case .autopilotDashboard: return .cyan
            }
        }

        var subtitle: String {
            switch self {
            case .contacts:           return "管理联系人级别、角色配置和忽略规则。"
            case .aiButler:           return "AI 服务连接、管家行为和通知过滤。"
            case .autopilot:          return "自动回复的安全护栏和行为设置。"
            case .system:             return "同步间隔、数据管理和系统信息。"
            case .insight:            return "聊天态势分析、情绪洞察和暗信号。"
            case .dailyReport:        return "查看日报摘要。自定义时间范围的复盘（原周报）已迁移到「复盘」tab。"
            case .commitments:        return "追踪你和对方的承诺和待办。"
            case .autopilotDashboard: return "自动回复活动日志和会话统计。"
            }
        }

        /// Whether this tab is a dashboard (read-only) vs settings (configurable)
        var isDashboard: Bool {
            switch self {
            case .insight, .dailyReport, .commitments, .autopilotDashboard: return true
            default: return false
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
        .onAppear { applyPendingTab(panelState.pendingSettingsTab) }
        .onReceive(panelState.$pendingSettingsTab) { applyPendingTab($0) }
    }

    /// Centralized pending-tab router so both onAppear and subsequent
    /// `pendingSettingsTab` updates end up in the same switch. Each
    /// matched case clears the flag so it only fires once per publish.
    private func applyPendingTab(_ raw: String?) {
        guard let raw = raw else { return }
        switch raw {
        case "insight":
            selectedTab = .insight
        case "autopilot":
            selectedTab = .autopilot
        default:
            return
        }
        panelState.pendingSettingsTab = nil
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
                // Settings section
                ForEach(Tab.allCases.filter { !$0.isDashboard }, id: \.self) { tab in
                    sidebarRow(tab)
                }

                Divider()
                    .padding(.vertical, 6)

                Text("面板")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                // Dashboard section
                ForEach(Tab.allCases.filter { $0.isDashboard }, id: \.self) { tab in
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

    @ViewBuilder
    private var content: some View {
        // Insight uses HSplitView and needs full space — no ScrollView or padding.
        // Contacts uses its own List which needs full height — no ScrollView.
        // Other tabs are form-based and need ScrollView.
        if selectedTab == .insight {
            ChatInsightView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedTab == .contacts {
            VStack(alignment: .leading, spacing: 16) {
                heroHeader
                ContactsSettingsView()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader

                    switch selectedTab {
                    case .contacts, .insight:
                        EmptyView() // handled above
                    case .aiButler:
                        AISettingsView()
                    case .autopilot:
                        AutopilotSettingsView()
                    case .system:
                        SyncSettingsView()
                    case .dailyReport:
                        DailyReportTabView()
                    case .commitments:
                        CommitmentTabView()
                    case .autopilotDashboard:
                        AutopilotTabView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

