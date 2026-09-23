import SwiftUI

/// In-app help for everyday use. Navigation is owned by SettingsView so the
/// guide stays independent from the workspace's selected-tab state.
struct CompanionGuideView: View {
    let navigate: (SettingsView.Tab) -> Void
    let showIntroduction: () -> Void
    @State private var isCheckingUpdates = false

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty && version != build:
            return "版本 \(version)（\(build)）"
        case let (version?, _) where !version.isEmpty:
            return "版本 \(version)"
        case let (_, build?) where !build.isEmpty:
            return "构建 \(build)"
        default:
            return "版本信息未提供"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introCard
                quickStartCard.companionStagger(index: 0)
                dailyUseCard
                privacyCard
                troubleshootingCard
                shortcutsCard
                aboutCard
            }
            .padding(.top, WorkspacePage.selfHeadedTopGap)
            .padding(.bottom, WorkspacePage.bottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The guide is the one page that owns the whole detail pane, so it
        // shares the same quiet jade atmosphere as every other page.
        .background(CompanionBackdrop(tint: CompanionPalette.accent))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("怎么用 WeChatHUD")
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("怎么用")
                .workspaceDisplay()
        }
        .padding(.bottom, 8)
    }

    private var quickStartCard: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                guideStep(number: "1", title: "连接微信", detail: "读取这台 Mac 上已登录的微信。", buttonTitle: "连接微信", action: showIntroduction)
                guideStep(number: "2", title: "选择关注的人", detail: "选一个联系人或群。", buttonTitle: "选择对话", action: { navigate(.contacts) })
                // The old detail was 「「今天」里看待回和待办。」 — the same
                // sentence the 每天怎么用 card prints 300pt below it, twice on
                // one screen. This one carries the relation instead: the pill
                // reports a number, this page is where the list behind it is.
                // (Deliberately not "岛上报几条，这里就列几条" — the pill counts
                // 待回 only, while this page also lists 待办, as the r12 island
                // captures show: 「1 条待回」 over a 待处理 (3) inbox.)
                guideStep(number: "3", title: "看清下一步", detail: "岛上报数，这里列明细。", buttonTitle: "打开今天", action: { navigate(.today) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                CompanionSectionHeader("常见问题")
                faqRow("看不到消息？") { navigate(.system) }
                faqRow("AI 没有生成摘要？") { navigate(.aiService) }
                faqRow("发送没有成功？") { navigate(.system) }
            }
            .frame(width: 240, alignment: .leading)
        }
    }

    private var dailyUseCard: some View {
        GuideCard(icon: "tray.full.fill", tint: CompanionPalette.accent, title: "每天怎么用", index: 1) {
            guideTopic("从「今天」开始", "看待回和待办。点开一条消息看原文和摘要。", icon: "bubble.left.and.bubble.right")
            guideTopic("没回的", "在「今天」里选时间，找出私聊和群 @ 里你还没回的。", icon: "clock.badge.questionmark")
            guideTopic("群里有人 @你", "会标出谁提到了你。", icon: "person.2.fill")
            guideTopic("我答应的事", "带着原话和截止时间。做完后点完成。", icon: "checkmark.bubble.fill")
            guideTopic("草稿", "写好后存草稿，确认再发。", icon: "square.and.pencil")
            guideTopic("头顶上的提醒", "可分别开关群 @、重点联系人和普通更新。移上去就能看。", icon: "bell.badge.fill")
            // The old ending promised a group draft, but no draft is written
            // until 群里 @我 时也准备回复 is on. What is always true is that a
            // group reply never goes out unattended.
            guideTopic("发送和自动回复", "发送前会确认。自动回复默认关；打开后先到「待确认回复」。群聊不会自动发出。", icon: "paperplane.fill")
        }
    }

    private var privacyCard: some View {
        GuideCard(icon: "lock.shield.fill", tint: CompanionPalette.accent, title: "数据与隐私", index: 2) {
            privacyRow("本机聊天资料", "只读取聊天原文，不改微信记录。事项、草稿和设置保存在这台 Mac。", icon: "externaldrive")
            privacyRow("发给 AI 的内容", "打开 AI 后，相关聊天片段会发给你选的服务，用来写摘要和草稿。请只用你信任的服务。", icon: "arrow.up.right")
            privacyRow("发送和自动回复", "默认每次发送都要你确认。自动回复默认关着；若打开「自动发出去」，符合条件的回复会自己发出。钱、红包这类消息仍不会自动回。", icon: "hand.raised")
        }
    }

    private var troubleshootingCard: some View {
        GuideCard(icon: "wrench.and.screwdriver.fill", tint: CompanionPalette.accent, title: "遇到问题时", index: 3) {
            troubleshootingRow("看不到新消息", "先确认这台 Mac 上的微信已经登录，再打开「微信连接」。页面会告诉你还差哪一步。连上之后点「查看新消息」。", buttonTitle: "检查连接", tab: .system)
            troubleshootingRow("摘要或草稿写不出来", "打开「AI 服务」，确认服务和访问凭据，再点「测试连接」。能不能用、还有没有额度，由你选的服务决定。", buttonTitle: "检查 AI", tab: .aiService)
            troubleshootingRow("跳转或发送没反应", "确认微信已登录，并在「隐私与安全性 → 辅助功能」里允许 WeChatHUD。发送失败时回微信核对，草稿还在。", buttonTitle: "查看连接说明", tab: .system)
            troubleshootingRow("关注错了人", "到「关注谁」里拿掉或改级别。要换微信账号，用连接页的「更换微信账号」；不同账号的资料分开保存。", buttonTitle: "关注谁", tab: .contacts)
        }
    }

    private var shortcutsCard: some View {
        GuideCard(icon: "command", tint: CompanionPalette.accent, title: "键盘快捷键", index: 4) {
            shortcutRow("⌘1", CompanionProductCopy.openCompanion)
            shortcutRow("⌘,", "打开微信连接")
            shortcutRow("Esc", "收起浮窗（仅当前窗口时有效）")
            Text("菜单栏可打开或收起浮窗、查看新消息、退出。")
                .guideSecondary()
                .textSelection(.enabled)
        }
    }

    private var aboutCard: some View {
        GuideCard(icon: "info.circle.fill", tint: CompanionPalette.accent, title: "关于", index: 5) {
            HStack {
                Text(CompanionProductCopy.brandName)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(versionText)
                    .guideSecondary()
                    .textSelection(.enabled)
            }
            HStack {
                Button("重新打开引导", action: showIntroduction)
                    .buttonStyle(.bordered)
                Button {
                    guard !isCheckingUpdates else { return }
                    isCheckingUpdates = true
                    Task {
                        await AppUpdateController.shared.check(force: true, installIfEnabled: false)
                        isCheckingUpdates = false
                        navigate(.preferences)
                    }
                } label: {
                    Text(isCheckingUpdates ? "正在检查…" : "检查更新")
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingUpdates)
                .help(isCheckingUpdates ? "正在检查 GitHub 上的新版本" : "")
                .accessibilityHint(isCheckingUpdates ? "正在检查 GitHub 上的新版本" : "")
                Spacer()
            }
            Text("资料保存在本机；启用线上 AI 时，相关聊天会交给所选服务处理。")
                .guideSecondary()
                .textSelection(.enabled)
        }
    }

    private func faqRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").companionFont(size: 11, weight: .semibold).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(CompanionRowPressStyle())
    }

    private func guideStep(number: String, title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("第 \(number) 步")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).guideSecondary().textSelection(.enabled)
                Button(buttonTitle) { action() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(buttonTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guideTopic(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).guideSecondary().textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func privacyRow(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).guideSecondary().textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func troubleshootingRow(_ title: String, _ detail: String, buttonTitle: String, tab: SettingsView.Tab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body.weight(.semibold))
            Text(detail).guideSecondary().textSelection(.enabled)
            Button(buttonTitle) { navigate(tab) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ key: String, _ action: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 48, alignment: .leading)
            Text(action).guideBody().textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("快捷键 \(key)：\(action)")
    }
}

private struct GuideCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    /// Stagger position within the guide. The page is a long form, so the
    /// cards arrive in reading order rather than all at once.
    ///
    /// Declared before `content` on purpose: an unlabeled trailing closure
    /// only matches the *last* parameter, and these cards are always written
    /// as `GuideCard(…, index: n) { … }`. Putting `content` first made the
    /// compiler reach backwards for it (`#TrailingClosureMatching`).
    var index: Int = 0
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Quiet glyph + title. Same type tokens as the rest of the
            // workspace, so this page does not look like a different app.
            HStack(spacing: 10) {
                CompanionModuleTile(systemImage: icon, tint: tint, selected: true, size: 26)
                Text(title)
                    .workspaceTitle()
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCardFace(padding: 0, tint: tint)
        .companionStagger(index: index)
    }
}

private extension View {
    func guideBody() -> some View {
        workspaceBody()
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func guideSecondary() -> some View {
        workspaceBody()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
