import SwiftUI
import AppKit

/// First launch introduces the product without treating a wizard click as
/// evidence of connectivity or enabling additional analysis/sending scope.
struct OnboardingView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor
    let onOpenSettings: ((String) -> Void)?
    let onComplete: () -> Void

    @State private var step = 0
    @State private var candidates: [String] = []
    @State private var configuration = AIConfig()
    @State private var saveError: String?
    @State private var refreshID = 0

    init(onOpenSettings: ((String) -> Void)? = nil, onComplete: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onComplete = onComplete
    }

    private let steps = FirstLaunchGuide.stepTitles

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(CompanionPalette.jade, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(CompanionProductCopy.brandName).font(.headline)
                    Text(CompanionProductCopy.brandPromise).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20)
            stepIndicator
                .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 16)
                .accessibilityLabel("\(steps[step])，第 \(step + 1) 步，共 \(steps.count) 步")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: wechatDetection
                    default: whitelistGuide
                    }
                    if let saveError {
                        Text(saveError).font(.callout).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            Divider()
            HStack {
                if step > 0 {
                    Button(FirstLaunchGuide.backCTA) { step -= 1; refresh() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    // Opening the workspace without writing the onboarded
                    // marker keeps the introduction available next launch.
                    Button(FirstLaunchGuide.skipCTA) { finish(openWorkspace: true, markOnboarded: false) }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if let footerHint {
                    Text(footerHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button(primaryCTA) {
                    if step == 0 { step = 1; refresh() }
                    else { finish(openWorkspace: true) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == 0 && !readiness.hasSuccessfulSync && !PreviewRuntime.isEnabled)
            }
            .controlSize(.regular)
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(CompanionPalette.accent)
        .companionAnimation(CompanionMotion.ease(0.15), value: step)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .hudOnboardingAdvance)) { _ in
            guard step == 0 else { return }
            step = 1
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConfigDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConnectionEvidenceDidChange).receive(on: RunLoop.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var directoryDiagnosis: SyncConnectionDiagnosis {
        let configured = (store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()).wechatDBPath
        return SyncConnectionDiagnosis.evaluate(configuredPath: configured, candidates: candidates,
            exists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }, readable: { FileManager.default.isReadableFile(atPath: $0) },
            containsDatabase: { FileManager.default.fileExists(atPath: $0 + "/session/session.db") })
    }

    private var readiness: OnboardingReadiness {
        _ = refreshID
        let sourceMatches: Bool
        if case .ready(let root) = directoryDiagnosis {
            sourceMatches = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: monitor.reader.dbDir).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            sourceMatches = false
        }
        return OnboardingReadiness(
            directoryReady: !directoryDiagnosis.needsAttention,
            keyFileReadable: monitor.reader.accessMaterialState == .available,
            hasSuccessfulSync: sourceMatches && monitor.stats.lastSyncAt != nil,
            aiConfigurationValid: AISettingsValidation.connectionError(configuration.provider, requireModel: true) == nil,
            aiConnectionTested: AIConnectionEvidenceStore.isSuccessful(configuration, store: store),
            trackedConversationCount: store.getWhitelist().count)
    }

    private var primaryCTA: String {
        FirstLaunchGuide.primaryCTA(forStep: step)
    }

    private var footerHint: String? {
        if step == 0 && !readiness.hasSuccessfulSync && !PreviewRuntime.isEnabled {
            return "连上微信后才能继续"
        }
        if step == 1 && readiness.trackedConversationCount == 0 {
            return FirstLaunchGuide.contactsSkipHint
        }
        return nil
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(index <= step ? Color.white : .secondary)
                        .frame(width: 26, height: 26)
                        .background(index <= step ? CompanionPalette.jade : Color.primary.opacity(0.08), in: Circle())
                    Text(title)
                        .font(.system(size: 11, weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? CompanionPalette.jade : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < step ? CompanionPalette.jade : Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .padding(.bottom, 18)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private var wechatDetection: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("先连接你的微信", subtitle: "连接后，助手会在需要时帮你梳理重要消息，不漏下该处理的事。")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    numberedStep(1, "在这台 Mac 上登录微信", "请先确保已在本地正常登录微信。")
                    numberedStep(2, "点击连接，按系统提示允许读取", "我们只读取聊天内容，不会修改任何记录。")
                    numberedStep(3, "看到连接成功后继续", "连接成功后，进入下一步选择你关注的对象。")
                }
                VStack(spacing: 8) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(CompanionPalette.jade)
                    Text((!NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty
                          || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.WeChat").isEmpty)
                         ? "微信已登录" : "等待连接")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 140)
                .padding(.top, 8)
            }
            WeChatConnectionSetupView()
            Text("只读取聊天，不修改微信记录。AI 和自动回复稍后按需开启。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func numberedStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(CompanionPalette.jade, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var whitelistGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(FirstLaunchGuide.contactsTitle, subtitle: FirstLaunchGuide.contactsSubtitle)
            FirstLaunchContactPicker()
            Label(FirstLaunchGuide.contactsFooter, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        candidates = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        configuration = store.loadAIConfig()
        refreshID += 1
    }

    @discardableResult
    private func openSettings(_ tab: String) -> Bool {
        if let onOpenSettings { onOpenSettings(tab); return true }
        guard let app = NSApp.delegate as? AppDelegate, let state = app.panelState else {
            saveError = "暂时无法打开设置，请使用菜单栏的设置入口。"
            return false
        }
        state.pendingSettingsTab = tab
        state.showDetail()
        return true
    }

    private func finish(openWorkspace: Bool, markOnboarded: Bool = true) {
        do {
            // "稍后再设置" opens the workspace without recording the
            // introduction as done, so the next launch still offers it.
            if markOnboarded {
                try store.setSetting("onboarded", value: "true")
            }
            saveError = nil
            if openWorkspace && !openSettings("today") { return }
            onComplete()
        } catch {
            saveError = "介绍进度未能保存，请重试。连接设置不受影响。"
        }
    }
}
