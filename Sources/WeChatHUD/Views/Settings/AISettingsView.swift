import SwiftUI

extension Notification.Name {
    static let hudAIConfigDidChange = Notification.Name("WeChatHUD.AIConfigDidChange")
    static let hudSwitchTab = Notification.Name("WeChatHUD.SwitchTab")
}

// MARK: - Model Picker (searchable expandable list)

struct ModelPicker: View {
    @Binding var model: String
    let models: [String]
    let isFetching: Bool
    let onRefresh: () -> Void

    @State private var searchText = ""
    @State private var isExpanded = false
    @FocusState private var searchFocused: Bool

    var filtered: [String] {
        if searchText.isEmpty { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("模型", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                Button(action: onRefresh) {
                    if isFetching {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .help("从接口获取模型列表")
                .disabled(isFetching)

                if !models.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isExpanded, !models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("搜索模型…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($searchFocused)
                        .onAppear { searchFocused = true }

                    ScrollViewReader { proxy in
                        List(filtered, id: \.self, selection: .constant(model)) { m in
                            Text(m)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .padding(.vertical, 2)
                                .tag(m)
                                .id(m)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model = m
                                    isExpanded = false
                                }
                        }
                        .listStyle(.plain)
                        .frame(height: min(CGFloat(filtered.count) * 24 + 8, 180))
                        .onChange(of: model) { _, new in
                            withAnimation { proxy.scrollTo(new, anchor: .center) }
                        }
                    }
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    let title: String
    let icon: String
    let tint: Color
    let isActive: Bool

    @Binding var providerID: String
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var apiKey: String
    @Binding var models: [String]
    @Binding var testResult: String
    @Binding var isTesting: Bool
    @Binding var isFetching: Bool

    let onTest: () -> Void
    let onFetch: () -> Void
    let onChange: () -> Void
    let filterLocal: Bool

    private var isCustom: Bool { providerID == "custom" }
    private var provider: AIProvider? { AIProvider.find(providerID) }
    private var providers: [AIProvider] {
        let all = AIProvider.builtIn
        if filterLocal {
            return all.filter { $0.id == "ollama" || $0.id == "custom" }
        } else {
            return all.filter { $0.id != "ollama" }
        }
    }

    var body: some View {
        SettingsSection(title) {
            // Status row
            SettingsRow("状态", icon: icon, iconColor: tint) {
                HStack(spacing: 8) {
                    StatusBadge(text: isActive ? "使用中" : "未激活", color: isActive ? tint : .secondary)
                    testButton
                }
            }

            SettingsRowDivider()

            // Provider picker
            SettingsRow("供应商") {
                HStack(spacing: 6) {
                    Picker("", selection: $providerID) {
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

            // Base URL (custom only)
            if isCustom {
                SettingsRowDivider()
                SettingsRow("API 地址") {
                    TextField("https://...", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 220)
                }
            }

            // API Key
            if provider?.requiresKey == true || isCustom {
                SettingsRowDivider()
                SettingsRow("API Key") {
                    SecureField("", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 220)
                }
            }

            // Model picker with live fetch + search
            SettingsRowDivider()
            SettingsRow("模型") {
                ModelPicker(
                    model: $model,
                    models: models,
                    isFetching: isFetching,
                    onRefresh: onFetch
                )
                .frame(maxWidth: 280)
            }
        }
        .onChange(of: providerID) { _, _ in syncProviderPreset() }
    }

    private var testButton: some View {
        HStack(spacing: 4) {
            if !testResult.isEmpty {
                Circle()
                    .fill(testResult.contains("OK") ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .help(testResult)
            }
            Button(action: onTest) {
                if isTesting {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                } else {
                    Text("测试").font(.system(size: 10))
                }
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(isTesting)
        }
    }

    private func syncProviderPreset() {
        guard let p = provider, providerID != "custom" else {
            onChange()
            return
        }
        if baseURL != p.baseURL {
            baseURL = p.baseURL
            apiKey = ""
            testResult = "已切换供应商，请填写对应 API Key"
        }
        models = p.models
        if model.isEmpty || !p.models.contains(model) {
            model = p.models.first ?? ""
        }
        onChange()
    }
}

// MARK: - Main View

struct AISettingsView: View {
    @EnvironmentObject private var store: HUDStore

    // Global
    @State private var activeMode: AIActiveMode = .cloud
    @State private var autoCloudFirst: Bool = true
    @State private var maxTokens: Double = 4096
    @State private var temperature: Double = 0.3
    @State private var thinkingEnabled: Bool = false

    // Cloud slot
    @State private var cloudProviderID = "deepseek"
    @State private var cloudBaseURL = ""
    @State private var cloudModel = ""
    @State private var cloudApiKey = ""
    @State private var cloudModels: [String] = []
    @State private var cloudTestResult = ""
    @State private var cloudTesting = false
    @State private var cloudFetching = false

    // Local slot
    @State private var localProviderID = "custom"
    @State private var localBaseURL = ""
    @State private var localModel = ""
    @State private var localApiKey = ""
    @State private var localModels: [String] = []
    @State private var localTestResult = ""
    @State private var localTesting = false
    @State private var localFetching = false

    // Behavior
    @State private var summaryEnabled = true
    @State private var suggestionsEnabled = true
    @State private var moodDetectionEnabled = true
    @State private var dailyReportActionInsightsEnabled = true

    @State private var didLoad = false
    @State private var isHydrating = false
    @State private var saveError = ""

    // Debounce helpers
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topControls
                cloudCard
                localCard
                behaviorSection
                if !saveError.isEmpty {
                    Text(saveError)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                }
                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .onAppear(perform: load)
    }

    // MARK: - Top Controls

    private var topControls: some View {
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

            SettingsRowDivider()
            SettingsToggleRow("思考模式 (Thinking)", subtitle: "允许模型输出推理链（DeepSeek / Kimi / Qwen）", isOn: $thinkingEnabled)

            SettingsRowDivider()
            HStack(spacing: 16) {
                SettingsRow("Max Tokens") {
                    HStack(spacing: 4) {
                        Slider(value: $maxTokens, in: 512...8192, step: 512)
                            .frame(width: 100)
                        Text("\(Int(maxTokens))")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                SettingsRow("Temperature") {
                    HStack(spacing: 4) {
                        Slider(value: $temperature, in: 0...1, step: 0.1)
                            .frame(width: 100)
                        Text(String(format: "%.1f", temperature))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onChange(of: activeMode) { _, _ in debouncedSave() }
        .onChange(of: autoCloudFirst) { _, _ in debouncedSave() }
        .onChange(of: thinkingEnabled) { _, _ in debouncedSave() }
        .onChange(of: maxTokens) { _, _ in debouncedSave() }
        .onChange(of: temperature) { _, _ in debouncedSave() }
    }

    // MARK: - Cards

    private var cloudCard: some View {
        let isActive = activeMode == .cloud || activeMode == .auto
        return ProviderCard(
            title: "线上服务",
            icon: "cloud.fill",
            tint: .blue,
            isActive: isActive,
            providerID: $cloudProviderID,
            baseURL: $cloudBaseURL,
            model: $cloudModel,
            apiKey: $cloudApiKey,
            models: $cloudModels,
            testResult: $cloudTestResult,
            isTesting: $cloudTesting,
            isFetching: $cloudFetching,
            onTest: { testSlot(cloud: true) },
            onFetch: { fetchModels(cloud: true) },
            onChange: { debouncedSave() },
            filterLocal: false
        )
        .onChange(of: cloudBaseURL) { _, _ in debouncedSave() }
        .onChange(of: cloudModel) { _, _ in debouncedSave() }
        .onChange(of: cloudApiKey) { _, _ in debouncedSave() }
    }

    private var localCard: some View {
        let isActive = activeMode == .local || activeMode == .auto
        return ProviderCard(
            title: "本地服务",
            icon: "desktopcomputer",
            tint: .green,
            isActive: isActive,
            providerID: $localProviderID,
            baseURL: $localBaseURL,
            model: $localModel,
            apiKey: $localApiKey,
            models: $localModels,
            testResult: $localTestResult,
            isTesting: $localTesting,
            isFetching: $localFetching,
            onTest: { testSlot(cloud: false) },
            onFetch: { fetchModels(cloud: false) },
            onChange: { debouncedSave() },
            filterLocal: true
        )
        .onChange(of: localBaseURL) { _, _ in debouncedSave() }
        .onChange(of: localModel) { _, _ in debouncedSave() }
        .onChange(of: localApiKey) { _, _ in debouncedSave() }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection("管家行为") {
            SettingsToggleRow("消息摘要", subtitle: "AI 生成摘要替代原始预览", isOn: $summaryEnabled)
            SettingsRowDivider()
            SettingsToggleRow("回复建议", subtitle: "展开消息时提供 AI 回复建议", isOn: $suggestionsEnabled)
            SettingsRowDivider()
            SettingsToggleRow("情绪检测", subtitle: "为 VIP 联系人检测消息情绪", isOn: $moodDetectionEnabled)
            SettingsRowDivider()
            SettingsToggleRow("日报逐条 AI 注释", subtitle: "为紧急待处理行生成 AI 一句解释 + 下一步建议", isOn: $dailyReportActionInsightsEnabled)
        }
        .onChange(of: summaryEnabled) { _, _ in debouncedSave() }
        .onChange(of: suggestionsEnabled) { _, _ in debouncedSave() }
        .onChange(of: moodDetectionEnabled) { _, _ in debouncedSave() }
        .onChange(of: dailyReportActionInsightsEnabled) { _, _ in debouncedSave() }
    }

    // MARK: - Actions

    private func testSlot(cloud: Bool) {
        let slot = buildSlot(cloud: cloud)
        let cfg = buildConfig()
        let service = AIService(config: cfg)
        if cloud {
            cloudTesting = true
            cloudTestResult = ""
        } else {
            localTesting = true
            localTestResult = ""
        }
        Task {
            do {
                let text = try await service.testSlot(slot)
                await MainActor.run {
                    if cloud {
                        cloudTestResult = "OK: \(text.prefix(20))"
                        cloudTesting = false
                    } else {
                        localTestResult = "OK: \(text.prefix(20))"
                        localTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    if cloud {
                        cloudTestResult = "失败: \(error.localizedDescription.prefix(60))"
                        cloudTesting = false
                    } else {
                        localTestResult = "失败: \(error.localizedDescription.prefix(60))"
                        localTesting = false
                    }
                }
            }
        }
    }

    private func fetchModels(cloud: Bool) {
        let slot = buildSlot(cloud: cloud)
        if cloud {
            cloudFetching = true
        } else {
            localFetching = true
        }
        let service = AIService(config: buildConfig())
        Task {
            do {
                let list = try await service.fetchModels(slot: slot)
                await MainActor.run {
                    if cloud {
                        cloudModels = list
                        cloudFetching = false
                        // If current model not in list, keep it but notify via test result
                        if !list.isEmpty, !list.contains(cloudModel) {
                            cloudTestResult = "已获取 \(list.count) 个模型"
                        }
                    } else {
                        localModels = list
                        localFetching = false
                        if !list.isEmpty, !list.contains(localModel) {
                            localTestResult = "已获取 \(list.count) 个模型"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if cloud {
                        cloudTestResult = "获取失败: \(error.localizedDescription.prefix(60))"
                        cloudFetching = false
                    } else {
                        localTestResult = "获取失败: \(error.localizedDescription.prefix(60))"
                        localFetching = false
                    }
                }
            }
        }
    }

    // MARK: - Config builders

    private func buildSlot(cloud: Bool) -> AIProviderSlot {
        if cloud {
            return AIProviderSlot(
                providerID: cloudProviderID,
                baseURL: resolvedURL(providerID: cloudProviderID, baseURL: cloudBaseURL),
                model: cloudModel,
                apiKey: cloudApiKey
            )
        } else {
            return AIProviderSlot(
                providerID: localProviderID,
                baseURL: resolvedURL(providerID: localProviderID, baseURL: localBaseURL),
                model: localModel,
                apiKey: localApiKey
            )
        }
    }

    private func buildConfig() -> AIConfig {
        var cfg = store.loadAIConfig()
        cfg.activeMode = activeMode
        cfg.autoCloudFirst = autoCloudFirst
        cfg.thinkingEnabled = thinkingEnabled
        cfg.maxTokens = Int(maxTokens)
        cfg.temperature = temperature
        cfg.cloudProvider = buildSlot(cloud: true)
        cfg.localProvider = buildSlot(cloud: false)
        cfg.summaryEnabled = summaryEnabled
        cfg.suggestionsEnabled = suggestionsEnabled
        cfg.moodDetectionEnabled = moodDetectionEnabled
        cfg.dailyReportActionInsightsEnabled = dailyReportActionInsightsEnabled
        return cfg
    }

    private func resolvedURL(providerID: String, baseURL: String) -> String {
        if providerID == "custom" { return baseURL }
        return AIProvider.find(providerID)?.baseURL ?? baseURL
    }

    // MARK: - Persistence

    private func debouncedSave() {
        guard didLoad, !isHydrating else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            await MainActor.run {
                saveAIConfig()
            }
        }
    }

    private func saveAIConfig() {
        guard didLoad, !isHydrating else { return }
        let cfg = buildConfig()
        do {
            try store.setSettingJSON("ai", value: cfg)
            saveError = ""
            NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
        } catch {
            saveError = "AI 配置保存失败: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard !didLoad else { return }
        isHydrating = true

        let cfg = store.loadAIConfig()
        activeMode = cfg.activeMode
        autoCloudFirst = cfg.autoCloudFirst
        thinkingEnabled = cfg.thinkingEnabled
        maxTokens = Double(cfg.maxTokens)
        temperature = cfg.temperature

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
        dailyReportActionInsightsEnabled = cfg.dailyReportActionInsightsEnabled

        // Seed built-in presets for models
        if let cp = AIProvider.find(cloudProviderID) {
            cloudModels = cp.models
        }
        if let lp = AIProvider.find(localProviderID) {
            localModels = lp.models
        }

        // Auto-fetch from remote if key present (non-blocking)
        if !cloudApiKey.isEmpty, cloudProviderID != "openai-codex" {
            fetchModels(cloud: true)
        }
        if !localApiKey.isEmpty, localProviderID != "openai-codex" {
            fetchModels(cloud: false)
        }

        didLoad = true
        DispatchQueue.main.async {
            isHydrating = false
        }
    }
}

// MARK: - Helpers

struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color)
            .cornerRadius(3)
    }
}
