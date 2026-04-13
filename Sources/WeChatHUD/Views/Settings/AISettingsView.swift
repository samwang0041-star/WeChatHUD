import SwiftUI

extension Notification.Name {
    static let hudAIConfigDidChange = Notification.Name("WeChatHUD.AIConfigDidChange")
    static let hudReplyDebtAIConfigDidChange = Notification.Name("WeChatHUD.ReplyDebtAIConfigDidChange")
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

    @State private var replyDebtAIEnabled = false
    @State private var replyDebtShadowMode = true
    @State private var summaryEnabled = true
    @State private var suggestionsEnabled = true
    @State private var moodDetectionEnabled = true
    @State private var notifyAtMention = true
    @State private var notifyVIP = true
    @State private var notifyWhitelist = false
    @State private var notifyDuration = 3
    @State private var recentReplyDebtAudit: [AIAuditEntry] = []
    @State private var recentGroupContextAudit: [AIAuditEntry] = []
    @State private var recentReplyDebtFeedback: [AIFeedbackEntry] = []
    @State private var replyDebtFeedbackByKey: [String: AIFeedbackEntry] = [:]
    @State private var didLoad = false
    @State private var showSaved = false

    // Combine provider fields into a single equatable value for change detection.
    private var cloudHash: String { "\(cloudProviderID)|\(cloudBaseURL)|\(cloudModel)|\(cloudApiKey)" }
    private var localHash: String { "\(localProviderID)|\(localBaseURL)|\(localModel)|\(localApiKey)" }
    private var togglesHash: String { "\(summaryEnabled)|\(suggestionsEnabled)|\(moodDetectionEnabled)" }
    private var notifyHash: String { "\(notifyAtMention)|\(notifyVIP)|\(notifyWhitelist)|\(notifyDuration)" }
    private var debtHash: String { "\(replyDebtAIEnabled)|\(replyDebtShadowMode)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modeSelector
            Divider()
            cloudSection
            Divider()
            localSection
            Divider()
            testAndTogglesSection
            Divider()
            butlerBehaviorSection
            Divider()
            notificationSection
            Divider()
            auditSection
            groupContextAuditSection
            feedbackSection
        }
        .onAppear(perform: load)
        .onChange(of: activeMode) { _, _ in saveAIConfig() }
        .onChange(of: autoCloudFirst) { _, _ in saveAIConfig() }
        .onChange(of: cloudHash) { _, _ in onCloudChanged() }
        .onChange(of: localHash) { _, _ in onLocalChanged() }
        .onChange(of: debtHash) { _, _ in saveReplyDebtAIConfig() }
        .onChange(of: togglesHash) { _, _ in saveAIToggles() }
        .onChange(of: notifyHash) { _, _ in saveNotificationConfig() }
    }

    private func onCloudChanged() {
        guard didLoad else { return }
        // Auto-fill fields when preset is selected
        if let p = AIProvider.find(cloudProviderID), cloudProviderID != "custom",
           cloudBaseURL != p.baseURL {
            cloudBaseURL = p.baseURL
            if !p.models.contains(cloudModel) { cloudModel = p.models.first ?? "" }
        }
        saveAIConfig()
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

    // MARK: - Body sub-views

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("运行模式")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("", selection: $activeMode) {
                Text("仅本地").tag(AIActiveMode.local)
                Text("仅线上").tag(AIActiveMode.cloud)
                Text("自动 (失败自动切换)").tag(AIActiveMode.auto)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            if activeMode == .auto {
                HStack(spacing: 8) {
                    Text("优先使用").font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("", selection: $autoCloudFirst) {
                        Text("线上优先").tag(true)
                        Text("本地优先").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            if showSaved {
                Text("已保存")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
    }

    private var cloudSection: some View {
        providerSection(
            title: "线上服务", icon: "cloud.fill", tint: .blue,
            isActive: activeMode == .cloud || activeMode == .auto,
            providerID: $cloudProviderID, baseURL: $cloudBaseURL,
            model: $cloudModel, apiKey: $cloudApiKey,
            testResult: $cloudTestResult, isTesting: $cloudTesting,
            filterLocal: false
        )
    }

    private var localSection: some View {
        providerSection(
            title: "本地服务", icon: "desktopcomputer", tint: .green,
            isActive: activeMode == .local || activeMode == .auto,
            providerID: $localProviderID, baseURL: $localBaseURL,
            model: $localModel, apiKey: $localApiKey,
            testResult: $localTestResult, isTesting: $localTesting,
            filterLocal: true
        )
    }

    private var testAndTogglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("启用待回 AI 判定", isOn: $replyDebtAIEnabled)
            Toggle("仅 Shadow Mode（只记录差异，不改排序）", isOn: $replyDebtShadowMode)
                .disabled(!replyDebtAIEnabled)
        }
        .toggleStyle(.switch)
        .font(.system(size: 12))
    }

    private var butlerBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("管家行为").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("消息摘要分析", isOn: $summaryEnabled).font(.system(size: 12))
                Text("为每条消息生成 AI 摘要，替代原始消息预览。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Toggle("回复建议", isOn: $suggestionsEnabled).font(.system(size: 12))
                Text("展开消息时提供 AI 回复建议。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Toggle("情绪检测", isOn: $moodDetectionEnabled).font(.system(size: 12))
                Text("为 VIP 联系人检测消息情绪。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .toggleStyle(.switch).padding(.top, 4)
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("通知过滤").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("群聊 @提及", isOn: $notifyAtMention).font(.system(size: 12))
                Toggle("VIP 消息", isOn: $notifyVIP).font(.system(size: 12))
                Toggle("所有白名单消息", isOn: $notifyWhitelist).font(.system(size: 12))
                HStack {
                    Text("提醒时长").font(.system(size: 12))
                    Picker("", selection: $notifyDuration) {
                        Text("2秒").tag(2)
                        Text("3秒").tag(3)
                        Text("5秒").tag(5)
                    }
                    .pickerStyle(.segmented).frame(width: 150)
                }
            }
            .toggleStyle(.switch).padding(.top, 4)
        }
    }

    // MARK: - Provider section

    @ViewBuilder
    private func providerSection(
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

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if isActive {
                    Text("使用中")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(tint).cornerRadius(3)
                }
                Spacer()
                // Per-card test button
                Button(action: {
                    testSlot(
                        providerID: providerID.wrappedValue,
                        baseURL: baseURL.wrappedValue,
                        model: model.wrappedValue,
                        apiKey: apiKey.wrappedValue,
                        result: testResult, testing: isTesting
                    )
                }) {
                    HStack(spacing: 4) {
                        if isTesting.wrappedValue {
                            ProgressView().scaleEffect(0.5)
                        }
                        Text(isTesting.wrappedValue ? "测试中" : "测试")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered).controlSize(.mini).disabled(isTesting.wrappedValue)
                if !testResult.wrappedValue.isEmpty {
                    Circle()
                        .fill(testResult.wrappedValue.contains("OK") ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                        .help(testResult.wrappedValue)
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: providerID) {
                    ForEach(providers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: 260)

                if let p = provider, !p.signupURL.isEmpty {
                    Button {
                        if let u = URL(string: p.signupURL) { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "key.fill").font(.system(size: 9))
                            Text("获取 Key").font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }

            if isCustom {
                settingsField("API 地址", text: baseURL)
            } else if let p = provider {
                HStack(spacing: 4) {
                    Text("地址").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(p.baseURL)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.6)).lineLimit(1)
                }
            }

            modelField(model: model, presets: provider?.models ?? [])

            if provider?.requiresKey == true || isCustom {
                settingsField("API Key", text: apiKey, isSecure: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? tint.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? tint.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func modelField(model: Binding<String>, presets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模型").font(.system(size: 11)).foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField("输入模型名称", text: model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 240)
                if !presets.isEmpty {
                    Menu {
                        ForEach(presets, id: \.self) { name in
                            Button(name) { model.wrappedValue = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }
        }
    }

    private func settingsField(_ label: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            if isSecure {
                SecureField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
            } else {
                TextField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
        }
    }

    private func testSlot(
        providerID: String, baseURL: String, model: String, apiKey: String,
        result: Binding<String>, testing: Binding<Bool>
    ) {
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
    }

    // MARK: - Load / Save

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

        if let rdCfg = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self) {
            replyDebtAIEnabled = rdCfg.enabled
            replyDebtShadowMode = rdCfg.shadowMode
        }

        summaryEnabled = cfg.summaryEnabled
        suggestionsEnabled = cfg.suggestionsEnabled
        moodDetectionEnabled = cfg.moodDetectionEnabled

        let notifCfg = store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
        notifyAtMention = notifCfg.atMention
        notifyVIP = notifCfg.important
        notifyWhitelist = notifCfg.allWhitelist
        notifyDuration = notifCfg.durationSeconds

        reloadRecentReplyDebtAudit()
        reloadRecentGroupContextAudit()
        reloadReplyDebtFeedback()
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
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    private func saveReplyDebtAIConfig() {
        guard didLoad else { return }
        var cfg = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self) ?? ReplyDebtAIConfig()
        cfg.enabled = replyDebtAIEnabled
        cfg.shadowMode = replyDebtShadowMode
        try? store.setSettingJSON("replyDebtAI", value: cfg)
        NotificationCenter.default.post(name: .hudReplyDebtAIConfigDidChange, object: nil)
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
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

    // MARK: - Audit sections

    @ViewBuilder
    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待回 AI 审计").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("刷新") { reloadRecentReplyDebtAudit() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.blue)
            }
            if recentReplyDebtAudit.isEmpty {
                Text("最近还没有待回 AI 审计记录。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentReplyDebtAudit, id: \.id) { entry in
                        auditRow(entry, showFeedback: true)
                    }
                }
            }
        }

        Divider()
    }

    @ViewBuilder
    private var groupContextAuditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("群聊上下文 AI 审计").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("刷新") { reloadRecentGroupContextAudit() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.blue)
            }
            if recentGroupContextAudit.isEmpty {
                Text("最近还没有群聊上下文简报记录。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentGroupContextAudit, id: \.id) { entry in
                        auditRow(entry, showFeedback: false)
                    }
                }
            }
        }
    }

    private func auditRow(_ entry: AIAuditEntry, showFeedback: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.auditTimestampFormatter.string(from: entry.ts))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Text(auditStatusLabel(entry))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(auditStatusColor(entry).opacity(0.15))
                    .foregroundColor(auditStatusColor(entry)).cornerRadius(4)
                Text(entry.model)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Text(auditSummary(entry))
                .font(.system(size: 11)).foregroundColor(.primary).lineLimit(2)

            if showFeedback && entry.status == .ok {
                HStack(spacing: 6) {
                    feedbackButton(title: "正确", type: .truePositive, entry: entry)
                    feedbackButton(title: "误判", type: .falsePositive, entry: entry)
                    Spacer()
                    if let fb = replyDebtFeedbackByKey[feedbackKey(for: entry)] {
                        Text(feedbackLabel(fb))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(feedbackColor(fb))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if !recentReplyDebtFeedbackWindow.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("近 7 天反馈").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    feedbackStatPill(title: "正确", value: feedbackStats.correct, color: .green)
                    feedbackStatPill(title: "误判", value: feedbackStats.incorrect, color: .orange)
                    feedbackStatPill(title: "准确率", value: feedbackStats.accuracyText, color: .blue)
                }
                if !recentFalsePositives.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近误判").font(.system(size: 11)).foregroundColor(.secondary)
                        ForEach(Array(recentFalsePositives.prefix(3)), id: \.id) { fb in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.auditTimestampFormatter.string(from: fb.ts))
                                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                Text(fb.note ?? "无摘要")
                                    .font(.system(size: 11)).foregroundColor(.primary).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reload helpers

    private func reloadRecentReplyDebtAudit() {
        recentReplyDebtAudit = store.loadRecentAIAudit(limit: 8, role: .ranker, promptVersionPrefix: "reply_debt_")
    }
    private func reloadRecentGroupContextAudit() {
        recentGroupContextAudit = store.loadRecentAIAudit(limit: 6, role: .retrospector, promptVersionPrefix: "group_context_")
    }
    private func reloadReplyDebtFeedback() {
        recentReplyDebtFeedback = store.loadAIFeedback(limit: 200, msgUIDPrefix: replyDebtFeedbackPrefix)
        replyDebtFeedbackByKey = store.loadLatestAIFeedbackByMsgUID(limit: 200, msgUIDPrefix: replyDebtFeedbackPrefix)
    }

    // MARK: - Audit formatting

    private func auditStatusLabel(_ entry: AIAuditEntry) -> String {
        switch entry.status {
        case .ok: return entry.promptVersion.contains("reply_debt") ? "OK" : entry.status.rawValue.uppercased()
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

    // MARK: - Feedback

    private func feedbackButton(title: String, type: AIFeedbackType, entry: AIAuditEntry) -> some View {
        let selected = replyDebtFeedbackByKey[feedbackKey(for: entry)]?.feedbackType == type
        return Button(title) { writeFeedback(type: type, for: entry) }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(selected ? feedbackColor(type).opacity(0.75) : Color.gray.opacity(0.15))
            .cornerRadius(4)
    }

    private func writeFeedback(type: AIFeedbackType, for entry: AIAuditEntry) {
        let snapshot = ReplyDebtAuditFeedbackSnapshot(
            auditID: entry.id, model: entry.model, promptVersion: entry.promptVersion,
            status: entry.status.rawValue, outputText: entry.outputText, summary: auditSummary(entry)
        )
        let payloadData = try? JSONEncoder().encode(snapshot)
        let payload = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? entry.outputText
        let feedback = AIFeedbackEntry(
            id: 0, ts: Date(), msgUID: feedbackKey(for: entry), feedbackType: type,
            originalOutput: payload, userAction: type == .truePositive ? "confirmed_audit" : "rejected_audit",
            note: auditSummary(entry)
        )
        try? store.writeAIFeedback(feedback)
        reloadReplyDebtFeedback()
    }

    private func feedbackKey(for entry: AIAuditEntry) -> String { "\(replyDebtFeedbackPrefix)\(entry.id)" }

    private func feedbackLabel(_ fb: AIFeedbackEntry) -> String {
        switch fb.feedbackType {
        case .truePositive: return "已标记: 正确"
        case .falsePositive: return "已标记: 误判"
        case .trueNegative: return "已标记: 无需处理"
        case .falseNegative: return "已标记: 漏判"
        }
    }
    private func feedbackColor(_ fb: AIFeedbackEntry) -> Color { feedbackColor(fb.feedbackType) }
    private func feedbackColor(_ type: AIFeedbackType) -> Color {
        switch type {
        case .truePositive, .trueNegative: return .green
        case .falsePositive, .falseNegative: return .orange
        }
    }

    private func feedbackStatPill(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) { Text(title); Text("\(value)").monospacedDigit() }
            .font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12)).cornerRadius(4)
    }
    private func feedbackStatPill(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) { Text(title); Text(value).monospacedDigit() }
            .font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12)).cornerRadius(4)
    }

    private var recentReplyDebtFeedbackWindow: [AIFeedbackEntry] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return recentReplyDebtFeedback.filter { $0.ts >= cutoff }
    }
    private var recentFalsePositives: [AIFeedbackEntry] {
        recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .falsePositive }
    }
    private var feedbackStats: (correct: Int, incorrect: Int, accuracyText: String) {
        let correct = recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .truePositive }.count
        let incorrect = recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .falsePositive }.count
        let total = correct + incorrect
        let accuracy = total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
        return (correct, incorrect, "\(accuracy)%")
    }

    private static let auditTimestampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
    private static let replyDebtFeedbackPrefix = "reply_debt_audit:"
    private var replyDebtFeedbackPrefix: String { Self.replyDebtFeedbackPrefix }
}

private struct ReplyDebtAuditFeedbackSnapshot: Encodable {
    let auditID: Int64
    let model: String
    let promptVersion: String
    let status: String
    let outputText: String
    let summary: String
}
