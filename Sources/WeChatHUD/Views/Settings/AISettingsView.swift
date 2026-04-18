import SwiftUI

extension Notification.Name {
    static let hudAIConfigDidChange = Notification.Name("WeChatHUD.AIConfigDidChange")
    static let hudSwitchTab = Notification.Name("WeChatHUD.SwitchTab")
}

struct AISettingsView: View {
    @EnvironmentObject private var store: HUDStore

    // ── Dual-provider state ──
    @State private var activeMode: AIActiveMode = .local
    @State private var autoCloudFirst: Bool = true
    // Local slot
    @State private var localProviderID = "custom"
    @State private var localBaseURL = ""
    @State private var localModel = ""
    @State private var localApiKey = ""
    // Cloud slot
    @State private var cloudProviderID = "dashscope"
    @State private var cloudBaseURL = ""
    @State private var cloudModel = ""
    @State private var cloudApiKey = ""
    // Per-card test
    @State private var cloudTestResult = ""
    @State private var cloudTesting = false
    @State private var localTestResult = ""
    @State private var localTesting = false

    // Codex (ChatGPT OAuth) status — populated when cloud slot picks "openai-codex".
    @State private var codexLoggedInEmail: String? = nil
    @State private var codexAuthError: String? = nil

    @State private var summaryEnabled = true
    @State private var suggestionsEnabled = true
    @State private var moodDetectionEnabled = true
    @State private var notifyAtMention = true
    @State private var notifyVIP = true
    @State private var notifyWhitelist = false
    @State private var notifyDuration = 3
    @State private var recentGroupContextAudit: [AIAuditEntry] = []
    @State private var didLoad = false

    private var cloudHash: String { "\(cloudProviderID)|\(cloudBaseURL)|\(cloudModel)|\(cloudApiKey)" }
    private var localHash: String { "\(localProviderID)|\(localBaseURL)|\(localModel)|\(localApiKey)" }
    private var togglesHash: String { "\(summaryEnabled)|\(suggestionsEnabled)|\(moodDetectionEnabled)" }
    private var notifyHash: String { "\(notifyAtMention)|\(notifyVIP)|\(notifyWhitelist)|\(notifyDuration)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeSection
            cloudProviderSection
            localProviderSection
            behaviorSection
            notificationSection
            auditSections
        }
        .onAppear(perform: load)
        .onChange(of: activeMode) { _, _ in saveAIConfig() }
        .onChange(of: autoCloudFirst) { _, _ in saveAIConfig() }
        .onChange(of: cloudHash) { _, _ in onCloudChanged() }
        .onChange(of: localHash) { _, _ in onLocalChanged() }
        .onChange(of: togglesHash) { _, _ in saveAIToggles() }
        .onChange(of: notifyHash) { _, _ in saveNotificationConfig() }
    }

    // MARK: - Mode

    private var modeSection: some View {
        SettingsSection("运行模式") {
            SettingsRow("AI 模式", icon: "bolt.fill", iconColor: .purple) {
                Picker("", selection: $activeMode) {
                    Text("仅本地").tag(AIActiveMode.local)
                    Text("仅线上").tag(AIActiveMode.cloud)
                    Text("自动").tag(AIActiveMode.auto)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            if activeMode == .auto {
                SettingsRowDivider()
                SettingsRow("优先", icon: "arrow.triangle.swap", iconColor: .secondary) {
                    Picker("", selection: $autoCloudFirst) {
                        Text("线上优先").tag(true)
                        Text("本地优先").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
        }
    }

    // MARK: - Provider sections

    private var cloudProviderSection: some View {
        let isActive = activeMode == .cloud || activeMode == .auto
        return providerCard(
            title: "线上服务",
            icon: "cloud.fill",
            tint: .blue,
            isActive: isActive,
            providerID: $cloudProviderID,
            baseURL: $cloudBaseURL,
            model: $cloudModel,
            apiKey: $cloudApiKey,
            testResult: $cloudTestResult,
            isTesting: $cloudTesting,
            filterLocal: false
        )
    }

    private var localProviderSection: some View {
        let isActive = activeMode == .local || activeMode == .auto
        return providerCard(
            title: "本地服务",
            icon: "desktopcomputer",
            tint: .green,
            isActive: isActive,
            providerID: $localProviderID,
            baseURL: $localBaseURL,
            model: $localModel,
            apiKey: $localApiKey,
            testResult: $localTestResult,
            isTesting: $localTesting,
            filterLocal: true
        )
    }

    @ViewBuilder
    private func providerCard(
        title: String, icon: String, tint: Color, isActive: Bool,
        providerID: Binding<String>, baseURL: Binding<String>,
        model: Binding<String>, apiKey: Binding<String>,
        testResult: Binding<String>, isTesting: Binding<Bool>,
        filterLocal: Bool
    ) -> some View {
        let provider = AIProvider.find(providerID.wrappedValue)
        let isCustom = providerID.wrappedValue == "custom"
        let providers = filterLocal
            ? AIProvider.builtIn.filter { $0.id == "ollama" || $0.id == "custom" }
            : AIProvider.builtIn.filter { $0.id != "ollama" }

        SettingsSection(title) {
            // Status + test
            SettingsRow("状态", icon: icon, iconColor: tint) {
                HStack(spacing: 8) {
                    if isActive {
                        Text("使用中")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(tint).cornerRadius(3)
                    } else {
                        Text("未激活")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    testButton(
                        providerID: providerID.wrappedValue,
                        baseURL: baseURL.wrappedValue,
                        model: model.wrappedValue,
                        apiKey: apiKey.wrappedValue,
                        result: testResult, testing: isTesting
                    )
                }
            }

            SettingsRowDivider()

            // Provider picker
            SettingsRow("供应商") {
                HStack(spacing: 6) {
                    Picker("", selection: providerID) {
                        ForEach(providers) { p in Text(p.name).tag(p.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 140)

                    if let p = provider, !p.signupURL.isEmpty {
                        Button {
                            if let u = URL(string: p.signupURL) { NSWorkspace.shared.open(u) }
                        } label: {
                            Image(systemName: "key.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .help("获取 API Key")
                    }
                }
            }

            SettingsRowDivider()

            // Base URL
            if isCustom {
                SettingsRow("API 地址") {
                    TextField("https://...", text: baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 200)
                }
                SettingsRowDivider()
            }

            // Model
            SettingsRow("模型") {
                HStack(spacing: 4) {
                    TextField("模型名称", text: model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 160)
                    if let presets = provider?.models, !presets.isEmpty {
                        Menu {
                            ForEach(presets, id: \.self) { name in
                                Button(name) { model.wrappedValue = name }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                    }
                }
            }

            // API Key
            if provider?.requiresKey == true || isCustom {
                SettingsRowDivider()
                SettingsRow("API Key") {
                    SecureField("", text: apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 200)
                }
            }

            // Codex login status (replaces baseURL/apiKey for the OAuth-only provider)
            if providerID.wrappedValue == "openai-codex" {
                SettingsRowDivider()
                codexStatusRow
            }
        }
    }

    @ViewBuilder
    private var codexStatusRow: some View {
        if let err = codexAuthError {
            SettingsRow("登录态", icon: "exclamationmark.triangle.fill", iconColor: .orange) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                    Text("终端运行: codex login")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        } else if let email = codexLoggedInEmail {
            SettingsRow("登录账号", icon: "checkmark.seal.fill", iconColor: .green) {
                Text(email)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        } else {
            SettingsRow("登录态", icon: "questionmark.circle", iconColor: .secondary) {
                Text("正在检测…").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private func testButton(
        providerID: String, baseURL: String, model: String, apiKey: String,
        result: Binding<String>, testing: Binding<Bool>
    ) -> some View {
        HStack(spacing: 4) {
            if !result.wrappedValue.isEmpty {
                Circle()
                    .fill(result.wrappedValue.contains("OK") ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .help(result.wrappedValue)
            }
            Button(action: {
                testing.wrappedValue = true
                result.wrappedValue = ""
                let url = resolvedURL(providerID: providerID, baseURL: baseURL)
                let slot = AIProviderSlot(providerID: providerID, baseURL: url, model: model, apiKey: apiKey)
                let service = AIService(config: buildConfig())
                Task {
                    do {
                        let text = try await service.testSlot(slot)
                        await MainActor.run {
                            result.wrappedValue = "OK: \(text.prefix(20))"
                            testing.wrappedValue = false
                        }
                    } catch {
                        await MainActor.run {
                            result.wrappedValue = "失败: \(error.localizedDescription.prefix(60))"
                            testing.wrappedValue = false
                        }
                    }
                }
            }) {
                if testing.wrappedValue {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                } else {
                    Text("测试").font(.system(size: 10))
                }
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(testing.wrappedValue)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection("管家行为") {
            SettingsToggleRow("消息摘要", subtitle: "AI 生成摘要替代原始预览", isOn: $summaryEnabled)
            SettingsRowDivider()
            SettingsToggleRow("回复建议", subtitle: "展开消息时提供 AI 回复建议", isOn: $suggestionsEnabled)
            SettingsRowDivider()
            SettingsToggleRow("情绪检测", subtitle: "为 VIP 联系人检测消息情绪", isOn: $moodDetectionEnabled)
        }
    }

    // MARK: - Notification

    private var notificationSection: some View {
        SettingsSection("通知过滤") {
            SettingsToggleRow("群聊 @提及", isOn: $notifyAtMention)
            SettingsRowDivider()
            SettingsToggleRow("VIP 消息", isOn: $notifyVIP)
            SettingsRowDivider()
            SettingsToggleRow("所有白名单", isOn: $notifyWhitelist)
            SettingsRowDivider()
            SettingsRow("提醒时长") {
                Picker("", selection: $notifyDuration) {
                    Text("2秒").tag(2)
                    Text("3秒").tag(3)
                    Text("5秒").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
    }

    // MARK: - Audit

    @ViewBuilder
    private var auditSections: some View {
        if !recentGroupContextAudit.isEmpty {
            SettingsSection("AI 审计") {
                auditGroupRows(
                    title: "群聊简报",
                    entries: recentGroupContextAudit,
                    showFeedback: false,
                    onRefresh: { reloadRecentGroupContextAudit() }
                )
            }
        }
    }

    @ViewBuilder
    private func auditGroupRows(
        title: String,
        entries: [AIAuditEntry],
        showFeedback: Bool = false,
        onRefresh: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Button("刷新") { onRefresh() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.blue)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)

        if entries.isEmpty {
            Text("暂无记录")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
        } else {
            ForEach(entries, id: \.id) { entry in
                SettingsRowDivider()
                auditRow(entry)
            }
        }
    }

    private func auditRow(_ entry: AIAuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.auditTimestampFormatter.string(from: entry.ts))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                Text(auditStatusLabel(entry))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(auditStatusColor(entry))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(auditStatusColor(entry).opacity(0.12)).cornerRadius(3)
                Text(entry.model)
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
            }
            Text(auditSummary(entry))
                .font(.system(size: 11)).foregroundColor(.primary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Load / Save

    private func onCloudChanged() {
        guard didLoad else { return }
        if let p = AIProvider.find(cloudProviderID), cloudProviderID != "custom",
           cloudBaseURL != p.baseURL {
            cloudBaseURL = p.baseURL
            if !p.models.contains(cloudModel) { cloudModel = p.models.first ?? "" }
        }
        if cloudProviderID == "openai-codex" { refreshCodexStatus() }
        saveAIConfig()
    }

    /// Probe `~/.codex/auth.json` and surface either the bound email or a
    /// short error string. Runs off the main thread (file IO + JWT decode).
    private func refreshCodexStatus() {
        codexAuthError = nil
        codexLoggedInEmail = nil
        Task.detached(priority: .userInitiated) {
            do {
                let profile = try CodexAuth.readProfile()
                await MainActor.run {
                    codexLoggedInEmail = profile.email ?? "(已登录)"
                    codexAuthError = nil
                }
            } catch let error as CodexError {
                await MainActor.run {
                    codexAuthError = error.errorDescription ?? "未登录"
                    codexLoggedInEmail = nil
                }
            } catch {
                await MainActor.run {
                    codexAuthError = error.localizedDescription
                    codexLoggedInEmail = nil
                }
            }
        }
    }

    private func onLocalChanged() {
        guard didLoad else { return }
        if let p = AIProvider.find(localProviderID), localProviderID != "custom",
           localBaseURL != p.baseURL {
            localBaseURL = p.baseURL
            if !p.models.contains(localModel) { localModel = p.models.first ?? "" }
        }
        saveAIConfig()
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        let cfg = store.loadAIConfig()
        activeMode = cfg.activeMode
        autoCloudFirst = cfg.autoCloudFirst
        cloudProviderID = cfg.cloudProvider.providerID
        cloudBaseURL = cfg.cloudProvider.baseURL
        cloudModel = cfg.cloudProvider.model
        cloudApiKey = cfg.cloudProvider.apiKey
        localProviderID = cfg.localProvider.providerID
        localBaseURL = cfg.localProvider.baseURL
        localModel = cfg.localProvider.model
        localApiKey = cfg.localProvider.apiKey

        summaryEnabled = cfg.summaryEnabled
        suggestionsEnabled = cfg.suggestionsEnabled
        moodDetectionEnabled = cfg.moodDetectionEnabled

        let notifCfg = store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
        notifyAtMention = notifCfg.atMention
        notifyVIP = notifCfg.important
        notifyWhitelist = notifCfg.allWhitelist
        notifyDuration = notifCfg.durationSeconds

        reloadRecentGroupContextAudit()
        if cloudProviderID == "openai-codex" { refreshCodexStatus() }
    }

    private func buildConfig() -> AIConfig {
        var cfg = store.loadAIConfig()
        cfg.activeMode = activeMode
        cfg.autoCloudFirst = autoCloudFirst
        cfg.cloudProvider = AIProviderSlot(
            providerID: cloudProviderID,
            baseURL: resolvedURL(providerID: cloudProviderID, baseURL: cloudBaseURL),
            model: cloudModel, apiKey: cloudApiKey
        )
        cfg.localProvider = AIProviderSlot(
            providerID: localProviderID,
            baseURL: resolvedURL(providerID: localProviderID, baseURL: localBaseURL),
            model: localModel, apiKey: localApiKey
        )
        return cfg
    }

    private func resolvedURL(providerID: String, baseURL: String) -> String {
        if providerID == "custom" { return baseURL }
        return AIProvider.find(providerID)?.baseURL ?? baseURL
    }

    private func saveAIConfig() {
        guard didLoad else { return }
        var cfg = buildConfig()
        cfg.summaryEnabled = summaryEnabled
        cfg.suggestionsEnabled = suggestionsEnabled
        cfg.moodDetectionEnabled = moodDetectionEnabled
        try? store.setSettingJSON("ai", value: cfg)
        NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
    }


    private func saveAIToggles() {
        guard didLoad else { return }
        var cfg = buildConfig()
        cfg.summaryEnabled = summaryEnabled
        cfg.suggestionsEnabled = suggestionsEnabled
        cfg.moodDetectionEnabled = moodDetectionEnabled
        try? store.setSettingJSON("ai", value: cfg)
        NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
    }

    private func saveNotificationConfig() {
        guard didLoad else { return }
        let cfg = NotificationConfig(
            atMention: notifyAtMention, important: notifyVIP,
            allWhitelist: notifyWhitelist, durationSeconds: notifyDuration
        )
        try? store.setSettingJSON("notification", value: cfg)
    }

    // MARK: - Audit helpers

    private func reloadRecentGroupContextAudit() {
        recentGroupContextAudit = store.loadRecentAIAudit(limit: 6, role: .retrospector, promptVersionPrefix: "group_context_")
    }

    private func auditStatusLabel(_ entry: AIAuditEntry) -> String {
        switch entry.status {
        case .ok: return "OK"
        case .parseError: return "PARSE"
        case .httpError: return "HTTP"
        case .timeout: return "TIMEOUT"
        }
    }
    private func auditStatusColor(_ entry: AIAuditEntry) -> Color {
        switch entry.status {
        case .ok: return .green
        case .parseError: return .orange
        case .httpError, .timeout: return .red
        }
    }
    private func auditSummary(_ entry: AIAuditEntry) -> String {
        if let msg = entry.errorMessage, !msg.isEmpty { return msg }
        if !entry.outputText.isEmpty { return String(entry.outputText.prefix(120)) }
        return "无额外说明"
    }

    private static let auditTimestampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
}
