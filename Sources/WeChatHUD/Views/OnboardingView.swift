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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(CompanionPalette.jade, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(CompanionProductCopy.brandName).workspaceTitle()
                    if !CompanionProductCopy.brandPromise.isEmpty {
                        Text(CompanionProductCopy.brandPromise)
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                stepIndicator
                    // One element, one label. Without collapsing the children
                    // the label applied here was inherited by every title
                    // inside, so the wizard's step was announced twice.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(FirstLaunchGuide.pageTitle(at: step))，第 \(step + 1) 步，共 \(FirstLaunchGuide.pageTitles.count) 步")
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

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
        // Only the rendered pages get a label. The third step title
        // ("开始使用") is the CTA on the last page, and showing it as a
        // grey dot promised a page the wizard never opens.
        HStack(spacing: 6) {
            ForEach(Array(FirstLaunchGuide.pageTitles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Text("·")
                        .workspaceMeta()
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .companionFont(
                        size: WorkspaceType.meta,
                        weight: index == step ? .semibold : .regular
                    )
                    .foregroundStyle(index == step ? .primary : .secondary)
            }
        }
    }

    private var wechatDetection: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("先连接你的微信", subtitle: "连接后读取你选的对话。")
            WeChatConnectionSetupView()
            Text("AI 和自动回复稍后按需开启。")
                .workspaceMeta()
                .foregroundStyle(.secondary)
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
            Text(title).workspaceDisplay()
            Text(subtitle).workspaceBody().foregroundStyle(.secondary)
        }
    }



    private func refresh() {
        candidates = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        configuration = store.loadAIConfig()
        refreshID += 1
    }

    private func perform(_ action: OnboardingReadinessAction) {
        switch action {
        case .wechatConnection:
            step = 0
            refresh()
        case .configureAI, .testAI:
            _ = openSettings("aiButler")
        case .chooseContacts:
            _ = openSettings("contacts")
        }
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
