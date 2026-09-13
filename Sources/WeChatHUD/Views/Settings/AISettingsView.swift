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
    static let insecureHTTP = "此连接未加密，请确认网络可信或改用安全连接"
    static let secretTitle = "密钥"
    static let getKey = "去拿密钥"
    static let modelTitle = "用哪个模型"
    static let noModel = "还没选模型"
    static let refreshModels = "重新获取可用模型"
    static let needSecret = "请补上这台服务的密钥。"
    static let needAddress = "请填一个能用的地址。"
    static let pickModel = "请选一个模型。"
    static let checkAgain = "请核对地址、模型和密钥，再点「确认能用」。"
    static let confirmUnreachable = "这次没连上。"
    static let confirmBusy = "这会儿忙，过会儿再试。"
    static let needChatGPTLogin = "请先在这台 Mac 上登录 ChatGPT。"
    static let retryOnce = "再试一次"
    static let confirmOk = "刚才确认过了。"
    static let confirmOkUnsaved = "可以用，但这次没记下，请再点「确认能用」。"
    static let confirmUnsaved = "这次没记下。"
    static let confirmFailedDemo = "这次没通过。"
    static let restoredOkPrefix = "上次确认过"
    static let restoredFailPrefix = "上次没通过"
    static let saveFailed = "刚才没存上。"
    static let saving = "正在保存…"
    static let confirming = "正在确认…"
    static let saveOk = "已保存。"
    static let privacyBody = "密钥只留在这台电脑里，不会出现在界面或确认结果里。"
    static let privacyRemote = "常用服务和自己填的地址多半是网上的服务，请确认你信任对方怎么处理数据。"
    static let fetchFailed = "没拿到模型列表。"
    static let writingHabits = "写作习惯"
    static let privacyTitle = "数据与隐私"
    static let advancedTitle = "高级设置"
    static let codexHint = "用这台 Mac 上已登录的 ChatGPT，不必再填密钥。"

    static func restoredOk(_ date: String) -> String { "\(restoredOkPrefix) \(date)。" }
    static func restoredFail(_ date: String) -> String { "\(restoredFailPrefix) \(date)。" }
    static func fetchCount(_ n: Int) -> String { "找到 \(n) 个模型。" }
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
    var fetchNote: String = ""
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
                            .workspaceBody()
                    }
                }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(.secondary)
                .help(AISettingsCopy.refreshModels)
                .accessibilityLabel(AISettingsCopy.refreshModels)
                .disabled(isFetching)

                if !models.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .workspaceMeta()
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isExpanded ? "收起模型列表" : "展开模型列表")
                }
            }

            if !fetchNote.isEmpty {
                Text(fetchNote)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    @Binding var modelFetchNote: String
    @Binding var isTesting: Bool
    @Binding var isFetching: Bool

    let onFetch: () -> Void
    let onProviderSelected: (String) -> Void

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
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
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
                            Text(AISettingsCopy.insecureHTTP)
                                .workspaceMeta()
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(AISettingsCopy.getKey)
                        }
                    }
                }
            }

            // Model picker with live fetch + search
            SettingsRowDivider()
            SettingsRow(AISettingsCopy.modelTitle) {
                ModelPicker(
                    model: $model,
                    models: models,
                    isFetching: isFetching || isTesting,
                    fetchNote: modelFetchNote,
                    onRefresh: onFetch
                )
                .frame(maxWidth: 280)
            }
        }

    }

    private var hasPresetBaseURL: Bool {
        !(provider?.baseURL.isEmpty ?? true)
    }

    private func syncProviderPreset() {
        testResult = ""
        modelFetchNote = ""
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
    @State private var modelFetchNote = ""
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
    @State private var advancedExpanded = false
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
        VStack(alignment: .leading, spacing: 12) {
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

            saveStatus
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
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    Text("填好服务和模型后，消息摘要和回复建议就会开始工作。测试连接用来确认还能不能用。")
                        .workspaceMeta()
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
                .workspaceTitle()
            Text("AI 只整理，不代替聊天。关键决定面都留着原文入口。")
                .workspaceBody()
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("示例")
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Text("原文")
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text("明天中午前发我修改稿吧。")
                        .workspaceBody()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("AI 提炼")
                        .workspaceMeta()
                        .foregroundStyle(CompanionPalette.jade)
                        .frame(width: 52, alignment: .leading)
                    Text("明天 12:00 前提交修改稿")
                        .workspaceBody()
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
        serviceForm
    }

    private var hasUsableConfiguredService: Bool {
        AISettingsValidation.connectionError(configuredSlot, requireModel: true) == nil
    }

    private var isSuccessfulTestResult: Bool {
        testResult == AISettingsCopy.confirmOk
            || testResult == AISettingsCopy.confirmOkUnsaved
            || testResult.hasPrefix(AISettingsCopy.restoredOkPrefix)
    }

    private var isFailedTestResult: Bool {
        !testResult.isEmpty && !isSuccessfulTestResult
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
            SettingsRowDivider()
            advancedPreferences
        }
        .onChange(of: serviceSource) { _, source in
            guard !isHydrating else { return }
            testRequestID = UUID()
            testResult = ""
            modelFetchNote = ""
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

    private var advancedPreferences: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(spacing: 0) {
                Text(AISettingsCopy.writingHabits)
                    .workspaceRowTitle()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
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
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                SettingsRowDivider()
                Text(AISettingsCopy.privacyTitle)
                    .workspaceRowTitle()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text(AISettingsCopy.privacyBody)
                    Text(AISettingsCopy.privacyRemote)
                }
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        } label: {
            Text(AISettingsCopy.advancedTitle)
                .workspaceRowTitle()
        }
        .tint(CompanionPalette.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            modelFetchNote: $modelFetchNote,
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
                    Text("随 AI 服务")
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var saveStatus: some View {
        if isTesting {
            Text(AISettingsCopy.confirming)
                .workspaceMeta()
                .foregroundStyle(.secondary)
        } else if !saveError.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AISettingsCopy.saveFailed)
                    .workspaceMeta()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(AISettingsCopy.retryOnce, action: saveAIConfig)
                    .buttonStyle(CompanionPressStyle())
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AISettingsCopy.retryOnce)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AISettingsCopy.saveFailed)
        } else if hasPendingSave {
            Text(AISettingsCopy.saving)
                .workspaceMeta()
                .foregroundStyle(.secondary)
        } else if !testResult.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CompanionCopyableText(text: testResult, lineLimit: nil)
                    .workspaceMeta()
                    .foregroundStyle(isFailedTestResult ? .primary : CompanionPalette.jade)
                    .fixedSize(horizontal: false, vertical: true)
                if isFailedTestResult {
                    Spacer(minLength: 8)
                    Button(AISettingsCopy.retryOnce, action: testSlot)
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                        .disabled(isTesting || isFetching)
                        .accessibilityLabel(AISettingsCopy.retryOnce)
                }
            }
        } else if savedAt != nil {
            Text(AISettingsCopy.saveOk)
                .workspaceMeta()
                .foregroundStyle(CompanionPalette.jade)
        }
    }

    // MARK: - Actions

    private func applyPreviewTestFailure() {
        PreviewRuntime.pendingAITestFailure = false
        testResult = AISettingsCopy.confirmFailedDemo
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
        modelFetchNote = ""
        if let error = AISettingsValidation.connectionError(slot, requireModel: true) {
            let saved = recordTestEvidence(slot: slot, succeeded: false, requestStartedAt: requestStartedAt)
            let suffix = saved ? "" : AISettingsCopy.confirmUnsaved
            let detail = userFacingConfigurationError(error)
            testResult = "\(detail)\(suffix.isEmpty ? "" : " \(suffix)")"
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
                        ? AISettingsCopy.confirmOk
                        : AISettingsCopy.confirmOkUnsaved
                    testResult = message
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    guard requestID == testRequestID, slot == buildSlot() else { return }
                    let saved = recordTestEvidence(slot: slot, succeeded: false, requestStartedAt: requestStartedAt)
                    let detail = userFacingConfigurationError(AISettingsValidation.connectionFailure(error))
                    let suffix = saved ? "" : AISettingsCopy.confirmUnsaved
                    testResult = "\(detail)\(suffix.isEmpty ? "" : " \(suffix)")"
                }
            }
        }
    }

    private func userFacingConfigurationError(_ message: String) -> String {
        if message.contains("超时") || message.contains("无法连接") || message.contains("网络请求失败") {
            return AISettingsCopy.confirmUnreachable
        }
        if message.contains("额度") || message.contains("过多") {
            return AISettingsCopy.confirmBusy
        }
        if message.contains("登录") {
            return AISettingsCopy.needChatGPTLogin
        }
        if message.localizedCaseInsensitiveContains("api key") || message.localizedCaseInsensitiveContains("token") {
            return AISettingsCopy.needSecret
        }
        if message.contains("接口地址") || message.contains("http://") || message.contains("https://") {
            return AISettingsCopy.needAddress
        }
        if message.contains("请填写模型名称") || message.contains("请选择一个模型") {
            return AISettingsCopy.pickModel
        }
        return AISettingsCopy.checkAgain
    }

    private func fetchModels() {
        let slot = buildSlot()
        if let error = AISettingsValidation.connectionError(slot, requireModel: false) {
            modelFetchNote = "\(AISettingsCopy.fetchFailed)\(userFacingConfigurationError(error))"
            return
        }
        isFetching = true
        modelFetchNote = ""
        let service = AIService(config: buildConfig())
        Task {
            do {
                let list = try await service.fetchModels(slot: slot)
                await MainActor.run {
                    isFetching = false
                    guard slot == buildSlot() else { return }
                    models = list
                    // Keep a model not in the list; say so under the field.
                    if !list.isEmpty, !list.contains(model) {
                        modelFetchNote = AISettingsCopy.fetchCount(list.count)
                    }
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    guard slot == buildSlot() else { return }
                    modelFetchNote = "\(AISettingsCopy.fetchFailed)\(userFacingConfigurationError(AISettingsValidation.connectionFailure(error)))"
                }
            }
        }
    }

    // MARK: - Config builders

    private func configurationDidChange() {
        guard !isHydrating else { return }
        testRequestID = UUID()
        testResult = ""
        modelFetchNote = ""
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
        return record.succeeded ? AISettingsCopy.restoredOk(date) : AISettingsCopy.restoredFail(date)
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
            saveError = AISettingsCopy.saveFailed
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
