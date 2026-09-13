import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let hudDisplayPreferenceDidChange = Notification.Name("WeChatHUD.DisplayPreferenceDidChange")
}

enum PreferencesCopy {
    static func hudLine(_ screen: DisplayScreen) -> String {
        "浮窗在\(screen.label)。"
    }

    static let displayTitle = "显示位置"
    static let displaySubtitle = "浮窗出现在哪块屏。那块屏不在时用还连着的。"
    static let updatesDisclosure = "还要看版本"
    static let saveFailed = "刚才没记上。"
    static let saveRetry = "再试一次"
}

struct SyncSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    // MARK: - Sync state
    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var cacheStrategy: CacheStrategy = .temporary
    @State private var displayScreen: DisplayScreen = .builtIn
    @State private var keysFilePath = ""
    @State private var databaseCandidates: [String] = []
    @State private var keyFileReadable = false
    @State private var keyFileExists = false
    @State private var keyPathMessage = ""

    // MARK: - Data management state
    @State private var selectedSection: DataSection = .commitments
    @State private var dataSearch = ""
    @State private var exportMessage: String?
    @State private var recalledMessages: [RecalledMessage] = []
    @State private var commitments: [Commitment] = []
    @State private var pendingAsks: [PendingAsk] = []

    @State private var didLoad = false
    @State private var isHydrating = true
    @State private var saveError = ""
    @State private var syncSaveFailed = false
    @State private var needsRestart = false
    @State private var exportedURL: URL?
    @State private var legacyStatus: DeviceSettingsStore.LegacyStoreStatus?
    @State private var showLegacyBindConfirm = false
    @State private var showAdvancedConnection = false
    @State private var showConnectionMaintenance = false
    @State private var showConnectionDiagnostics = false
    @State private var selectedSettingsSection: SettingsPane
    private let lockedPane: SettingsPane?

    init(pane: String? = nil) {
        switch pane {
        case "preferences":
            lockedPane = .preferences
            _selectedSettingsSection = State(initialValue: .preferences)
        case "data":
            lockedPane = .data
            _selectedSettingsSection = State(initialValue: .data)
        case "connection":
            lockedPane = .connection
            _selectedSettingsSection = State(initialValue: .connection)
        default:
            lockedPane = nil
            _selectedSettingsSection = State(initialValue: .connection)
        }
    }

    let intervals = [15, 30, 60, 300]

    enum DataSection: String, CaseIterable {
        case commitments = "承诺"
        case pendingAsks = "提问"
        case recalls = "撤回记录"
    }

    private enum SettingsPane: String, CaseIterable {
        case connection = "微信连接"
        case preferences = "使用偏好"
        case data = "本地资料"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if lockedPane == nil {
                Picker("设置分区", selection: $selectedSettingsSection) {
                    ForEach(SettingsPane.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("设置分区")
            }
            settingsPane(.connection) {
                VStack(alignment: .leading, spacing: 16) {
                    WeChatConnectionSetupView(
                        connectedContinueTitle: WeChatConnectionCopy.pickConversations,
                        onConnectedContinue: {
                            NotificationCenter.default.post(name: .hudSwitchTab, object: "contacts")
                        }
                    )
                        .companionSurface(padding: 22)
                    connectionSaveReceipt
                    if needsRestart {
                        Text(WeChatConnectionCopy.restartToApply)
                            .workspaceMeta()
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    DisclosureGroup(WeChatConnectionCopy.advanced, isExpanded: $showAdvancedConnection) {
                        VStack(alignment: .leading, spacing: 16) {
                            connectionCapabilityList
                            DisclosureGroup(WeChatConnectionCopy.syncAndChecks, isExpanded: $showConnectionMaintenance) {
                                VStack(alignment: .leading, spacing: 16) {
                                    syncSection
                                    databaseSection
                                    if let device = store.deviceSettings,
                                       (legacyStatus ?? device.legacyStoreStatus) == .needsAccountConfirmation {
                                        legacyRecordsSection(device: device)
                                    }
                                    DisclosureGroup(WeChatConnectionCopy.diagnostics, isExpanded: $showConnectionDiagnostics) {
                                        SupportDiagnosticsView()
                                    }
                                }
                            }
                        }.padding(.top, 14)
                    }.font(.callout)
                }
            }
            settingsPane(.preferences) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(PreferencesCopy.hudLine(displayScreen))
                        .workspaceTitle()
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if syncSaveFailed {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(PreferencesCopy.saveFailed)
                                .workspaceMeta()
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(PreferencesCopy.saveRetry, action: save)
                                .buttonStyle(CompanionPressStyle())
                                .workspaceMeta()
                                .foregroundStyle(.secondary)
                        }
                    }
                    displaySection
                    MacExperienceSettingsView()
                    DisclosureGroup(PreferencesCopy.updatesDisclosure) {
                        AppUpdateSettingsView()
                    }
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                }
            }
            settingsPane(.data) {
                dataSection
            }
        }
        .alert("确认这是当前账号的旧版资料？", isPresented: $showLegacyBindConfirm) {
            Button("绑定到当前账号") { bindLegacyRecords() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只有在当前新账号库没有业务资料时才应绑定。绑定不会复制或删除数据；重启助手后，将读取旧版记录。请先备份旧数据库和同目录 WAL/SHM 文件。")
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            legacyStatus = store.deviceSettings?.legacyStoreStatus
            loadSync()
            reloadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudConnectionConfigurationDidChange)) { _ in
            loadSync()
        }
    }

    @ViewBuilder
    private func settingsPane<Content: View>(_ section: SettingsPane, @ViewBuilder content: () -> Content) -> some View {
        let active = selectedSettingsSection == section
        content()
            .opacity(active ? 1 : 0)
            .frame(maxHeight: active ? .infinity : 0)
            .clipped()
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }

    @ViewBuilder
    private var connectionSaveReceipt: some View {
        if syncSaveFailed || saveError == WeChatConnectionCopy.bindFailed {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(syncSaveFailed ? WeChatConnectionCopy.saveFailed : WeChatConnectionCopy.bindFailed)
                    .workspaceMeta()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if syncSaveFailed {
                    Button(WeChatConnectionCopy.saveRetry, action: save)
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(WeChatConnectionCopy.saveRetry)
                }
            }
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection("同步") {
            // Poll interval
            SettingsRow("轮询间隔", subtitle: "补充检查频率，重启助手后生效", icon: "clock.arrow.2.circlepath", iconColor: .blue) {
                Picker("轮询间隔", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i)秒" : "\(i/60)分钟").tag(i)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: interval) { save() }
            }

            SettingsRowDivider()

            // Cache strategy
            SettingsRow("解密缓存", subtitle: cacheStrategy.hint + " · 重启助手后生效", icon: "externaldrive", iconColor: .orange) {
                Picker("解密缓存", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                .onChange(of: cacheStrategy) { save() }
            }

        }
    }

    private var displaySection: some View {
        SettingsSection {
            SettingsRow(PreferencesCopy.displayTitle, subtitle: PreferencesCopy.displaySubtitle, icon: "display", iconColor: .secondary) {
                HStack(spacing: 6) {
                    ForEach(DisplayScreen.allCases, id: \.self) { screen in
                        Button(screen.label) {
                            displayScreen = screen
                            save()
                        }
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(displayScreen == screen ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            displayScreen == screen ? CompanionPalette.selectedFill : Color.clear,
                            in: Capsule()
                        )
                        .accessibilityLabel(screen.label)
                        .accessibilityAddTraits(displayScreen == screen ? .isSelected : [])
                    }
                }
            }
        }
    }

    static func connectionFooter(readingReady: Bool, sendReady: Bool) -> String {
        if !readingReady {
            return "先连接微信。发送回复还需要系统授权。"
        }
        if sendReady {
            return "读取聊天和跳转发送都已就绪。"
        }
        return "读取聊天已可使用，发送前需要在系统中额外授权。"
    }

    private var connectionCapabilityList: some View {
        let readingReady = monitor.stats.lastSyncAt != nil
        let aiConfig = store.loadAIConfig()
        let aiConfigured = AISettingsValidation.connectionError(aiConfig.provider, requireModel: true) == nil
        let aiTested = AIConnectionEvidenceStore.isSuccessful(aiConfig, store: store)
        let aiReady = aiConfigured
        let sendReady = AXIsProcessTrusted()
        return VStack(alignment: .leading, spacing: 0) {
            capabilityRow(
                icon: "bubble.left.and.bubble.right",
                title: "读取聊天",
                detail: "已连接微信，可读取你的聊天内容，用于识别待办、约定等重要信息。",
                status: readingReady ? "已就绪" : "待连接",
                ready: readingReady
            )
            SettingsRowDivider()
            capabilityRow(
                icon: "sparkles",
                title: "AI 整理",
                detail: "从聊天提取待办和约定。",
                status: aiTested ? "已就绪" : (aiConfigured ? "已配置" : "尚未设置"),
                ready: aiReady,
                actionTitle: aiReady ? nil : "设置 AI"
            ) {
                NotificationCenter.default.post(name: .hudSwitchTab, object: "aiService")
            }
            SettingsRowDivider()
            capabilityRow(
                icon: "arrow.up.forward.app",
                title: "跳转与发送",
                detail: "在微信中打开对话并发送。",
                status: sendReady ? "已就绪" : "待授权",
                ready: sendReady,
                actionTitle: sendReady ? nil : "打开系统设置"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(CompanionPalette.jade)
                Text(Self.connectionFooter(readingReady: readingReady, sendReady: sendReady))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .companionSurface(padding: 0)
    }

    private func capabilityRow(
        icon: String,
        title: String,
        detail: String,
        status: String,
        ready: Bool,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CompanionPalette.jade)
                .frame(width: 28, height: 28)
                .background(CompanionPalette.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Label(status, systemImage: ready ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ready ? CompanionPalette.jade : .secondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func legacyRecordsSection(device: DeviceSettingsStore) -> some View {
        SettingsSection("旧版资料") {
            SettingsRow("旧版记录已保留，尚未绑定账号", subtitle: "旧版本没有保存明确的账号归属，当前账号因此使用独立资料库。", icon: "archivebox", iconColor: .orange) {
                Button("在 Finder 中查看") {
                    NSWorkspace.shared.activateFileViewerSelecting([device.legacyStoreURL])
                }
                if canOfferLegacyBind {
                    Button("绑定到当前账号") { showLegacyBindConfirm = true }
                }
            }
            Text("原资料没有删除，也没有合并到当前账号。只有你已核实目录归属、且当前新账号还没有关注/待办/草稿等资料时，才可显式绑定。绑定不会自动认领，也不会移动或覆盖文件；重启助手后生效。")
                .font(.system(size: 12)).foregroundColor(.secondary).padding(14)
        }
    }

    private var canOfferLegacyBind: Bool {
        guard !monitor.reader.dbDir.isEmpty else { return false }
        return !newAccountStoreHasBusinessData
    }

    private var newAccountStoreHasBusinessData: Bool {
        !store.getWhitelist().isEmpty
            || !store.loadDrafts().isEmpty
            || !store.loadDiscussionItems().isEmpty
            || !store.loadCommitments().isEmpty
            || !store.loadAIFeedback(msgUIDPrefix: "discussion_item:").isEmpty
            || store.classificationQueueCount() > 0
            || store.getSetting("autopilot")?.isEmpty == false
    }

    private func bindLegacyRecords() {
        guard let device = store.deviceSettings else { return }
        do {
            var sync = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
            sync.wechatDBPath = monitor.reader.dbDir
            try store.setSettingJSON("sync", value: sync)
            dbPath = monitor.reader.dbDir
            try device.confirmLegacyAccountIdentity(expectedRoot: monitor.reader.dbDir)
            legacyStatus = device.legacyStoreStatus
            saveError = ""
            needsRestart = true
        } catch {
            saveError = WeChatConnectionCopy.bindFailed
        }
    }

    private var directoryDiagnosis: SyncConnectionDiagnosis {
        SyncConnectionDiagnosis.evaluate(
            configuredPath: dbPath, candidates: databaseCandidates,
            exists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            readable: { FileManager.default.isReadableFile(atPath: $0) },
            containsDatabase: { FileManager.default.fileExists(atPath: $0 + "/session/session.db") }
        )
    }

    private var databaseSection: some View {
        SettingsSection("微信账号与数据目录") {
            SettingsRow("本次运行读取", subtitle: monitor.reader.dbDir.isEmpty ? "尚未连接目录" : shortenPath(monitor.reader.dbDir), icon: "person.crop.circle", iconColor: .blue) {
                Button("重新检测", action: refreshConnectionDiagnosis)
            }
            SettingsRowDivider()
            Text(directoryDiagnosis.message)
                .font(.system(size: 12))
                .foregroundColor(directoryDiagnosis.needsAttention ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)

            if !databaseCandidates.isEmpty {
                ForEach(databaseCandidates, id: \.self) { path in
                    SettingsRowDivider()
                    SettingsRow(accountDirectoryName(path), subtitle: shortenPath(path), icon: "folder", iconColor: .secondary) {
                        if dbPath == path {
                            Label("已选择", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundColor(.green)
                        } else {
                            Button("使用此目录") { dbPath = path; save() }
                        }
                    }
                }
            }
            SettingsRowDivider()
            SettingsRow("下次启动读取", subtitle: "填 auto 仅在一个候选目录时自动连接；选择后重启助手生效。") {
                VStack(alignment: .trailing, spacing: 6) {
                    CompanionClipboardField(
                        text: $dbPath,
                        placeholder: "auto 或微信账号资料目录",
                        kind: .plain,
                        accessibilityLabel: "下次启动读取路径"
                    )
                    .frame(maxWidth: 280)
                    .onChange(of: dbPath) { save() }
                    Button("选择文件夹…", action: chooseDatabaseDirectory)
                }
            }
            SettingsRowDivider()
            SettingsRow("解密密钥文件", subtitle: keyFileMessage, icon: "key", iconColor: keyFileReadable ? .secondary : .orange) {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("下次启动：" + (keysFilePath.isEmpty ? "默认路径" : shortenPath(keysFilePath)))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button("选择 JSON…", action: chooseKeyFile)
                            .disabled(PreviewRuntime.isEnabled)
                        if !keysFilePath.isEmpty {
                            Button("恢复默认") {
                                keysFilePath = ""
                                keyPathMessage = ""
                                save()
                                refreshConnectionDiagnosis()
                            }
                        }
                    }
                }
            }
            if !keyPathMessage.isEmpty {
                Text(keyPathMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
            }
            Text("解密缓存按数据库目录隔离。选择目录不会合并账号，也不会证明密钥属于该账号。请使用与你所选微信账号匹配的密钥。")
                .font(.system(size: 12)).foregroundColor(.secondary).padding(14)
        }
    }

    private var keyFileMessage: String {
        let prefix = "本次运行"
        if !keyFileExists { return "\(prefix)：未找到当前连接的密钥文件。请先使用配套的 wechat-cli 为所选账号配置密钥，默认位置为 ~/.wechat-cli/all_keys.json。" }
        if !keyFileReadable { return "\(prefix)：当前连接的密钥文件不可读，请检查本机文件权限。" }
        return "\(prefix)。密钥保留在本机；文件可读不代表内容有效或匹配当前账号，以成功同步为准。"
    }

    private func accountDirectoryName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    private func refreshConnectionDiagnosis() {
        databaseCandidates = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        switch monitor.reader.accessMaterialState {
        case .missing:
            keyFileExists = false
            keyFileReadable = false
        case .unreadable:
            keyFileExists = true
            keyFileReadable = false
        case .available:
            keyFileExists = true
            keyFileReadable = true
        }
    }

    private func chooseDatabaseDirectory() {
        let picker = NSOpenPanel()
        picker.title = "选择所需微信账号的资料目录"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url {
            dbPath = url.path
            save()
            refreshConnectionDiagnosis()
        }
    }

    private func chooseKeyFile() {
        guard !PreviewRuntime.isEnabled else { return }
        let picker = NSOpenPanel()
        picker.title = "选择已有的 JSON 密钥文件"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard WeChatReader.validateKeyFile(at: url.path) else {
            keyPathMessage = "无法使用此文件。请选择可读取且内容为 JSON 对象的密钥文件。"
            return
        }
        keysFilePath = url.path
        keyPathMessage = ""
        save()
        refreshConnectionDiagnosis()
    }

    // MARK: - Data management

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if PreviewRuntime.isEnabled {
                Text("当前账号 演示数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(LocalDataCopy.statusLine(count: recalledMessages.count + commitments.count + pendingAsks.count))
                .workspaceTitle()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalDataRetrospection.windowCaption)
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !saveError.isEmpty {
                Text(LocalDataCopy.saveFailed)
                    .workspaceMeta()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            retrospectionSection
            DisclosureGroup(LocalDataCopy.exportDisclosure) {
                exportReportSection
            }
            .workspaceMeta()
            .foregroundStyle(.secondary)
        }
    }

    private var exportReportSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    sectionHeaderIcon("square.and.arrow.up", color: .blue)
                    Text("导出报告")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    if let url = exportedURL {
                        Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                    Button("导出到桌面") {
                        if let url = monitor.exportReport() {
                            exportedURL = url
                            exportMessage = "已导出 \(url.lastPathComponent)"
                        } else {
                            exportMessage = "导出失败，请检查桌面写入权限"
                        }
                    }
                    .buttonStyle(CompanionPressStyle())
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Text(LocalDataRetrospection.exportCaption)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                if let msg = exportMessage {
                    HStack(spacing: 8) {
                        Image(systemName: msg.hasPrefix("导出失败") ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .foregroundStyle(msg.hasPrefix("导出失败") ? Color.red : Color.secondary)
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(msg.hasPrefix("导出失败") ? .red : .secondary)
                        if let url = exportedURL, !msg.hasPrefix("导出失败") {
                            Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(CompanionPressStyle())
                                .workspaceMeta()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                    .transition(.opacity)
                }
            }
        }
    }

    private var retrospectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(DataSection.allCases, id: \.self) { section in
                    CompanionFilterPill(title: section.rawValue, selected: selectedSection == section) {
                        selectedSection = section
                        reloadData()
                    }
                }
            }
            DisclosureGroup(LocalDataCopy.findDisclosure) {
                CompanionClipboardField(
                    text: $dataSearch,
                    placeholder: LocalDataCopy.searchPlaceholder,
                    kind: .plain,
                    accessibilityLabel: LocalDataCopy.searchPlaceholder
                )
            }
            .workspaceMeta()
            .foregroundStyle(.secondary)
            switch selectedSection {
            case .recalls:     recallsList
            case .commitments: commitmentsList
            case .pendingAsks: pendingAsksList
            }
        }
    }

    private func sectionHeaderIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundColor(color)
            .frame(width: 28, height: 28, alignment: .center)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Data lists

    private var recallsList: some View {
        Group {
            if recalledMessages.isEmpty {
                emptyRow(LocalDataRetrospection.emptyRecalls)
            } else {
                ForEach(recalledMessages.filter { matchesDataSearch($0.senderName, $0.chatName, $0.originalText) }) { msg in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Text(msg.senderRole.icon).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(msg.senderName)
                                    .font(.system(size: 13, weight: .medium))
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text(msg.chatName)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(msg.recallDelaySeconds)秒后撤回")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            Text("「\(msg.originalText)」")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var commitmentsList: some View {
        Group {
            if commitments.isEmpty {
                emptyRow(LocalDataRetrospection.emptyCommitments, nextTitle: LocalDataCopy.openTasks) {
                    NotificationCenter.default.post(name: .hudSwitchTab, object: "tasks")
                }
            } else {
                ForEach(commitments.filter { matchesDataSearch($0.content, $0.commitTo) }) { item in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(commitmentColor(item))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.content)
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Text("→ \(item.commitTo)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                if item.status == .fulfilled {
                                    Text("已完成")
                                        .font(.system(size: 12))
                                        .foregroundColor(CompanionPalette.jade)
                                } else if item.status == .pending || item.status == .overdue, let d = item.deadlineAt {
                                    Text(d < Date() ? "已超期" : "截止 \(MessageInfo.formatRelative(Int(d.timeIntervalSince1970)))")
                                        .font(.system(size: 12))
                                        .foregroundColor(d < Date() ? .red : .secondary)
                                }
                            }
                        }
                        Spacer()
                        if item.status == .pending {
                            Button("完成") {
                                mutateData { try store.updateCommitmentStatus(msgUID: item.msgUID, status: .fulfilled) }
                            }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                            Button("取消") {
                                mutateData { try store.updateCommitmentStatus(msgUID: item.msgUID, status: .cancelled) }
                            }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                        } else {
                            Text(commitmentStatusLabel(item.status))
                                .font(.system(size: 12))
                                .foregroundColor(item.status == .fulfilled ? CompanionPalette.jade : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var pendingAsksList: some View {
        Group {
            if pendingAsks.isEmpty {
                emptyRow(LocalDataRetrospection.emptyPendingAsks, nextTitle: LocalDataCopy.openTasks) {
                    NotificationCenter.default.post(name: .hudSwitchTab, object: "tasks")
                }
            } else {
                ForEach(pendingAsks.filter { matchesDataSearch($0.senderName, $0.chatName, $0.summary) }) { ask in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(urgencyColor(ask))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if let role = ask.senderRole { Text(role.icon).font(.system(size: 12)) }
                                Text(ask.senderName).font(.system(size: 13, weight: .medium))
                                Text(ask.chatName).font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            Text(ask.summary).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                            Text(MessageInfo.formatRelative(Int(ask.createdAt.timeIntervalSince1970)))
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if ask.status == .pending {
                            Button("已处理") {
                                mutateData { try store.updatePendingAskStatus(msgUID: ask.msgUID, status: .done) }
                            }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                            Button("忽略") {
                                mutateData { try store.dismissPendingAsk(msgUID: ask.msgUID) }
                            }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                        } else {
                            Text(ask.status.rawValue).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - Helpers

    private func matchesDataSearch(_ fields: String...) -> Bool {
        let query = dataSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func emptyRow(_ text: String, nextTitle: String? = nil, next: (() -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            if let nextTitle, let next {
                Button(nextTitle, action: next)
                    .buttonStyle(CompanionPressStyle())
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private func commitmentStatusLabel(_ status: CommitmentStatus) -> String {
        switch status {
        case .pending: return "进行中"
        case .fulfilled: return "已完成"
        case .overdue: return "已超期"
        case .cancelled: return "已取消"
        }
    }

    private func commitmentColor(_ item: Commitment) -> Color {
        switch item.status {
        case .pending:  return (item.deadlineAt ?? .distantFuture) < Date() ? .red : .orange
        case .fulfilled: return .green
        case .overdue:   return .red
        case .cancelled: return .gray
        }
    }

    private func urgencyColor(_ ask: PendingAsk) -> Color {
        switch ask.urgency {
        case .urgent:  return .red
        case .timely:  return .orange
        case .routine: return .blue
        case .none:    return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func shortenPath(_ path: String) -> String {
        if path.count <= 40 { return path }
        let comps = path.split(separator: "/")
        if comps.count > 3 {
            return "…/" + comps.suffix(3).joined(separator: "/")
        }
        return path
    }

    // MARK: - Persistence

    private func loadSync() {
        isHydrating = true
        let cfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        dbPath = cfg.wechatDBPath
        interval = cfg.intervalSeconds
        cacheStrategy = cfg.cacheStrategy
        displayScreen = cfg.displayScreen
        keysFilePath = cfg.keysFilePath ?? ""
        refreshConnectionDiagnosis()
        DispatchQueue.main.async { isHydrating = false }
    }

    private func save() {
        guard didLoad, !isHydrating else { return }
        let previous = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        let cfg = SyncConfig(
            intervalSeconds: interval,
            wechatDBPath: dbPath,
            keysFilePath: keysFilePath.isEmpty ? nil : keysFilePath,
            cacheStrategy: cacheStrategy,
            displayScreen: displayScreen
        )
        do {
            try store.setSettingJSON("sync", value: cfg)
            syncSaveFailed = false
            saveError = ""
            needsRestart = needsRestart || previous.intervalSeconds != cfg.intervalSeconds
                || previous.wechatDBPath != cfg.wechatDBPath || previous.keysFilePath != cfg.keysFilePath
                || previous.cacheStrategy != cfg.cacheStrategy
            if previous.displayScreen != cfg.displayScreen {
                NotificationCenter.default.post(name: .hudDisplayPreferenceDidChange, object: nil)
            }
        } catch {
            saveError = WeChatConnectionCopy.saveFailed
            syncSaveFailed = true
        }
    }

    private func mutateData(_ operation: () throws -> Void) {
        do {
            try operation()
            saveError = ""
            reloadData()
            monitor.refreshNow()
        } catch {
            saveError = LocalDataCopy.saveFailed
        }
    }

    private func reloadData() {
        let snapshot = LocalDataRetrospection.load(store: store)
        recalledMessages = snapshot.recalls
        commitments = snapshot.commitments
        pendingAsks = snapshot.pendingAsks
    }
}

enum LocalDataCopy {
    static func statusLine(count: Int) -> String {
        if count == 0 { return "近两周没有整理过的记录。" }
        return "近两周整理过 \(count) 件事。"
    }

    static let exportDisclosure = "还要导出"
    static let searchPlaceholder = "找人或内容"
    static let findDisclosure = "还要找"
    static let saveFailed = "刚才没记上。"
    static let openTasks = "去待办里看"
}

/// 本地资料 is "近两周整理过的事情". Load windows and empty copy must
/// use the same 14-day cutoff as 待办, not the whole sqlite history.
enum LocalDataRetrospection {
    static let windowDays = DiscussionLiveWindow.pendingDays
    static let exportCaption = "导出一份状态报告到桌面：未读、待回复、承诺等统计。不是聊天原文。"
    static let windowCaption = "只看近 \(windowDays) 天整理过的记录。更早的已收起。"
    static let emptyRecalls = "近两周没有撤回记录"
    static let emptyCommitments = "近两周没有记下的承诺"
    static let emptyPendingAsks = "近两周没有记下的提问"

    struct Snapshot {
        var recalls: [RecalledMessage]
        var commitments: [Commitment]
        var pendingAsks: [PendingAsk]
    }

    static func cutoff(now: Date = Date()) -> Int {
        DiscussionLiveWindow.cutoff(days: windowDays, now: now)
    }

    static func load(store: HUDStore, now: Date = Date()) -> Snapshot {
        let since = cutoff(now: now)
        let main = store.loadPendingAsks(bucket: .main, status: .pending, relevantSince: since)
        let review = store.loadPendingAsks(bucket: .review, status: .pending, relevantSince: since)
        let done = store.loadPendingAsks(bucket: .main, status: .done, relevantSince: since)
        return Snapshot(
            recalls: store.loadRecalledMessages(since: since, limit: 50),
            commitments: store.loadCommitments(relevantSince: since),
            pendingAsks: main + review + Array(done.prefix(10))
        )
    }
}
