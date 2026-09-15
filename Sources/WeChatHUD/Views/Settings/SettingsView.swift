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
        case insight, dailyReport, relationshipRadar
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
            case .relationshipRadar: return "关系雷达"
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
            case .relationshipRadar: return "point.3.connected.trianglepath.dotted"
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
            case .dailyReport: return "做过和剩下的"
            case .relationshipRadar: return "态度和沉默"
            case .contacts: return "关注的对话"
            case .aiButler: return "分析范围"
            case .notifications: return "谁弹出、停多久"
            case .aiService: return "摘要用哪家"
            case .autopilot: return "怎么自动回"
            case .autopilotDashboard: return "确认后发送"
            case .system: return "连接微信"
            case .preferences: return "启动和动效"
            case .localData: return "近两周记录"
            case .guide: return "说明"
            }
        }
        var isDaily: Bool { [.today, .tasks, .commitments, .drafts].contains(self) }
        var isReview: Bool { [.insight, .dailyReport, .relationshipRadar].contains(self) }
        var isSettings: Bool {
            [.contacts, .aiButler, .notifications, .aiService, .autopilot, .system, .preferences, .localData, .guide].contains(self)
        }
        var accentColor: Color {
            switch self {
            case .today: return CompanionPalette.jade
            case .tasks: return Color(red: 0.20, green: 0.55, blue: 0.85) // Crisp productivity blue
            case .commitments: return Color(red: 0.18, green: 0.68, blue: 0.58) // Mint
            case .drafts: return Color(red: 0.35, green: 0.45, blue: 0.88) // Indigo
            case .insight: return Color(red: 0.60, green: 0.38, blue: 0.85) // Clean purple
            case .dailyReport: return Color(red: 0.88, green: 0.52, blue: 0.18) // Amber
            case .relationshipRadar: return Color(red: 0.85, green: 0.32, blue: 0.52) // Rose
            case .autopilotDashboard, .autopilot: return Color(red: 0.22, green: 0.65, blue: 0.85) // Cyan
            case .contacts: return Color(red: 0.30, green: 0.62, blue: 0.48)
            case .aiButler, .aiService: return Color(red: 0.55, green: 0.42, blue: 0.90) // Violet
            case .notifications: return Color(red: 0.90, green: 0.45, blue: 0.20)
            case .system: return Color(red: 0.25, green: 0.70, blue: 0.55)
            case .preferences, .localData, .guide: return CompanionPalette.jade
            }
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
                        Text(CompanionProductCopy.brandName).workspaceTitle()
                        if !CompanionProductCopy.brandPromise.isEmpty {
                            Text(CompanionProductCopy.brandPromise)
                                .companionFont(size: 11)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)
                // The inset floats over the scrolling rows. Without its own
                // ground the last visible row shows through the brand block
                // and the two read as one garbled line.
                .background(sidebarInsetGround)
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
                // Opaque, unlike the header: rows scroll *up* behind this
                // block, so the text would otherwise sit on top of them. The
                // header can afford a fade because content arrives from below
                // it already.
                .background(CompanionPalette.mist)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .companionAnimation(CompanionMotion.pageChange(), value: selectedTab)
                WorkspaceStatusBar()
                    .companionDimmedByDialog(panelState.modalDialogOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CompanionBackdrop(tint: selectedTab.accentColor))
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

    /// Ground for the sidebar's floating header and footer. The mist colour
    /// plus a fade toward the rows, so the block separates from scrolled
    /// content without drawing a hard rule across the column.
    private var sidebarInsetGround: some View {
        ZStack {
            CompanionPalette.mist
            if !CompanionMotion.reduceTransparency {
                LinearGradient(
                    colors: [CompanionPalette.mist.opacity(0), CompanionPalette.mist],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                // The module's own tile, at page scale. Same colour, same
                // geometry as the sidebar row that opened it, so arriving on
                // a page confirms where you are without re-reading the title.
                CompanionModuleTile(
                    systemImage: selectedTab.icon,
                    tint: selectedTab.accentColor,
                    selected: true,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTab.label).workspaceDisplay().minimumScaleFactor(0.7).lineLimit(2)
                    Text(selectedTab.subtitle).workspaceBody().onWashSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            if selectedTab == .today {
                Text(Date(), format: .dateTime.month().day().weekday(.wide))
                    .companionFont(size: 13, weight: .medium).onWashSecondary()
            }
            if selectedTab == .contacts {
                Button { NotificationCenter.default.post(name: .hudAddContact, object: nil) } label: {
                    Label("添加关注", systemImage: "plus")
                }
                .buttonStyle(CompanionGlowButtonStyle(tint: selectedTab.accentColor))
            }
        }
        .frame(maxWidth: headerWidth, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)
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
        case .relationshipRadar:
            RelationshipRadarView()
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
                .workspaceMeta()
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(tabs) { tab in sidebarRow(tab) }
        }
    }

    private func sidebarRow(_ tab: SettingsView.Tab) -> some View {
        SettingsSidebarRow(
            tab: tab,
            selected: selectedTab == tab,
            count: sidebarCount(tab),
            action: { selectedTab = tab }
        )
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

private struct SettingsSidebarRow: View {
    let tab: SettingsView.Tab
    let selected: Bool
    let count: Int?
    let action: () -> Void
    @EnvironmentObject var panelState: PanelState
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                CompanionModuleTile(
                    systemImage: tab.icon,
                    tint: tab.accentColor,
                    selected: selected,
                    hovered: hovered
                )
                Text(tab.label)
                    .companionFont(size: WorkspaceType.rowTitle, weight: selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text(count, format: .number)
                        .workspaceMicro()
                        .monospacedDigit()
                        .foregroundStyle(selected ? tab.accentColor : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            tab.accentColor.opacity(selected ? 0.20 : 0.11),
                            in: Capsule()
                        )
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(sidebarRowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected && !CompanionMotion.reduceTransparency
                            ? tab.accentColor.opacity(0.22) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(CompanionPressStyle())
        .onHover { hovered = $0 }
        .companionAnimation(CompanionMotion.hover(), value: hovered)
        .companionAnimation(CompanionMotion.sidebarSelection(), value: selected)
        .focusable(!panelState.modalDialogOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab.label)
        // One string serves the tooltip and VoiceOver, so the promise a
        // mouse user reads and the one a screen reader announces cannot drift
        // apart. The hint says what the page is *for*, not what the label
        // already says.
        .accessibilityHint(CompanionInteractionCopy.pageHint(for: tab.rawValue))
        .help(CompanionInteractionCopy.pageHint(for: tab.rawValue))
        .accessibilityIdentifier("workspace.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Selected rows carry a tint of their own module colour rather than the
    /// brand green, so the sidebar reads as "you are in the blue module"
    /// before the eye reaches the page title. Hover is the neutral step below.
    private var sidebarRowFill: LinearGradient {
        if selected {
            return LinearGradient(
                colors: [
                    tab.accentColor.opacity(CompanionMotion.reduceTransparency ? 0.30 : 0.20),
                    tab.accentColor.opacity(CompanionMotion.reduceTransparency ? 0.22 : 0.13)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                Color.primary.opacity(hovered ? 0.055 : 0),
                Color.primary.opacity(hovered ? 0.035 : 0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct SettingsPreviewChrome: View {
    @Binding var previewA11yNonce: Int
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore

    var body: some View {
        // Fifteen buttons in one HStack collapsed into vertical
        // one-character-per-line labels the moment the workspace was
        // narrower than the row's ideal width — which is exactly the size
        // QA screenshots are taken at, so the demo controls became
        // unreadable. An adaptive grid keeps every label legible at any
        // window width.
        VStack(alignment: .leading, spacing: 8) {
            Label("交互演示 · 全部为虚构数据，不读取或操作微信", systemImage: "play.rectangle")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
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
            // Status carries a light, not an icon. A tinted dot with a halo
            // says connected / working / needs-attention at a glance and
            // stops the bar from reading as a row of toolbar buttons; the
            // symbol that used to sit here duplicated the sentence next to it.
            CompanionStatusDot(tint: color, pulsing: isSyncing)
            Text(title)
                .companionFont(size: 12, weight: .medium)
            Spacer()
            if let date = monitor.stats.lastSyncAt {
                Text("上次同步 \(date.formatted(date: .abbreviated, time: .shortened))")
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
        .background(statusBarBackground)
        .overlay(alignment: .top) { Divider() }
    }

    /// The bar is a footer, not a card: it keeps the window ground and adds
    /// only enough separation to stay legible when content scrolls under it.
    private var statusBarBackground: some View {
        ZStack {
            CompanionPalette.canvas
            if !CompanionMotion.reduceTransparency {
                LinearGradient(
                    colors: [Color.primary.opacity(0.035), Color.primary.opacity(0.055)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var isSyncing: Bool { if case .syncing = monitor.stats.syncStatus { return true }; return false }

    private var title: String {
        switch monitor.stats.syncStatus {
        case .ok: return "微信已连接 · 刚刚同步"
        case .syncing:
            // Name the object being read and how much of it. "正在读取你关注
            // 的聊天" was true but unmeasurable: it left the user unable to
            // tell a two-chat refresh from a first full scan.
            let watched = monitor.inboxItems.count
            return CompanionInteractionCopy.readingChats(watched)
        case .idle: return CompanionInteractionCopy.firstScan
        case .stale: return "读到的是旧消息，可能微信刚更新过"
        case .waitingForWeChat: return CompanionInteractionCopy.waitingForWeChat
        case .accountSwitched: return "换了微信账号，之前的记录已经读不到了"
        case .error: return "暂时读不到新消息，可以重试"
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
