import SwiftUI

/// One native workspace: daily work first, configuration in its own sidebar section.
struct SettingsView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore
    @State private var selectedTab: Tab = .today
    @State private var previewA11yNonce = 0
    @State private var hideCaptureChrome = false
    @State private var previewAutoSendDialog = false
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case today, tasks, commitments, drafts
        case insight, dailyReport
        case autopilotDashboard
        case contacts, aiButler, notifications, aiService, autopilot, system, preferences, localData, guide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "今天"
            case .drafts: return "草稿"
            case .tasks: return "待办"
            case .commitments: return "我答应的事"
            case .insight: return "聊天回顾"
            case .dailyReport: return "今日小结"
            case .contacts: return "关注谁"
            case .aiButler: return "AI 分析与建议"
            case .notifications: return "提醒方式"
            case .aiService: return "AI 服务"
            case .autopilot: return "自动回复"
            case .autopilotDashboard: return "待确认回复"
            case .system: return "微信连接"
            case .preferences: return "使用偏好"
            case .localData: return "本地资料"
            case .guide: return "怎么用"
            }
        }
        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .drafts: return "square.and.pencil"
            case .tasks: return "checklist"
            case .commitments: return "checkmark.bubble"
            case .insight: return "bubble.left.and.text.bubble.right"
            case .dailyReport: return "doc.text"
            case .contacts: return "person.2"
            case .aiButler: return "sparkles"
            case .notifications: return "bell"
            case .aiService: return "link"
            case .autopilot: return "bolt.shield"
            case .autopilotDashboard: return "bubble.left.and.bubble.right"
            case .system: return "antenna.radiowaves.left.and.right"
            case .preferences: return "slider.horizontal.3"
            case .localData: return "externaldrive"
            case .guide: return "questionmark.circle"
            }
        }
        var subtitle: String {
            switch self {
            case .today: return "待回和待办"
            case .drafts: return "确认后发送"
            case .tasks: return "谁来做"
            case .commitments: return "已答应的事"
            case .insight: return "按天查看"
            case .dailyReport: return "今天做了什么、还剩什么"
            case .contacts: return "关注的对话"
            case .aiButler: return "分析范围"
            case .notifications: return "谁弹出、停多久"
            case .aiService: return "摘要和草稿用哪家"
            case .autopilot: return "自动回复"
            case .autopilotDashboard: return "确认后发送"
            case .system: return "连接微信"
            case .preferences: return "启动、权限、动效"
            case .localData: return "近两周记录"
            case .guide: return "说明"
            }
        }
        var isDaily: Bool { [.today, .tasks, .commitments, .drafts].contains(self) }
        var isReview: Bool { [.insight, .dailyReport].contains(self) }
        var isSettings: Bool {
            [.contacts, .aiButler, .notifications, .aiService, .autopilot, .system, .preferences, .localData, .guide].contains(self)
        }
        static func from(raw: String?) -> Tab? { raw.flatMap(Self.init(rawValue:)) }
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                SettingsSidebarSections(selectedTab: $selectedTab)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)
            .background(CompanionPalette.mist)
            .companionDimmedByDialog(panelState.modalDialogOpen)
            .navigationSplitViewColumnWidth(
                min: largeChrome ? 240 : 208,
                ideal: largeChrome ? 280 : 236,
                max: largeChrome ? 340 : 268
            )
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .companionFont(size: 16, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(CompanionPalette.jade, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CompanionProductCopy.brandName).companionFont(size: 15, weight: .bold)
                        if !CompanionProductCopy.brandPromise.isEmpty {
                            Text(CompanionProductCopy.brandPromise)
                                .companionFont(size: 11)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(CompanionPalette.accent)
                    Text(CompanionProductCopy.sidebarFooter)
                        .companionFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, largeChrome ? 10 : 16)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if PreviewRuntime.isEnabled && !hideCaptureChrome {
                    SettingsPreviewChrome(previewA11yNonce: $previewA11yNonce)
                }
                if selectedTab != .guide {
                    pageHeader
                        .companionDimmedByDialog(panelState.modalDialogOpen)
                }
                content
                    .companionAnimation(CompanionMotion.pageChange(), value: selectedTab)
                WorkspaceStatusBar()
                    .companionDimmedByDialog(panelState.modalDialogOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CompanionPalette.canvas)
        }
        .navigationTitle(CompanionProductCopy.brandName)
        .dynamicTypeSize(PreviewRuntime.largeType ? .accessibility2 : .large)
        .tint(CompanionPalette.accent)
        .accentColor(CompanionPalette.accent)
        .background(SettingsInboxErrorAlert())
        .onAppear { applyPendingTab(panelState.pendingSettingsTab) }
        .onReceive(panelState.$pendingSettingsTab) { applyPendingTab($0) }
        .onReceive(NotificationCenter.default.publisher(for: .hudSwitchTab)) { notification in
            applyPendingTab(notification.object as? String ?? notification.userInfo?["tab"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudPreviewCaptureChrome)) { _ in
            hideCaptureChrome = PreviewRuntime.hideDemoChromeForCapture
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudPreviewAutoSendConfirm)) { _ in
            applyPendingTab("autopilot")
            previewAutoSendDialog = true
        }
        .companionDialogBackdrop(previewAutoSendDialog) {
            if previewAutoSendDialog {
                CompanionDialog(title: CompanionProductCopy.autoSendConfirmTitle, onClose: {
                    previewAutoSendDialog = false
                }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.autoSendConfirmMessage)
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.autoSendKeepManual) { previewAutoSendDialog = false }
                            Button(CompanionProductCopy.autoSendAllow) {
                                previewAutoSendDialog = false
                                var cfg = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
                                cfg.autoSendEnabled = true
                                try? store.setSettingJSON("autopilot", value: cfg)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                        }
                    }
                }
            }
        }
    }

    private var largeChrome: Bool { PreviewRuntime.largeType || typeSize.isAccessibilitySize }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(selectedTab.label).companionFont(size: 30, weight: .bold).minimumScaleFactor(0.7).lineLimit(2)
                Text(selectedTab.subtitle).companionFont(size: 13).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if selectedTab == .today {
                Text(Date(), format: .dateTime.month().day().weekday(.wide))
                    .companionFont(size: 13, weight: .medium).foregroundStyle(.secondary)
            }
            if selectedTab == .contacts {
                Button { NotificationCenter.default.post(name: .hudAddContact, object: nil) } label: {
                    Label("添加关注", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: headerWidth, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: selectedTab == .guide ? .leading : .center)
    }

    private var headerWidth: CGFloat {
        [.aiButler, .notifications, .aiService, .system, .preferences, .localData, .autopilot, .autopilotDashboard, .guide].contains(selectedTab) ? 960 : 1180
    }

    private func applyPendingTab(_ raw: String?) {
        guard let tab = Tab.from(raw: raw) else { return }
        selectedTab = tab
        panelState.pendingSettingsTab = nil
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case .today:
            AssistantTodayView(navigate: { selectedTab = $0 })
        case .tasks:
            DiscussionWorkspaceView()
        case .drafts:
            ReplyDraftsView()
        case .commitments:
            CommitmentTabView()
        case .contacts:
            ContactsSettingsView()
                .frame(maxWidth: 1180)
                .padding(.horizontal, 28).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        case .insight:
            ChatInsightWorkspacePage()
        case .guide:
            CompanionGuideView(navigate: { selectedTab = $0 }, showIntroduction: {
                NotificationCenter.default.post(name: .hudShowOnboarding, object: nil)
            })
        case .aiButler:
            AISettingsView(section: "analysis")
        case .notifications:
            ScrollView {
                NotificationSettingsView()
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
            }
        case .aiService:
            AISettingsView(section: "service")
        case .autopilotDashboard:
            ApprovalWorkspaceView()
                .frame(maxWidth: 1180)
                .padding(.horizontal, 28).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .autopilot: AutopilotSettingsView()
                    case .system: SyncSettingsView(pane: "connection")
                    case .preferences: SyncSettingsView(pane: "preferences")
                    case .localData: SyncSettingsView(pane: "data")
                    case .dailyReport: DailyReportTabView()
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SettingsSidebarSections: View {
    @Binding var selectedTab: SettingsView.Tab
    @EnvironmentObject var workspaceBadges: WorkspaceBadges
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarSection(CompanionProductCopy.sectionHandle, SettingsView.Tab.allCases.filter(\.isDaily))
            sidebarSection(CompanionProductCopy.sectionReview, SettingsView.Tab.allCases.filter(\.isReview))
            sidebarSection(CompanionProductCopy.sectionReply, [.autopilotDashboard])
            sidebarSection(CompanionProductCopy.sectionSettings, SettingsView.Tab.allCases.filter(\.isSettings))
        }
    }

    private func sidebarSection(_ title: String, _ tabs: [SettingsView.Tab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .companionFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(tabs) { tab in sidebarRow(tab) }
        }
    }

    private func sidebarRow(_ tab: SettingsView.Tab) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(selected ? CompanionPalette.jade : Color.clear)
                    .frame(width: 3, height: 18)
                Image(systemName: tab.icon)
                    .companionFont(size: 14, weight: .medium)
                    .foregroundStyle(selected ? CompanionPalette.jade : .secondary)
                    .frame(width: 20)
                Text(tab.label)
                    .companionFont(size: 13, weight: selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let count = sidebarCount(tab), count > 0 {
                    Text(count, format: .number)
                        .companionFont(size: 11, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(CompanionPalette.jade)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(CompanionPalette.sidebarSelectedFill, in: Capsule())
                }
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? CompanionPalette.sidebarSelectedFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(!panelState.modalDialogOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab.label)
        .accessibilityHint("回车打开这一页")
        .accessibilityIdentifier("workspace.\(tab.rawValue)")
        .accessibilityValue(selected ? "已选中" : "")
    }

    private func sidebarCount(_ tab: SettingsView.Tab) -> Int? {
        switch tab {
        case .tasks: return workspaceBadges.counts.tasks
        case .commitments: return workspaceBadges.counts.commitments
        case .drafts: return workspaceBadges.counts.drafts
        case .autopilotDashboard:
            return workspaceBadges.counts.pendingReplies > 0 ? workspaceBadges.counts.pendingReplies : nil
        default: return nil
        }
    }
}

private struct SettingsPreviewChrome: View {
    @Binding var previewA11yNonce: Int
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore

    var body: some View {
        HStack {
            Label("交互演示 · 全部为虚构数据，不读取或操作微信", systemImage: "play.rectangle")
            Spacer()
            Button("模拟新消息") { PreviewRuntime.simulateNotification(monitor: monitor, panelState: panelState) }
            Button("模拟首次浮窗") {
                panelState.islandSurface = .firstLaunch
                panelState.goExtended()
            }
            Button("模拟同步中") {
                monitor.stats.syncStatus = .syncing
                panelState.islandSurface = .inbox
                panelState.goExtended()
            }
            Button("模拟连接中断") {
                monitor.stats.syncStatus = .error("preview")
                panelState.islandSurface = .inbox
                panelState.goExtended()
            }
            Button("打开引导") { NotificationCenter.default.post(name: .hudShowOnboarding, object: nil) }
            Button("模拟发送成功") { PreviewRuntime.simulateSendSuccess(monitor: monitor, panelState: panelState) }
            Button("模拟发送待核对") { PreviewRuntime.simulateSendUncertain(monitor: monitor, panelState: panelState) }
            Button("模拟空浮窗") { PreviewRuntime.simulateEmptyIsland(monitor: monitor, panelState: panelState) }
            Button("模拟收起") { PreviewRuntime.simulateCompact(monitor: monitor, panelState: panelState) }
            Button("模拟 AI 测试失败") {
                panelState.pendingSettingsTab = "aiService"
                PreviewRuntime.simulateAITestFailure()
            }
            Button("模拟开启自动发送") { PreviewRuntime.simulateAutoSendConfirm(panelState: panelState) }
            Button(PreviewRuntime.reduceMotionOverride == true ? "关闭减少动态" : "模拟减少动态") {
                PreviewRuntime.toggleReduceMotion(); previewA11yNonce += 1
            }
            Button(PreviewRuntime.reduceTransparencyOverride == true ? "关闭减少透明" : "模拟减少透明") {
                PreviewRuntime.toggleReduceTransparency(); previewA11yNonce += 1
            }
            Button(PreviewRuntime.largeType ? "关闭大字号" : "模拟大字号") {
                PreviewRuntime.toggleLargeType(); previewA11yNonce += 1
            }
            Button(PreviewRuntime.usingExternalDisplay ? "回到原生屏" : "模拟扩展屏") {
                PreviewRuntime.toggleExternalDisplay(store: store); previewA11yNonce += 1
            }
            Button("导出界面快照") { PreviewRuntime.captureSurfaces() }
        }
        .font(.callout).foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(CompanionMotion.reduceTransparency ? CompanionPalette.surface : Color.orange.opacity(0.08))
        .companionDimmedByDialog(panelState.modalDialogOpen)
        .id(previewA11yNonce)
    }
}

private struct SettingsInboxErrorAlert: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        Color.clear
            .alert("操作未保存", isPresented: Binding(get: { monitor.inboxActionError != nil }, set: { if !$0 { monitor.inboxActionError = nil } })) {
                Button("知道了") { monitor.inboxActionError = nil }
            } message: { Text(monitor.inboxActionError ?? "请重试") }
    }
}

private struct ChatInsightWorkspacePage: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        ChatInsightView(insightCoordinator: monitor.insightCoordinator)
    }
}

private struct WorkspaceStatusBar: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
                .companionFont(size: 12, weight: .medium)
            Spacer()
            if let date = monitor.stats.lastSyncAt {
                Text("上次同步：\(date.formatted(date: .long, time: .shortened))")
                    .companionFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Button { monitor.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)
            .accessibilityLabel("查看新消息")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(CompanionPalette.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var isSyncing: Bool { if case .syncing = monitor.stats.syncStatus { return true }; return false }

    private var title: String {
        switch monitor.stats.syncStatus {
        case .ok: return "微信已连接 · 刚刚同步"
        case .syncing: return "正在读取你关注的聊天"
        case .idle: return "等待首次同步"
        case .stale: return "消息可能不是最新的"
        case .waitingForWeChat: return "等待微信启动"
        case .accountSwitched: return "当前微信账号已经读不到了"
        case .error: return "暂时读不到新消息"
        }
    }

    private var color: Color {
        switch monitor.stats.syncStatus {
        case .ok: return CompanionPalette.jade
        case .syncing, .idle: return .secondary
        default: return .orange
        }
    }

    private var symbol: String {
        switch monitor.stats.syncStatus {
        case .ok: return "checkmark.circle.fill"
        case .syncing, .idle: return "arrow.triangle.2.circlepath"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

extension Notification.Name {
    static let hudAddContact = Notification.Name("WeChatHUD.AddContact")
}
