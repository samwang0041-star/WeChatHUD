import SwiftUI

/// In-app help for everyday use. Navigation is owned by SettingsView so the
/// guide stays independent from the workspace's selected-tab state.
struct CompanionGuideView: View {
    let navigate: (SettingsView.Tab) -> Void
    let showIntroduction: () -> Void

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
                quickStartCard
                dailyUseCard
                privacyCard
                troubleshootingCard
                shortcutsCard
                aboutCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("怎么用不漏事")
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("不漏事，从这里开始。")
                .font(.system(size: 28, weight: .bold))
            Text("少翻聊天，记住答应的事，需要时再回复。")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private var quickStartCard: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                guideStep(number: "1", title: "连接微信", detail: "先让助手读到你关心的聊天。", buttonTitle: "连接微信", action: showIntroduction)
                guideStep(number: "2", title: "选择关注的人", detail: "从一位联系人或一个群开始。", buttonTitle: "选择对话", action: { navigate(.contacts) })
                guideStep(number: "3", title: "看清下一步", detail: "谁在等你、你答应了什么，都在今天。", buttonTitle: "打开今天", action: { navigate(.today) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Text("常见问题").font(.system(size: 15, weight: .semibold))
                faqRow("看不到消息？") { navigate(.system) }
                faqRow("AI 没有生成摘要？") { navigate(.aiService) }
                faqRow("发送没有成功？") { navigate(.system) }
            }
            .frame(width: 240, alignment: .leading)
        }
    }

    private var dailyUseCard: some View {
        GuideCard(icon: "tray.full.fill", tint: .blue, title: "每天怎么用") {
            guideTopic("从「今天」开始", "打开聊天伴侣，先看该回的和该做的。点开一条消息能看原文、摘要和下一步。普通闲聊可以先收起来。", icon: "bubble.left.and.bubble.right")
            guideTopic("群里有人 @你", "群消息会标出谁提到了你。点「看看什么事」就能看发生了什么、为什么找你、接下来怎么办。", icon: "person.2.fill")
            guideTopic("我答应的事", "答应过别人的话会留在这里，带着原话和截止时间。真正做完了再点完成，不要只靠自动整理。", icon: "checkmark.bubble.fill")
            guideTopic("草稿", "在对话里写好回复后选「存为草稿」，之后可以在「草稿」里接着改、复制或回到原对话。草稿不会自己发出去。", icon: "square.and.pencil")
            guideTopic("头顶上的提醒", "可以分别决定：群里 @你、重点联系人、普通更新要不要弹出。鼠标移上去就能继续看。到期提醒走系统通知。", icon: "bell.badge.fill")
            guideTopic("发送和自动回复", "点「发送」会先让你看清发给谁、发什么。自动回复默认关着；打开后，写好的内容先出现在「待确认回复」。群聊不会自动发。", icon: "paperplane.fill")
        }
    }

    private var privacyCard: some View {
        GuideCard(icon: "lock.shield.fill", tint: .orange, title: "数据与隐私") {
            privacyRow("本机聊天资料", "连接时只读取聊天原文，不修改微信里的记录。助手整理出的事项、草稿和设置保存在这台 Mac。", icon: "externaldrive")
            privacyRow("发给 AI 的内容", "打开 AI 后，相关聊天片段会发给你选的服务，用来写摘要和草稿。请只用你信任的服务。", icon: "arrow.up.right")
            privacyRow("发送和自动回复", "每次发送都要你点一下确认。自动回复默认关着。钱、红包这类消息不会自动回。打开前先用一两个人试。", icon: "hand.raised")
        }
    }

    private var troubleshootingCard: some View {
        GuideCard(icon: "wrench.and.screwdriver.fill", tint: .purple, title: "遇到问题时") {
            troubleshootingRow("看不到新消息", "先确认这台 Mac 上的微信已经登录，再打开「微信连接」。页面会告诉你还差哪一步。连上之后点「查看新消息」。", buttonTitle: "检查连接", tab: .system)
            troubleshootingRow("摘要或草稿写不出来", "打开「AI」，确认服务和密钥，再点「测试连接」。能不能用、还有没有额度，由你选的服务决定。", buttonTitle: "检查 AI", tab: .aiButler)
            troubleshootingRow("跳转或发送没反应", "确认微信正在运行并已登录，并在系统设置的「隐私与安全性 → 辅助功能」里允许聊天伴侣控制微信。发送失败时回到微信核对当前对话，草稿还在。", buttonTitle: "查看连接说明", tab: .system)
            troubleshootingRow("关注错了人", "到「关注谁」里拿掉或改级别。要换微信账号，用连接页的「更换微信账号」；不同账号的资料分开保存。", buttonTitle: "关注谁", tab: .contacts)
        }
    }

    private var shortcutsCard: some View {
        GuideCard(icon: "command", tint: .gray, title: "键盘快捷键") {
            shortcutRow("⌘1", CompanionProductCopy.openCompanion)
            shortcutRow("⌘,", "打开微信连接")
            shortcutRow("Esc", "把不漏事收成一条（只在它是当前窗口时有效）")
            Text("菜单栏可以打开或收起不漏事、查看新消息，以及退出。")
                .guideSecondary()
                .textSelection(.enabled)
        }
    }

    private var aboutCard: some View {
        GuideCard(icon: "info.circle.fill", tint: .secondary, title: "关于") {
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
                Button("检查更新") {
                    navigate(.preferences)
                    Task { await AppUpdateController.shared.check(force: true, installIfEnabled: false) }
                }
                .buttonStyle(.bordered)
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
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55)))
    }
}

private extension View {
    func guideBody() -> some View {
        font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func guideSecondary() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
