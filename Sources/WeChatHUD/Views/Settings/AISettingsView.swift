import SwiftUI

/// Promises for the AI service page. The first thing on this screen is
/// whether the service can be used, not a vendor picker.
enum AISettingsCopy {
    static let confirmWorks = "确认能用"
    static let notReady = "还不能用"
    static let unverified = "还没确认能不能用"
    static let ready = "可以用"
    static let statusHint = "改完会自动保存。相关聊天会发给这个服务来写摘要和草稿。"
    static let sourceTitle = "用哪家"
    static let sourcePreset = "常用服务"
    static let sourceCustom = "自己填"
    static let vendorTitle = "哪一家"
    static let addressTitle = "接到哪"
    static let secretTitle = "密钥"
    static let getKey = "去拿密钥"
    static let modelTitle = "用哪个模型"
    static let noModel = "还没选模型"
    static let refreshModels = "重新获取可用模型"
    static let needSecret = "请补上这台服务的密钥。"
    static let needAddress = "请填一个能用的地址。"
    static let pickModel = "请选一个模型。"
    static let checkAgain = "请核对地址、模型和密钥，再点「确认能用」。"
    static let codexHint = "用这台 Mac 上已登录的 ChatGPT，不必再填密钥。"
}

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

    var filtered: [String] {
        if searchText.isEmpty { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CompanionClipboardField(
                    text: $model,
                    placeholder: AISettingsCopy.modelTitle,
                    kind: .model,
                    monospaced: true,
                    accessibilityLabel: AISettingsCopy.modelTitle
                )

                Button(action: onRefresh) {
                    if isFetching {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.borderless)
                .help(AISettingsCopy.refreshModels)
                .accessibilityLabel(AISettingsCopy.refreshModels)
                .disabled(isFetching)

                if !models.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "收起模型列表" : "展开模型列表")
                }
            }

            if isExpanded, !models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CompanionClipboardField(
                        text: $searchText,
                        placeholder: "搜索模型…",
                        kind: .plain,
                        accessibilityLabel: "搜索模型"
                    )

                    ScrollViewReader { proxy in
                        List(filtered, id: \.self, selection: Binding<String?>(
                            get: { model },
                            set: { if let selected = $0 { model = selected } }
                        )) { m in
                            Text(m)
                                .font(.system(size: 13))
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
                        .onKeyPress(.return) { isExpanded = false; return .handled }
                        .onKeyPress(.escape) { isExpanded = false; return .handled }
                        .frame(height: min(CGFloat(filtered.count) * 24 + 8, 180))
                        .onChange(of: model) { _, new in
                            withMotion(CompanionMotion.systemDefault) { proxy.scrollTo(new, anchor: .center) }
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
    let isCustomSource: Bool

    @Binding var providerID: String
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var apiKey: String
    @Binding var models: [String]
    @Binding var testResult: String
    @Binding var isTesting: Bool
    @Binding var isFetching: Bool

    let onFetch: () -> Void
    let onProviderSelected: (String) -> Void

    @State private var advancedConnectionExpanded = false
    /// The preset id `syncProviderPreset` last aligned to. Switching to a
    /// *different* preset must drop the key even when the URL matches (two
    /// presets can share an address with different keys); re-syncing the same
    /// preset keeps it (otherwise two ordinary clicks silently empty a working
    /// credential). Nil until the first sync so hydration never wipes.
    @State private var lastSyncedPresetID: String?

    private var usesUnencryptedRemoteHTTP: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }
    private var provider: AIProvider? { AIProvider.find(providerID) }
    private var presetProviders: [AIProvider] {
        AIProvider.builtIn.filter { $0.id != "custom" }
    }

    var body: some View {
        Group {
            if !isCustomSource {
                SettingsRow(AISettingsCopy.vendorTitle) {
                    Picker(AISettingsCopy.vendorTitle, selection: Binding(get: { providerID }, set: { value in
                        providerID = value
                        syncProviderPreset()
                        onProviderSelected(value)
                    })) {
                        ForEach(presetProviders) { p in Text(p.name).tag(p.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                SettingsRowDivider()
                // Preset vendors own their service address; show it read-only.
                SettingsRow(AISettingsCopy.addressTitle) {
                    if hasPresetBaseURL {
                        CompanionClipboardField(
                            text: $baseURL,
                            kind: .url,
                            writable: false,
                            monospaced: true,
                            accessibilityLabel: AISettingsCopy.addressTitle
                        )
                        .frame(maxWidth: 240)
                    } else {
                        CompanionCopyableText(text: AISettingsCopy.codexHint)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                DisclosureGroup("高级连接设置", isExpanded: $advancedConnectionExpanded) {
                    SettingsRowDivider()
                    SettingsRow(AISettingsCopy.addressTitle) {
                        VStack(alignment: .leading, spacing: 5) {
                            CompanionClipboardField(
                                text: $baseURL,
                                placeholder: AISettingsCopy.addressTitle,
                                kind: .url,
                                accessibilityLabel: AISettingsCopy.addressTitle
                            )
                            .frame(maxWidth: 220)
                            if usesUnencryptedRemoteHTTP {
                                Text("此连接未加密，请确认网络可信或改用安全连接")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .tint(CompanionPalette.accent)
            }

            // Access credential — only for providers that require a key
            if isCustomSource || provider?.requiresKey == true {
                SettingsRowDivider()
                SettingsRow(AISettingsCopy.secretTitle) {
                    HStack(spacing: 8) {
                        CompanionClipboardField(
                            text: $apiKey,
                            kind: .secret,
                            secure: true,
                            accessibilityLabel: AISettingsCopy.secretTitle
                        )
                        .frame(maxWidth: 220)
                        if !isCustomSource, provider?.requiresKey == true, let signup = provider?.signupURL, !signup.isEmpty {
                            Button(AISettingsCopy.getKey) {
                                if let u = URL(string: signup) { NSWorkspace.shared.open(u) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityLabel(AISettingsCopy.getKey)
                        }
                    }
                }
            }

            if providerID == "openai-codex" {
                Text(AISettingsCopy.codexHint)
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(14)
            }

            // Model picker with live fetch + search
            SettingsRowDivider()
            SettingsRow(AISettingsCopy.modelTitle) {
                ModelPicker(
                    model: $model,
                    models: models,
                    isFetching: isFetching || isTesting,
                    onRefresh: onFetch
                )
                .frame(maxWidth: 280)
            }
            if !testResult.isEmpty {
                SettingsRowDivider()
                if isFailedTestResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("连接没有通过", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        CompanionCopyableText(text: testResult, lineLimit: nil)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AISettingsCopy.checkAgain)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(14)
                } else {
                    CompanionCopyableText(text: testResult, lineLimit: nil)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }

    }

    private var hasPresetBaseURL: Bool {
        !(provider?.baseURL.isEmpty ?? true)
    }

    private var isFailedTestResult: Bool {
        testResult.hasPrefix("失败") || testResult.hasPrefix("连接未完成") || testResult.hasPrefix("获取失败") || testResult.hasPrefix("上次测试失败")
    }

    private func syncProviderPreset() {
        testResult = ""
        guard let preset = provider, !isCustomSource else { return }
        defer { lastSyncedPresetID = preset.id }
        guard let previous = lastSyncedPresetID else {
            // First sync after hydration: align address/models, never touch
            // the key the user already has saved.
            if baseURL != preset.baseURL { baseURL = preset.baseURL }
            models = preset.models
            if model.isEmpty || !preset.models.contains(model) {
                model = preset.models.first ?? ""
            }
            return
        }
        if preset.id != previous {
            // Different service: the address follows the preset and the old
            // key must not linger, even when the URL is identical.
            baseURL = preset.baseURL
            apiKey = ""
        } else if baseURL != preset.baseURL {
            baseURL = preset.baseURL
            apiKey = ""
        }
        models = preset.models
        if model.isEmpty || !preset.models.contains(model) {
            model = preset.models.first ?? ""
        }
    }
}

// MARK: - Main View

private enum AISettingsSection: String, CaseIterable, Identifiable {
    case analysis = "分析与建议"
    case notifications = "提醒方式"
    case service = "AI 服务"

    var id: String { rawValue }
}

struct AISettingsView: View {
    enum ServiceSource: Hashable {
        case preset
        case custom
    }

    @EnvironmentObject private var store: HUDStore

    // Global
    @State private var maxTokens: Double = 2048
    @State private var temperature: Double = 0.3
    @State private var thinkingEnabled: Bool = false

    // Provider (single slot). serviceSource is local UI state only; the
    // persisted config stores just the final provider slot.
    @State private var serviceSource: ServiceSource = .preset
    @State private var lastPresetProviderID = "kimicode"
    @State private var providerID = "kimicode"
    @State private var baseURL = "https://api.kimi.com/coding/v1"
    @State private var model = "kimi-for-coding"
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var isFetching = false
    @State private var testRequestID = UUID()

    // Behavior
    @State private var summaryEnabled = true
    @State private var suggestionsEnabled = true
    @State private var moodDetectionEnabled = true
    @State private var dailyReportActionInsightsEnabled = true

    @State private var didLoad = false
    @State private var isHydrating = false
    @State private var saveError = ""
    @State private var hasPendingSave = false
    @State private var savedAt: Date?
    @State private var preferencesExpanded = false
    @State private var privacyExpanded = false
    @State private var selectedSection: AISettingsSection?
    private let lockedSection: AISettingsSection?

    init(section: String? = nil) {
        switch section {
        case "analysis": lockedSection = .analysis
        case "notifications": lockedSection = .notifications
        case "service": lockedSection = .service
        default: lockedSection = nil
        }
    }

    // Debounce helpers
    @State private var saveTask: Task<Void, Never>?

    /// One way to reach the "AI 服务" section. Setting `selectedSection`
    /// alone only moves an unlocked page: `SettingsView` always passes a
    /// `section`, so `selectedSection` is otherwise ignored and the tab
    /// switch is what the user actually sees.
    private func switchToAIServiceTab() {
        selectedSection = .service
        NotificationCenter.default.post(name: .hudSwitchTab, object: "aiService")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if lockedSection != .analysis && lockedSection != .notifications {
                    serviceStatusCard
                }
                if lockedSection == nil { sectionPicker }
                switch lockedSection ?? selectedSection ?? .service {
                case .analysis:
                    analysisSection
                case .notifications:
                    NotificationSettingsView()
                case .service:
                    serviceSection
                }
                saveStatus
                Spacer(minLength: 20)
            }
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .hudPreviewAITestFailure)) { _ in
            applyPreviewTestFailure()
        }
        .onDisappear {
            saveTask?.cancel()
            if hasPendingSave { saveAIConfig() }
        }
    }

    // MARK: - Current service

    private var configuredSlot: AIProviderSlot {
        buildSlot()
    }

    private var activeProviderName: String {
        AIProvider.find(configuredSlot.providerID)?.name ?? (configuredSlot.providerID == "custom" ? "自定义服务" : configuredSlot.providerID)
    }

    private var activeServiceStatus: (label: String, color: Color, icon: String) {
        guard AISettingsValidation.connectionError(configuredSlot, requireModel: true) == nil else {
            return ("未配置", .secondary, "circle.dashed")
        }
        if AIConnectionEvidenceStore.isSuccessful(buildConfig(), store: store) {
            return ("已验证", CompanionPalette.accent, "checkmark.circle.fill")
        }
        return ("未验证", .orange, "exclamationmark.circle")
    }

    private var serviceUsabilityTitle: String {
        switch activeServiceStatus.label {
        case "未配置": return AISettingsCopy.notReady
        case "已验证": return AISettingsCopy.ready
        default: return AISettingsCopy.unverified
        }
    }

    private var serviceStatusCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(serviceUsabilityTitle)
                    .workspaceTitle()
                let summary = "\(activeProviderName) · \(configuredSlot.model.isEmpty ? AISettingsCopy.noModel : configuredSlot.model)"
                Text(summary)
                    .workspaceBody()
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制") { CompanionClipboard.write(summary) }
                    }
                Text(AISettingsCopy.statusHint)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            Button(action: testSlot) {
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 18, height: 18)
                } else {
                    Text(AISettingsCopy.confirmWorks)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(CompanionPalette.jade)
            .disabled(isTesting || isFetching)
            .accessibilityLabel(AISettingsCopy.confirmWorks)
        }
        .companionSurface(padding: 20)
    }

    private var sectionPicker: some View {
        Picker("AI 设置分区", selection: Binding(
            get: { selectedSection ?? .service },
            set: { selectedSection = $0 }
        )) {
            ForEach(AISettingsSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .accessibilityLabel("AI 设置分区")
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !hasUsableConfiguredService {
                SettingsSection {
                    SettingsRow("还没有可用的 AI 服务", icon: "exclamationmark.circle", iconColor: .orange) {
                        Button("去 AI 服务配置") { switchToAIServiceTab() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Text("填好服务和模型后，消息摘要和回复建议就会开始工作。测试连接用来确认还能不能用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
            behaviorSection
        }
    }

    private var originalExampleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("你始终可以查看原文")
                .font(.system(size: 15, weight: .semibold))
            Text("AI 只整理，不代替聊天。关键决定面都留着原文入口。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("示例").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Text("原文")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text("明天中午前发我修改稿吧。")
                        .font(.system(size: 13))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("AI 提炼")
                        .font(.system(size: 11))
                        .foregroundStyle(CompanionPalette.jade)
                        .frame(width: 52, alignment: .leading)
                    Text("明天 12:00 前提交修改稿")
                        .font(.system(size: 13))
                        .foregroundStyle(CompanionPalette.jade)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CompanionPalette.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CompanionPalette.border))
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            serviceForm
            generationPreferences
            privacySection
        }
    }

    private var hasUsableConfiguredService: Bool {
        AISettingsValidation.connectionError(configuredSlot, requireModel: true) == nil
    }

    private var serviceForm: some View {
        SettingsSection {
            SettingsRow(AISettingsCopy.sourceTitle) {
                Picker(AISettingsCopy.sourceTitle, selection: $serviceSource) {
                    Text(AISettingsCopy.sourcePreset).tag(ServiceSource.preset)
                    Text(AISettingsCopy.sourceCustom).tag(ServiceSource.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel(AISettingsCopy.sourceTitle)
            }
            SettingsRowDivider()
            providerCard
        }
        .onChange(of: serviceSource) { _, source in
            guard !isHydrating else { return }
            testRequestID = UUID()
            testResult = ""
            switch source {
            case .preset:
                if providerID == "custom" || AIProvider.find(providerID) == nil {
                    applyPresetProvider(lastPresetProviderID)
                }
            case .custom:
                providerID = "custom"
            }
            debouncedSave()
        }
    }

    private var generationPreferences: some View {
        DisclosureGroup(isExpanded: $preferencesExpanded) {
            SettingsSection {
                SettingsToggleRow("慢慢想清楚再答", subtitle: "写摘要和草稿时多想一会儿，可能会更慢。", isOn: $thinkingEnabled)
                SettingsRowDivider()
                SettingsRow("回复最长写多少") {
                    HStack(spacing: 4) {
                        Slider(value: $maxTokens, in: 512...8192, step: 512)
                            .frame(width: 120)
                            .accessibilityLabel("回复最长写多少")
                        Text(String(Int(maxTokens)))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                SettingsRowDivider()
                SettingsRow("写得更随意一些") {
                    HStack(spacing: 4) {
                        Slider(value: $temperature, in: 0...1, step: 0.1)
                            .frame(width: 120)
                            .accessibilityLabel("写得更随意一些")
                        Text(String(format: "%.1f", temperature))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                Text("这是平时写摘要和草稿的习惯。有的整理任务会单独处理；用 ChatGPT 登录时，上面两项长度和随意度不会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } label: {
            Label("写作习惯", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .tint(CompanionPalette.accent)
        .companionSurface(padding: 16)
        .onChange(of: thinkingEnabled) { _, _ in debouncedSave() }
        .onChange(of: maxTokens) { _, _ in debouncedSave() }
        .onChange(of: temperature) { _, _ in debouncedSave() }
    }

    // MARK: - Cards

    // MARK: - Card

    private var providerCard: some View {
        ProviderCard(
            isCustomSource: serviceSource == .custom,
            providerID: $providerID,
            baseURL: $baseURL,
            model: $model,
            apiKey: $apiKey,
            models: $models,
            testResult: $testResult,
            isTesting: $isTesting,
            isFetching: $isFetching,
            onFetch: { fetchModels() },
            onProviderSelected: { value in
                guard !isHydrating else { return }
                if value != "custom" { lastPresetProviderID = value }
            }
        )
        .onChange(of: baseURL) { _, _ in configurationDidChange() }
        .onChange(of: model) { _, _ in configurationDidChange() }
        .onChange(of: apiKey) { _, _ in configurationDidChange() }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("分析与建议") {
                SettingsToggleRow("消息摘要", subtitle: "显示消息摘要。", isOn: $summaryEnabled)
                SettingsRowDivider()
                SettingsToggleRow("回复建议", subtitle: "起草回复，由你发送。", isOn: $suggestionsEnabled)
                SettingsRowDivider()
                SettingsRow("整理待办", subtitle: "有可用的 AI 服务时会自动从聊天里找待办，没有单独开关。未设 AI 仍可看原文。") {
                    Text("随 AI 服务").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            originalExampleCard
            SettingsSection("更多帮助") {
                SettingsToggleRow("重点联系人的语气提示", subtitle: "整理重点联系人在群聊中的表达，结合原话提示语气，供你参考。", isOn: $moodDetectionEnabled)
                SettingsRowDivider()
                SettingsToggleRow("今日小结里的下一步建议", subtitle: "给紧急事项加下一步建议。", isOn: $dailyReportActionInsightsEnabled)
            }
        }
        .onChange(of: summaryEnabled) { _, _ in debouncedSave() }
        .onChange(of: suggestionsEnabled) { _, _ in debouncedSave() }
        .onChange(of: moodDetectionEnabled) { _, _ in debouncedSave() }
        .onChange(of: dailyReportActionInsightsEnabled) { _, _ in debouncedSave() }
    }

    private var privacySection: some View {
        DisclosureGroup(isExpanded: $privacyExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("访问凭据仅保存在本机私有设置中，不会显示在界面或测试结果里。")
                Text("预设与自定义服务多为远程服务，请确认你信任其数据处理方式。")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            Label("数据与隐私", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .tint(CompanionPalette.accent)
        .companionSurface(padding: 16)
    }

    private var saveStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: saveError.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(saveError.isEmpty ? CompanionPalette.accent : .red)
            VStack(alignment: .leading, spacing: 3) {
                Text(serviceSaveStatusText)
                    .font(.system(size: 12, weight: .medium))
                if !saveError.isEmpty {
                    Text(saveError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if !saveError.isEmpty {
                Button("重试保存", action: saveAIConfig)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .companionSurface(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(saveError.isEmpty ? "设置保存状态" : "设置保存失败")
        .accessibilityValue(!saveError.isEmpty ? saveError : serviceSaveStatusText)
    }

    private var serviceSaveStatusText: String {
        if !saveError.isEmpty { return "更改尚未保存" }
        if hasPendingSave { return "正在保存更改…" }
        let tested = store.loadAIConnectionEvidence().record(for: buildSlot())?.succeeded == true
        if tested { return savedAt == nil ? "连接已验证" : "更改已保存" }
        if savedAt != nil || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "配置已保存 · 尚未测试"
        }
        return "配置加载后，修改会自动保存"
    }

    // MARK: - Actions

    private func applyPreviewTestFailure() {
        PreviewRuntime.pendingAITestFailure = false
        testResult = "失败：演示用的连接没有通过。"
        isTesting = false
    }

    private func testSlot() {
        if PreviewRuntime.isEnabled {
            applyPreviewTestFailure()
            return
        }
        let slot = buildSlot()
        let requestID = UUID()
        let requestStartedAt = Date()
        testRequestID = requestID
        if let error = AISettingsValidation.connectionError(slot, requireModel: true) {
            let saved = recordTestEvidence(slot: slot, succeeded: false, requestStartedAt: requestStartedAt)
            let suffix = saved ? "" : "；测试结果未保存，请重试"
            let detail = userFacingConfigurationError(error)
            testResult = "连接未完成：\(detail)\(suffix)"
            return
        }
        let service = AIService(config: buildConfig())
        isTesting = true
        testResult = ""
        Task {
            do {
                _ = try await service.testSlot(slot)
                await MainActor.run {
                    isTesting = false
                    guard requestID == testRequestID, slot == buildSlot() else { return }
                    let saved = recordTestEvidence(slot: slot, succeeded: true, requestStartedAt: requestStartedAt)
                    let message = saved
                        ? "连接成功，服务已返回有效响应。"
                        : "连接成功，但测试结果未保存，请重试。"
                    testResult = message
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    guard requestID == testRequestID, slot == buildSlot() else { return }
                    let saved = recordTestEvidence(slot: slot, succeeded: false, requestStartedAt: requestStartedAt)
                    let detail = userFacingConfigurationError(AISettingsValidation.connectionFailure(error))
                    let suffix = saved ? "" : "；测试结果未保存，请重试"
                    testResult = "连接未完成：\(detail)\(suffix)"
                }
            }
        }
    }

    private func userFacingConfigurationError(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("api key") || message.localizedCaseInsensitiveContains("token") {
            return AISettingsCopy.needSecret
        }
        if message.contains("接口地址") || message.contains("http://") || message.contains("https://") {
            return AISettingsCopy.needAddress
        }
        if message.contains("模型") {
            return AISettingsCopy.pickModel
        }
        return message
    }

    private func fetchModels() {
        let slot = buildSlot()
        if let error = AISettingsValidation.connectionError(slot, requireModel: false) {
            testResult = "获取失败：\(userFacingConfigurationError(error))"
            return
        }
        isFetching = true
        let service = AIService(config: buildConfig())
        Task {
            do {
                let list = try await service.fetchModels(slot: slot)
                await MainActor.run {
                    isFetching = false
                    guard slot == buildSlot() else { return }
                    models = list
                    // If current model not in list, keep it but notify via test result
                    if !list.isEmpty, !list.contains(model) {
                        testResult = "已获取 \(list.count) 个模型"
                    }
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    guard slot == buildSlot() else { return }
                    testResult = "获取失败：\(userFacingConfigurationError(AISettingsValidation.connectionFailure(error)))"
                }
            }
        }
    }

    // MARK: - Config builders

    private func configurationDidChange() {
        guard !isHydrating else { return }
        testRequestID = UUID()
        testResult = ""
        debouncedSave()
    }

    private func applyPresetProvider(_ id: String) {
        let previousProvider = providerID
        providerID = id
        guard let preset = AIProvider.find(id), preset.id != "custom" else { return }
        // Clear the key when moving to a different service, even at the same
        // address (two presets can share one URL with different keys). Coming
        // back from "custom" keeps the key when the address still matches:
        // the key in the field is the preset's own unless the user edited it
        // under custom *and* moved the address — in which case it is dropped
        // below. Flipping preset → custom → preset with no edits therefore
        // preserves a working credential instead of silently emptying it.
        if (preset.id != previousProvider && previousProvider != "custom") || baseURL != preset.baseURL {
            baseURL = preset.baseURL
            apiKey = ""
        }
        models = preset.models
        if model.isEmpty || !preset.models.contains(model) {
            model = preset.models.first ?? ""
        }
    }

    @discardableResult
    private func recordTestEvidence(slot: AIProviderSlot, succeeded: Bool, requestStartedAt: Date) -> Bool {
        var evidence = store.loadAIConnectionEvidence()
        guard evidence.setResult(for: slot, succeeded: succeeded, requestStartedAt: requestStartedAt) else {
            return false
        }
        do {
            try store.saveAIConnectionEvidence(evidence)
            return true
        } catch {
            return false
        }
    }

    private func restoredTestResult(for slot: AIProviderSlot) -> String {
        guard let record = store.loadAIConnectionEvidence().record(for: slot) else { return "" }
        let date = record.testedAt.formatted(.dateTime.month().day().hour().minute())
        return record.succeeded ? "上次测试成功 \(date)，可重新测试" : "上次测试失败 \(date)，请重新测试"
    }

    private func buildSlot() -> AIProviderSlot {
        AIProviderSlot(
            providerID: providerID,
            baseURL: resolvedURL(providerID: providerID, baseURL: baseURL),
            model: model,
            apiKey: apiKey
        )
    }

    private func buildConfig() -> AIConfig {
        var cfg = store.loadAIConfig()
        cfg.provider = buildSlot()
        cfg.thinkingEnabled = thinkingEnabled
        cfg.maxTokens = Int(maxTokens)
        cfg.temperature = temperature
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
        hasPendingSave = true
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
            hasPendingSave = false
            savedAt = Date()
            NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
        } catch {
            saveError = "AI 配置保存失败，请重试。"
        }
    }

    private func load() {
        guard !didLoad else { return }
        isHydrating = true

        let cfg = store.loadAIConfig()
        thinkingEnabled = cfg.thinkingEnabled
        maxTokens = Double(cfg.maxTokens)
        temperature = cfg.temperature

        providerID = cfg.provider.providerID
        baseURL = cfg.provider.baseURL
        model = cfg.provider.model
        apiKey = cfg.provider.apiKey

        if providerID == "custom" || AIProvider.find(providerID) == nil {
            serviceSource = .custom
        } else {
            serviceSource = .preset
            lastPresetProviderID = providerID
            if let preset = AIProvider.find(providerID) {
                if baseURL.isEmpty { baseURL = preset.baseURL }
                var list = preset.models
                // A stored model outside the preset list stays selectable.
                if !model.isEmpty, !list.contains(model) {
                    list = [model] + list
                }
                models = list
            }
        }

        summaryEnabled = cfg.summaryEnabled
        suggestionsEnabled = cfg.suggestionsEnabled
        moodDetectionEnabled = cfg.moodDetectionEnabled
        dailyReportActionInsightsEnabled = cfg.dailyReportActionInsightsEnabled

        testResult = restoredTestResult(for: buildSlot())
        if PreviewRuntime.pendingAITestFailure {
            applyPreviewTestFailure()
        }

        if selectedSection == nil {
            selectedSection = lockedSection ?? (hasUsableConfiguredService ? .analysis : .service)
        }
        didLoad = true
        DispatchQueue.main.async {
            isHydrating = false
        }
    }
}
