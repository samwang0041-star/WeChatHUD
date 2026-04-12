import SwiftUI

/// First-launch onboarding flow. Guides through:
/// 1. WeChat detection  2. AI setup  3. First whitelist  4. Feature overview
struct OnboardingView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor
    let onComplete: () -> Void

    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Step content
            Group {
                switch step {
                case 0: wechatDetection
                case 1: aiSetup
                case 2: whitelistGuide
                default: featureOverview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)

            // Navigation
            HStack {
                if step > 0 {
                    Button("上一步") { step -= 1 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                if step < 3 {
                    Button("下一步") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("开始使用") {
                        try? store.setSetting("onboarded", value: "true")
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Step 1: WeChat Detection

    private var wechatDetection: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            Text("检测微信")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            let running = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.tencent.xinWeChat"
            }
            if running {
                Label("微信正在运行", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13))
            } else {
                Label("请先启动微信", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))
                Text("WeChatHUD 需要读取微信的本地数据库")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Step 2: AI Setup

    private var aiSetup: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 32))
                .foregroundColor(.purple)
            Text("AI 引擎配置")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            let config = store.loadAIConfig()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("当前 API:")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(config.baseURL.isEmpty ? "未配置" : config.baseURL)
                        .font(.system(size: 11))
                        .foregroundColor(config.baseURL.isEmpty ? .orange : .green)
                }
                HStack {
                    Text("模型:")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(config.model.isEmpty ? "未配置" : config.model)
                        .font(.system(size: 11))
                        .foregroundColor(config.model.isEmpty ? .orange : .green)
                }
            }

            Text("可以稍后在设置 → AI 引擎中修改")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Step 3: Whitelist

    private var whitelistGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.blue)
            Text("添加关注联系人")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            let whitelist = store.getWhitelist()
            if whitelist.isEmpty {
                Text("白名单为空 — HUD 只分析白名单中的对话")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("稍后在设置 → 联系人中添加")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Label("已有 \(whitelist.count) 个联系人", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13))
            }
        }
    }

    // MARK: - Step 4: Features

    private var featureOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("功能概览")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            featureRow("🔔", "实时监控", "未读消息、@提醒、VIP 动态")
            featureRow("📊", "回复债务", "跨聊天回复优先级排序")
            featureRow("🕐", "追赶模式", "离开后快速了解重要消息")
            featureRow("🤝", "承诺追踪", "自动检测你的承诺并提醒")
            featureRow("🤖", "自动托管", "AI 代回消息（可关闭）")
            featureRow("⌨️", "快捷键", "Esc 折叠, Cmd+1-5 切换标签")
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(icon).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
