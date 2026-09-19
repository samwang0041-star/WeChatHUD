import SwiftUI

/// One native workspace: daily work first, configuration in its own sidebar section.
struct SettingsView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore
    @State private var selectedTab: Tab = {
        guard let raw = PreviewRuntime.requestedLaunchTab else { return .today }
        guard let tab = Tab(rawValue: raw) else {
            // A typo used to fall back silently, so a QA run aimed at
            // 聊天回顾 would record a 今天 screenshot as if it had landed.
            print("[WCHUD] preview: --preview-tab=\(raw) 不是已知分页，落在「今天」")
            return .today
        }
        return tab
    }()
    /// Owned here rather than left implicit so ⌃⌘S (显示 menu) has something to
    /// toggle. SwiftUI's split view never claims `toggleSidebar:`, so the
    /// standard menu item has to be routed to a binding instead of the
    /// responder chain.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previewA11yNonce = 0
    /// Mirrors `CompanionAccessibility.generation` into an environment value,
    /// so every surface whose contrast tokens are statics actually redraws
    /// when the user flips Increase Contrast. See `CompanionAccessibility`.
    @State private var displayOptionsGeneration = CompanionAccessibility.generation
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
        var subtitle: String? {
            switch self {
            case .today: return "待回和待办"
            // Nothing sends from this page — 继续回复 hands the text to WeChat —
            // so 确认后发送 (the 待确认回复 page's promise) was not kept here.
            case .drafts: return "改好再去微信发"
            case .tasks: return "谁来做"
            // "已答应的事" under the title "我答应的事" restated the heading, and
            // the page body already carries the one line that adds something.
            case .commitments: return nil
            case .insight: return "按天查看"
            case .dailyReport: return "做过和剩下的"
            case .relationshipRadar: return "态度和沉默"
            case .contacts: return "关注的对话"
            case .aiButler: return "分析范围"
            // The two section headers already say 谁弹出 and 停多久; the gloss
            // earns its line by drawing the boundary the footnote used to.
            case .notifications: return "只管顶部浮窗"
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
        /// The page's content width, from the one place that decides it.
        ///
        /// The page header reads this too, which is the whole point: before
        /// this, the header picked its width from a hardcoded list of tabs and
        /// the body picked its own, so 待确认回复 had a 960pt header above an
        /// 1180pt body and 关系雷达 had a 1180pt header above a body that ran
        /// the full width of the window.
        var pageWidth: CGFloat {
            switch self {
            case .today, .tasks, .commitments, .drafts, .contacts,
                 .insight, .relationshipRadar, .autopilotDashboard:
                return WorkspacePage.wideWidth
            case .aiButler, .notifications, .aiService, .autopilot,
                 .system, .preferences, .localData, .dailyReport, .guide:
                return WorkspacePage.narrowWidth
            }
        }
        var accentColor: Color {
            // One accent for the whole workspace.
            //
            // A previous pass gave every sidebar row its own hue so the
            // window would "change rooms". That made 18 saturated tiles
            // compete with the message list this app exists for, and it
            // fought macOS: sidebar icons are supposed to follow the app
            // accent, with a fixed colour only when the colour itself means
            // something (Mail's VIP star). Red / orange stay reserved for
            // destructive work and things that need action.
            CompanionPalette.accent
        }
        static func from(raw: String?) -> Tab? { raw.flatMap(Self.init(rawValue:)) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                    // A page may scroll; it may not paint over the header above
                    // it. Same reason `ReplyDraftsView` clips its panes: with
                    // both the header and a tall body claiming the whole
                    // `VStack`, a body whose ideal height exceeds the pane can
                    // draw across the title block instead of scrolling inside
                    // its own ScrollView. Seen intermittently on 待办 while
                    // live-resizing toward the window minimum. Clipping makes
                    // the overflow impossible rather than unlikely.
                    .clipped()
                    .companionAnimation(CompanionMotion.pageChange(), value: selectedTab)
                WorkspaceStatusBar()
                    .companionDimmedByDialog(panelState.modalDialogOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CompanionBackdrop(tint: selectedTab.accentColor))
        }
        .navigationTitle(CompanionProductCopy.brandName)
        .companionDisplayGeneration(displayOptionsGeneration)
        .dynamicTypeSize(CompanionTypeScale.appliedRange(largeType: PreviewRuntime.largeType))
        .tint(CompanionPalette.accent)
        .accentColor(CompanionPalette.accent)
        .background(SettingsInboxErrorAlert())
        .onAppear { applyPendingTab(panelState.pendingSettingsTab) }
        .onReceive(panelState.$pendingSettingsTab) { applyPendingTab($0) }
        .onReceive(NotificationCenter.default.publisher(for: .hudSwitchTab)) { notification in
            applyPendingTab(notification.object as? String ?? notification.userInfo?["tab"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudPreviewCaptureChrome)) { _ in
            hideCaptureChrome = PreviewRuntime.hideDemoChromeForCapture
        }
        // Increase Contrast / Differentiate Without Color resolve at draw time
        // through `CompanionAccessibility`, which SwiftUI cannot observe on its
        // own. Bumping a @State invalidates this body, and with it every
        // surface that reads a contrast token.
        .onReceive(NotificationCenter.default.publisher(for: CompanionAccessibility.displayOptionsDidChange)) { _ in
            displayOptionsGeneration = CompanionAccessibility.generation
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
                                // Same merge rule as the settings page: this is the
                                // one write that turns unattended sends on, so it
                                // must not rebuild the config from defaults when
                                // the stored record could not be read.
                                _ = try? store.updateAutopilotConfig { $0.autoSendEnabled = true }
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTab.label).workspaceDisplay().minimumScaleFactor(0.7).lineLimit(2)
                if let subtitle = headerSubtitle {
                    Text(subtitle).workspaceBody().onWashSecondary()
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
                .tint(CompanionPalette.accent)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: headerWidth, alignment: .leading)
        // Inset, top air and the gap down to the body all come from the shared
        // page tokens. They used to be literals here while the bodies used
        // theirs, which is precisely how the header and the content underneath
        // drifted onto different edges.
        .padding(.horizontal, WorkspacePage.inset)
        .padding(.top, WorkspacePage.selfHeadedTopGap)
        .padding(.bottom, WorkspacePage.headerGap)
        // Leading, not centred.
        //
        // Centring looked fine while every page body was centred too, but the
        // moment a body pinned itself to a corner (the fix that keeps the
        // status bar at the bottom) the title block drifted ~120pt right of
        // its own content: the 待办 title sat above and to the right of the
        // retention bar it belongs to, and 怎么用 was already leading while
        // every other page was not. One rule for all pages: the header and the
        // body share the pane's left edge, exactly.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The header is as wide as the page it introduces, so the title block and
    /// the body always start on the same edge.
    private var headerWidth: CGFloat { selectedTab.pageWidth }

    private var headerSubtitle: String? {
        if selectedTab == .today, panelState.todayShowsMissedReplies {
            return "指定时间里还没回的私聊和群 @"
        }
        return selectedTab.subtitle
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
                .workspacePage(selectedTab.pageWidth)
        case .insight:
            ChatInsightWorkspacePage()
                .workspacePage(selectedTab.pageWidth)
        case .relationshipRadar:
            RelationshipRadarView()
                .workspacePage(selectedTab.pageWidth)
        case .guide:
            CompanionGuideView(navigate: { selectedTab = $0 }, showIntroduction: {
                NotificationCenter.default.post(name: .hudShowOnboarding, object: nil)
            })
            .workspacePage(selectedTab.pageWidth)
        case .aiButler:
            AISettingsView(section: "analysis")
                .workspacePage(selectedTab.pageWidth)
        case .notifications:
            ScrollView {
                NotificationSettingsView()
            }
            .workspacePage(selectedTab.pageWidth)
        case .aiService:
            AISettingsView(section: "service")
                .workspacePage(selectedTab.pageWidth)
        case .autopilotDashboard:
            ApprovalWorkspaceView()
                .workspacePage(selectedTab.pageWidth)
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
            }
            .workspacePage(selectedTab.pageWidth)
        }
    }
}

private struct SettingsSidebarSections: View {
    @Binding var selectedTab: SettingsView.Tab
    @EnvironmentObject var workspaceBadges: WorkspaceBadges
    @EnvironmentObject var panelState: PanelState
    /// Which row the keyboard is on. SwiftUI's `List` would track this for
    /// free, but the sidebar is hand-built (it needs a gradient fill and a
    /// count capsule per row), so the focus ring has to be drawn by hand —
    /// otherwise Tab moves through eighteen invisible stops. HIG treats a
    /// visible focus indicator as a requirement for exactly this reason.
    @FocusState private var focusedTab: SettingsView.Tab?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarSection(CompanionProductCopy.sectionHandle, SettingsView.Tab.allCases.filter(\.isDaily))
            sidebarSection(CompanionProductCopy.sectionReview, SettingsView.Tab.allCases.filter(\.isReview))
            sidebarSection(CompanionProductCopy.sectionReply, [.autopilotDashboard])
            sidebarSection(CompanionProductCopy.sectionSettings, SettingsView.Tab.allCases.filter(\.isSettings))
        }
        // The window has to give initial key focus to *some* view, and the
        // default is the first row — so opening 关系雷达 rings 今天, two rows
        // above the page actually showing. Point the keyboard at the page the
        // user is on instead: the ring then agrees with the selection, and Tab
        // continues from where the eye already is.
        .task { focusedTab = selectedTab }
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
            focused: focusedTab == tab,
            action: { selectedTab = tab }
        )
        .focused($focusedTab, equals: tab)
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
    /// Owning view tracks focus because `List` is not doing it here; the row
    /// only needs to know whether to draw the ring.
    var focused: Bool = false
    let action: () -> Void
    @EnvironmentObject var panelState: PanelState
    @Environment(\.companionDisplayGeneration) private var displayGeneration
    @State private var hovered = false

    var body: some View {
        let _ = displayGeneration
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? CompanionPalette.accent : Color.secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
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
                        .foregroundStyle(selected ? CompanionPalette.accent : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            CompanionPalette.accent.opacity(selected ? 0.18 : 0.10),
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
            // Inside the button label so the ring follows the row's own
            // rounded rect rather than the enclosing stack, and so it is
            // visible on the selected row too — where a jade wash would
            // otherwise swallow a jade ring.
            .companionFocusRing(focused, radius: 9)
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

    /// Selected rows take a quiet jade wash. Colour is not used to name the
    /// room — the label does that — so the sidebar stays one product.
    private var sidebarRowFill: LinearGradient {
        if selected {
            return LinearGradient(
                colors: [
                    CompanionPalette.accent.opacity(CompanionMotion.reduceTransparency ? 0.22 : 0.14),
                    CompanionPalette.accent.opacity(CompanionMotion.reduceTransparency ? 0.16 : 0.08)
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
            Button(PreviewRuntime.increaseContrastOverride == true ? "关闭提高对比度" : "模拟提高对比度") {
                PreviewRuntime.toggleIncreaseContrast(); previewA11yNonce += 1
            }
            Button(PreviewRuntime.differentiateWithoutColorOverride == true ? "关闭不用颜色区分" : "模拟不用颜色区分") {
                PreviewRuntime.toggleDifferentiateWithoutColor(); previewA11yNonce += 1
            }
            Button(PreviewRuntime.usingExternalDisplay ? "回到原生屏" : "模拟扩展屏") {
                PreviewRuntime.toggleExternalDisplay(store: store); previewA11yNonce += 1
            }
            Button("导出界面快照") { PreviewRuntime.captureSurfaces() }
            }
        }
        .font(.callout).foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspacePage.inset).padding(.vertical, 10)
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
            CompanionStatusDot(tint: color, level: level, pulsing: isSyncing)
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
                    // Measured at 12×14 before this: the footer's refresh was
                    // the smallest target in the window, on the control a user
                    // reaches for when the list looks stale. Same glyph, a
                    // target the pointer can actually find.
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)
            .accessibilityLabel("查看新消息")
            .help("查看新消息")
        }
        .padding(.horizontal, WorkspacePage.inset)
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

    /// The state half of the footer. Freshness is the right-hand column's job
    /// (`上次同步 …`), so this must not restate it — the bar used to read
    /// 「微信已连接 · 刚刚同步 …… 上次同步 2026年9月18日 19:50」, the same fact
    /// twice in one 30 pt-tall strip, in two time formats.
    private var title: String {
        switch monitor.stats.syncStatus {
        case .ok: return "微信已连接"
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
        case .ok: return CompanionPalette.jadeInk
        case .syncing, .idle: return .secondary
        default: return .orange
        }
    }

    /// The same three states as a shape, for the Differentiate Without Color
    /// switch. Kept next to `color` so the two can never disagree about how
    /// many levels exist.
    private var level: CompanionStatusDot.Level {
        switch monitor.stats.syncStatus {
        case .ok: return .ok
        case .syncing, .idle: return .working
        default: return .attention
        }
    }
}

extension Notification.Name {
    static let hudAddContact = Notification.Name("WeChatHUD.AddContact")
}
