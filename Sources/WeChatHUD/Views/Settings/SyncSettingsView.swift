import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let hudDisplayPreferenceDidChange = Notification.Name("WeChatHUD.DisplayPreferenceDidChange")
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
    @State private var isTighteningKeyPermissions = false
    @State private var keyPermissionFixError: String?
    @State private var keyPermissionGeneration = 0
    @State private var fullDiskSettingsError: String?
   @State private var accessibilitySettingsError: String?
    @State private var finderRevealError: String?

    // MARK: - Data management state
    @State private var selectedSection: DataSection = .commitments
    @State private var dataSearch = ""
   @State private var exportMessage: String?
    @State private var exportFailed = false
    @State private var recalledMessages: [RecalledMessage] = []
    @State private var commitments: [Commitment] = []
    @State private var pendingAsks: [PendingAsk] = []

    @State private var didLoad = false
    @State private var isHydrating = true
    @State private var saveError = ""
    @State private var syncSaveFailed = false
    @State private var needsRestart = false
    /// 记录回溯 row whose 取消 is awaiting confirmation.
    @State private var pendingCommitmentCancel: Commitment?
    @State private var exportedURL: URL?
    @State private var legacyStatus: DeviceSettingsStore.LegacyStoreStatus?
    @State private var showLegacyBindConfirm = false
    @State private var showAdvancedConnection = false
    @State private var isBindingLegacy = false
    @State private var isCancellingCommitment = false
    @State private var showInstallConfirm = false
    @ObservedObject private var updates = AppUpdateController.shared
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
        case pendingAsks = "待处理的提问"
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
            if !saveError.isEmpty {
                HStack {
                    Text(saveError).companionFont(size: 12).foregroundColor(.red)
                    Spacer()
                    if syncSaveFailed { Button("重试保存设置", action: save) }
                }
                .transition(.companionStatusReveal)
            }
            settingsPane(.connection) {
                VStack(alignment: .leading, spacing: 16) {
                    WeChatConnectionSetupView()
                        .companionSurface(padding: 22)
                    connectionCapabilityList
                    keyPermissionNotice
                    DisclosureGroup(isExpanded: $showAdvancedConnection, content: {
                        VStack(alignment: .leading, spacing: 16) {
                            databaseSection
                            syncSection
                            if let device = store.deviceSettings,
                               (legacyStatus ?? device.legacyStoreStatus) == .needsAccountConfirmation {
                                legacyRecordsSection(device: device)
                            }
                            if needsRestart {
                                Text("高级连接设置将在助手重新打开后应用。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            SupportDiagnosticsView()
                        }.padding(.top, 14)
                    }, label: {
                        Text("高级连接设置").companionDisclosureLabel()
                    })
                    .font(.callout)
                }
            }
            settingsPane(.preferences) {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    MacExperienceSettingsView()
                    AppUpdateSettingsView(showInstallConfirm: $showInstallConfirm)
                }
            }
            settingsPane(.data) {
                dataSection
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: saveError)
        .companionDialogBackdrop(showLegacyBindConfirm || pendingCommitmentCancel != nil || showInstallConfirm) {
            if showLegacyBindConfirm {
                CompanionDialog(title: "确认这是当前账号的旧版资料？", onClose: { if !isBindingLegacy { showLegacyBindConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("只有在当前新账号还没有待办、草稿和关注名单时才应绑定。绑定不会复制或删除资料；重启助手后，将读取旧版记录。请先备份旧资料，以及同文件夹里一起出现的配套文件。")
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !saveError.isEmpty {
                            Text(saveError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { showLegacyBindConfirm = false }
                                .companionBusyHold(isBindingLegacy, "正在绑定旧版资料")
                            Button {
                                guard !isBindingLegacy else { return }
                                isBindingLegacy = true
                                Task { @MainActor in
                                    let ok = bindLegacyRecords()
                                    isBindingLegacy = false
                                    if ok { showLegacyBindConfirm = false }
                                }
                            } label: {
                                Text(isBindingLegacy ? "正在绑定旧资料…" : "绑定到当前账号")
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBindingLegacy)
                            .help(isBindingLegacy ? "正在绑定旧版资料" : "")
                            .accessibilityHint(isBindingLegacy ? "正在绑定旧版资料" : "")
                        }
                    }
                }
            } else if let item = pendingCommitmentCancel {
                // 记录回溯's 取消 is irreversible from the list, so it asks first.
                CompanionDialog(title: CompanionProductCopy.cancelCommitmentTitle, onClose: { if !isCancellingCommitment { pendingCommitmentCancel = nil } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.cancelCommitmentMessage)
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !saveError.isEmpty {
                            Text(saveError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("保留") { pendingCommitmentCancel = nil }
                                .companionBusyHold(isCancellingCommitment, "正在取消这条承诺")
                            Button(role: .destructive) {
                                guard !isCancellingCommitment else { return }
                                isCancellingCommitment = true
                                Task { @MainActor in
                                    let ok = mutateData { try store.updateCommitmentStatus(msgUID: item.msgUID, status: .cancelled) }
                                    isCancellingCommitment = false
                                    if ok { pendingCommitmentCancel = nil }
                                }
                            } label: {
                                Text(isCancellingCommitment ? "正在取消承诺…" : "取消承诺")
                            }
                            .disabled(isCancellingCommitment)
                            .help(isCancellingCommitment ? "正在取消这条承诺" : "")
                            .accessibilityHint(isCancellingCommitment ? "正在取消这条承诺" : "")
                        }
                    }
                }
            }
            else if showInstallConfirm {
                CompanionDialog(title: "安装新版本？", onClose: { if !isInstallingUpdate { showInstallConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(AppUpdateInstallCopy.confirmMessage(version: updates.offer?.version.description ?? "新版本"))
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .failed(let message) = updates.phase {
                            Text(message)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        } else if isInstallingUpdate {
                            Text(updates.statusText)
                                .companionFont(size: 13)
                                .foregroundStyle(.secondary)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { showInstallConfirm = false }
                                .companionBusyHold(isInstallingUpdate, "正在下载或安装新版本")
                            Button {
                                guard !isInstallingUpdate else { return }
                                Task { await updates.installAvailable() }
                            } label: {
                                Text(AppUpdateInstallCopy.actionTitle(phase: updates.phase))
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingUpdate)
                            .help(isInstallingUpdate ? "正在下载或安装新版本" : "")
                            .accessibilityHint(isInstallingUpdate ? "正在下载或安装新版本" : "")
                        }
                    }
                }
            }
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

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection("同步") {
            // Poll interval
            SettingsRow("检查新消息", subtitle: "微信没主动推过来时，隔多久再看一次。改完重启助手后生效。", icon: "clock.arrow.2.circlepath", iconColor: .blue) {
                Picker("检查新消息", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i) 秒" : "\(i/60) 分钟").tag(i)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .companionScaledWidth(92)
                .onChange(of: interval) { save() }
            }

            SettingsRowDivider()

            // Cache strategy
            SettingsRow("聊天读取缓存", subtitle: cacheStrategy.hint + " · 重启助手后生效", icon: "externaldrive", iconColor: .orange) {
                Picker("聊天读取缓存", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .companionScaledWidth(90)
                .onChange(of: cacheStrategy) { save() }
            }

        }
    }

    private var displaySection: some View {
        // Section names the group, row names the setting inside it. These were
        // the same words, so the page stacked the phrase on itself and the
        // header read as a rendering fault rather than as a heading.
        SettingsSection("浮窗位置") {
            SettingsRow("显示在哪块屏幕", subtitle: "选择顶部浮窗所在的屏幕。未连接所选屏幕时使用可用屏幕。", icon: "display", iconColor: CompanionPalette.jade) {
                Picker("显示位置", selection: $displayScreen) {
                    ForEach(DisplayScreen.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .companionScaledWidth(110)
                .onChange(of: displayScreen) { save() }
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
                // It used to open with 已连接微信 even when this very row's own
                // status chip read 待连接.
                detail: "读本机的微信记录，只读不改。",
                status: readingReady ? "已就绪" : "待连接",
                ready: readingReady
            )
            SettingsRowDivider()
            capabilityRow(
                icon: "sparkles",
                title: "AI 整理",
                // The row above no longer spends its line on 待办和约定.
                detail: "从聊天记录里提取待办和约定。",
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
               actionTitle: sendReady ? nil : "打开系统设置",
                actionHoldReason: PreviewRuntime.isEnabled ? "演示界面不会改系统权限" : nil
          ) {
               openAccessibilitySettings()
          }
            if let accessibilitySettingsError {
                Text(accessibilitySettingsError)
                    .companionFont(size: 12)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.companionStatusReveal)
            }
           HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(CompanionPalette.jadeInk)
                Text(Self.connectionFooter(readingReady: readingReady, sendReady: sendReady))
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
            }
           .padding(14)
       }
       .companionSurface(padding: 0)
        .companionAnimation(CompanionMotion.ease(), value: accessibilitySettingsError)
   }

   /// A security warning for the primary connection pane.
    ///
    /// Why this is on the *primary* surface and not with the rest of the key
    /// configuration: the two key problems behave differently. An unrecognised
    /// format makes reading fail, so "读取聊天 待连接" already reports it. Loose
    /// permissions do not — reading works perfectly — so nothing on this pane
    /// would say anything, and a world-readable credential would sit behind a
    /// collapsed "高级连接设置" indefinitely.
    ///
    /// Rendered only when there is something to act on, so the default surface
    /// stays as simple as it was.
    @ViewBuilder
   private var keyPermissionNotice: some View {
       if monitor.reader.keyFilePermissionsAreLoose {
           HStack(alignment: .top, spacing: 10) {
               Image(systemName: "exclamationmark.triangle.fill")
                   .companionFont(size: 12)
                   .foregroundStyle(.orange)
               VStack(alignment: .leading, spacing: 4) {
                   Text("密钥文件权限过宽")
                       .companionFont(size: 13, weight: .semibold)
                    Text("同一台 Mac 上的其他账号也能读到这个文件。收紧后只有你能读，不必重新准备。")
                       .companionFont(size: 12)
                       .foregroundStyle(.secondary)
                       .fixedSize(horizontal: false, vertical: true)
                    if let keyPermissionFixError {
                        Text(keyPermissionFixError)
                            .companionFont(size: 12)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.companionStatusReveal)
                    }
                    Button {
                        tightenKeyPermissions()
                    } label: {
                        Text(isTighteningKeyPermissions ? "正在收紧权限…" : "收紧权限")
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .disabled(isTighteningKeyPermissions || PreviewRuntime.isEnabled)
                    .help(PreviewRuntime.isEnabled ? "演示界面不会改文件权限" : (isTighteningKeyPermissions ? "正在把读取凭证收成仅你可读" : ""))
                    .accessibilityLabel(isTighteningKeyPermissions ? "正在收紧权限" : "收紧权限")
                    .accessibilityHint(PreviewRuntime.isEnabled ? "演示界面不会改文件权限" : (isTighteningKeyPermissions ? "正在把读取凭证收成仅你可读" : ""))
               }
               Spacer(minLength: 0)
           }
            .padding(16)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
           .overlay(
               RoundedRectangle(cornerRadius: 10, style: .continuous)
                   .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
           )
            .companionAnimation(CompanionMotion.ease(), value: keyPermissionFixError)
       }
   }
    private func capabilityRow(
        icon: String,
        title: String,
        detail: String,
        status: String,
       ready: Bool,
       actionTitle: String? = nil,
        actionHoldReason: String? = nil,
       action: (() -> Void)? = nil
   ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .companionFont(size: 14, weight: .medium)
                .foregroundStyle(CompanionPalette.jadeInk)
                .frame(width: 28, height: 28)
                .background(CompanionPalette.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).companionFont(size: 14, weight: .semibold)
                Text(detail)
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Label(status, systemImage: ready ? "checkmark.circle.fill" : "circle")
                    .companionFont(size: 12, weight: .medium)
                    .foregroundStyle(ready ? CompanionPalette.jadeInk : .secondary)
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: 3) {
                            Text(actionTitle)
                            Image(systemName: "chevron.right")
                                .companionFont(size: 10, weight: .semibold)
                        }
                    }
                       .buttonStyle(CompanionPressStyle())
                       .foregroundStyle(CompanionPalette.jadeInk)
                       .companionFont(size: 12, weight: .medium)
                        .disabled(actionHoldReason != nil)
                        .help(actionHoldReason ?? "")
                        .accessibilityHint(actionHoldReason ?? "")
               }
           }
       }
       .padding(16)
    }

    private func legacyRecordsSection(device: DeviceSettingsStore) -> some View {
        SettingsSection("旧版资料") {
            SettingsRow("旧版记录已保留，尚未绑定账号", subtitle: "旧版本没有保存明确的账号归属，当前账号因此使用独立资料库。", icon: "archivebox", iconColor: .orange) {
                   Button("在 Finder 中查看") {
                        revealInFinder(device.legacyStoreURL)
                   }
                if canOfferLegacyBind {
                    Button("绑定到当前账号") { showLegacyBindConfirm = true }
                }
            }
           Text("原资料没有删除，也没有合并到当前账号。只有你已核实目录归属、且当前新账号还没有关注/待办/草稿等资料时，才可显式绑定。绑定不会自动认领，也不会移动或覆盖文件；重启助手后生效。")
               .companionFont(size: 12).foregroundColor(.secondary).padding(14)
            if let finderRevealError {
                Text(finderRevealError)
                    .companionFont(size: 12)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.companionStatusReveal)
            }
       }
        .companionAnimation(CompanionMotion.ease(), value: finderRevealError)
   }

    private var isInstallingUpdate: Bool {
        switch updates.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private var canOfferLegacyBind: Bool {
        guard !monitor.reader.dbDir.isEmpty else { return false }
        return !newAccountStoreHasBusinessData
    }

    private var newAccountStoreHasBusinessData: Bool {
        {
            switch store.whitelistAllRead() {
            case .unreadable: return true
            case .value(let entries): return !entries.isEmpty
            }
        }()
            || !store.loadDrafts().isEmpty
            || !store.loadDiscussionItems().isEmpty
            || !store.loadCommitments().isEmpty
            || !store.loadAIFeedback(msgUIDPrefix: "discussion_item:").isEmpty
            || store.classificationQueueCount() > 0
            || store.getSetting("autopilot")?.isEmpty == false
    }

    @discardableResult
    private func bindLegacyRecords() -> Bool {
        guard let device = store.deviceSettings else { return false }
        do {
            guard try store.updatingSettingJSON(
                    "sync", as: SyncConfig.self, fallback: { SyncConfig() },
                    mutate: { latest in latest.wechatDBPath = monitor.reader.dbDir }) != nil
            else {
                // 读不到旧值就不写：整行覆盖会把用户设的间隔/缓存/显示偏好一起复位
                throw HUDStoreError.sqlError("sync 设置读不到")
            }
            dbPath = monitor.reader.dbDir
            try device.confirmLegacyAccountIdentity(expectedRoot: monitor.reader.dbDir)
            legacyStatus = device.legacyStoreStatus
            saveError = ""
            needsRestart = true
            return true
        } catch {
            saveError = CompanionInteractionCopy.legacyBindFailed
            return false
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
            containsDatabase: { FileManager.default.fileExists(atPath: $0 + "/session/session.db") },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: monitor.reader)
        )
    }

    private var databaseSection: some View {
        SettingsSection("微信账号资料") {
            SettingsRow("本次运行读取", subtitle: monitor.reader.dbDir.isEmpty ? "尚未选定账号资料" : shortenPath(monitor.reader.dbDir), icon: "person.crop.circle", iconColor: .blue) {
                Button("重新检测", action: refreshConnectionDiagnosis)
            }
           SettingsRowDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text(directoryDiagnosis.message)
                    .companionFont(size: 12)
                    .foregroundColor(directoryDiagnosis.needsAttention ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .directoryUnreadable = directoryDiagnosis {
                    if let fullDiskSettingsError {
                        Text(fullDiskSettingsError)
                            .companionFont(size: 12)
                            .foregroundStyle(.red)
                            .transition(.companionStatusReveal)
                    }
                    Button {
                        openFullDiskAccessSettings()
                    } label: {
                        Text("打开完全磁盘访问权限")
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .disabled(PreviewRuntime.isEnabled)
                    .help(PreviewRuntime.isEnabled ? "演示界面不会改系统权限" : "")
                    .accessibilityLabel("打开系统设置中的完全磁盘访问权限")
                    .accessibilityHint(PreviewRuntime.isEnabled ? "演示界面不会改系统权限" : "")
                }
            }
            .padding(14)
            .companionAnimation(CompanionMotion.ease(), value: fullDiskSettingsError)

           if !databaseCandidates.isEmpty {
                ForEach(databaseCandidates, id: \.self) { path in
                    SettingsRowDivider()
                    SettingsRow(accountDirectoryName(path), subtitle: shortenPath(path), icon: "folder", iconColor: .secondary) {
                        if dbPath == path {
                            Label("已选择", systemImage: "checkmark.circle.fill")
                                .companionFont(size: 12).foregroundColor(.green)
                        } else {
                            Button("使用此目录") { dbPath = path; save() }
                        }
                    }
                }
            }
            SettingsRowDivider()
            SettingsRow("下次启动读取", subtitle: "只找到一个账号时可以自动连接；选好具体目录后重启助手生效。") {
                VStack(alignment: .trailing, spacing: 6) {
                    CompanionClipboardField(
                        text: $dbPath,
                        placeholder: "账号资料目录，或 auto（仅一个候选）",
                        kind: .plain,
                        accessibilityLabel: "下次启动读取路径"
                    )
                    .frame(maxWidth: 280)
                    .onChange(of: dbPath) { save() }
                    Button("选择文件夹…", action: chooseDatabaseDirectory)
                }
            }
            SettingsRowDivider()
            SettingsRow("密钥文件", subtitle: keyFileMessage, icon: "key", iconColor: keyFileNeedsAttention ? .orange : .secondary) {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("下次启动：" + (keysFilePath.isEmpty ? "默认路径" : shortenPath(keysFilePath)))
                        .companionFont(size: 12)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button("选择密钥文件…", action: chooseKeyFile)
                            .disabled(PreviewRuntime.isEnabled)
                            .help(PreviewRuntime.isEnabled ? "演示界面不会选择密钥文件" : "")
                            .accessibilityHint(PreviewRuntime.isEnabled ? "演示界面不会选择密钥文件" : "")
                        if !keysFilePath.isEmpty {
                            Button("恢复默认") {
                                keysFilePath = ""
                                keyPathMessage = ""
                                save()
                                refreshConnectionDiagnosis()
                            }
                            .buttonStyle(CompanionPressStyle())
                        }
                    }
                }
            }
            if !keyPathMessage.isEmpty {
                Text(keyPathMessage)
                    .companionFont(size: 12)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .transition(.companionStatusReveal)
            }
            Text("聊天读取缓存按账号资料目录分开。选择目录不会合并账号，也不会证明这份密钥文件属于该账号。请使用与当前微信账号匹配的密钥文件。")
                .companionFont(size: 12).foregroundColor(.secondary).padding(14)
        }
        .companionAnimation(CompanionMotion.ease(), value: keyPathMessage)
    }

    /// True when the key file row should carry a warning.
    ///
   /// Loose permissions are read live rather than cached: a user who runs
    /// 「收紧权限」 to fix the warning must see it clear without a restart.
   private var keyFileNeedsAttention: Bool {
        !keyFileReadable || monitor.reader.keyFilePermissionsAreLoose
    }

    private var keyFileMessage: String {
        let prefix = "本次运行"
        if !keyFileExists { return "\(prefix)：未找到当前连接的密钥文件。请先为这个微信账号准备本机读取凭据，然后再连。" }
        if !keyFileReadable { return "\(prefix)：当前连接的密钥文件不可读，请检查本机文件权限。" }
        if monitor.reader.keyFilePermissionsAreLoose { return "\(prefix)：密钥文件权限过宽，同一台 Mac 上的其他账号也能读到。请用本页上方的「收紧权限」。" }
        return "\(prefix)。密钥文件留在本机；文件能打开不代表内容有效或匹配当前账号，以成功读取为准。"
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
        case .available, .loosePermissions:
            // A loose key file is present and readable; it only needs its
            // permissions tightened. Reporting it as missing would send the
            // user looking for a key they already have.
            keyFileExists = true
           keyFileReadable = true
       }
   }

    private func tightenKeyPermissions() {
        guard !isTighteningKeyPermissions, !PreviewRuntime.isEnabled else { return }
        isTighteningKeyPermissions = true
        keyPermissionFixError = nil
        Task { @MainActor in
            defer { isTighteningKeyPermissions = false }
            let path = monitor.reader.configuredKeysPath
            let wrote = SecureFileManager.ensureFilePermissions(at: path)
            keyPermissionGeneration += 1
            refreshConnectionDiagnosis()
            if wrote, !monitor.reader.keyFilePermissionsAreLoose {
                keyPermissionFixError = nil
            } else {
               keyPermissionFixError = "权限没有收紧。请确认这个文件属于当前账号，然后再试一次。"
           }
       }
   }

    private func openFullDiskAccessSettings() {
        guard !PreviewRuntime.isEnabled else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
              NSWorkspace.shared.open(url) else {
            fullDiskSettingsError = "系统设置未能打开，请从苹果菜单打开系统设置，再允许完全磁盘访问权限。"
            return
        }
       fullDiskSettingsError = nil
   }

    private func openAccessibilitySettings() {
        guard !PreviewRuntime.isEnabled else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            accessibilitySettingsError = "系统设置未能打开，请从苹果菜单打开系统设置，再允许微信操作权限。"
            return
        }
       accessibilitySettingsError = nil
   }

    private func revealInFinder(_ url: URL) {
        if CompanionFinder.reveal(url) {
            finderRevealError = nil
        } else {
            finderRevealError = "没能打开访达，请到文件所在位置查看。"
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
        picker.title = "选择密钥文件"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard WeChatReader.validateKeyFile(at: url.path) else {
            keyPathMessage = "无法使用此文件。请选择一份本机可读的密钥文件。"
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
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            exportReportSection
            retrospectionSection
        }
    }

    private var exportReportSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    sectionHeaderIcon("square.and.arrow.up", color: .blue)
                    Text("导出报告")
                        .companionFont(size: 13, weight: .medium)
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                   if let url = exportedURL {
                        Button("查看文件") { revealInFinder(url) }
                           .controlSize(.small)
                           .buttonStyle(CompanionPressStyle())
                   }
                   Button {
                      if let url = monitor.exportReport() {
                          exportedURL = url
                            exportFailed = false
                          exportMessage = "已导出 \(url.lastPathComponent)"
                      } else {
                           exportedURL = nil
                           exportFailed = true
                           exportMessage = CompanionInteractionCopy.exportToDesktopFailed
                      }
                   } label: {
                        Label("导出到桌面", systemImage: "square.and.arrow.down")
                    }
                    .tint(CompanionPalette.jade)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Text(LocalDataRetrospection.exportCaption)
                    .companionFont(size: 12)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                if let msg = exportMessage {
                    HStack(spacing: 8) {
                        Image(systemName: exportFailed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .foregroundStyle(exportFailed ? Color.red : CompanionPalette.jadeInk)
                        Text(msg)
                            .companionFont(size: 12)
                            .foregroundColor(exportFailed ? .red : .secondary)
                       if let url = exportedURL, !exportFailed {
                            Button("查看文件") { revealInFinder(url) }
                               .buttonStyle(CompanionPressStyle())
                               .foregroundStyle(CompanionPalette.jadeInk)
                       } else if exportFailed {
                            Button("打开桌面") {
                                if !CompanionFinder.openDesktop() {
                                    finderRevealError = "没能打开桌面。请到访达里查看桌面。"
                                }
                            }
                            .buttonStyle(CompanionPressStyle())
                            .foregroundStyle(CompanionPalette.jadeInk)
                       }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                   .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                   .transition(.companionStatusReveal)
               }
                if let finderRevealError {
                    Text(finderRevealError)
                        .companionFont(size: 12)
                        .foregroundStyle(.red)
                        .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                        .transition(.companionStatusReveal)
                }
           }
           .companionAnimation(CompanionMotion.ease(), value: exportMessage)
            .companionAnimation(CompanionMotion.ease(), value: finderRevealError)
       }
   }

   private var retrospectionSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        sectionHeaderIcon("clock.arrow.circlepath", color: CompanionPalette.jadeInk)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("记录回溯")
                                .companionFont(size: 13, weight: .medium)
                            Text(LocalDataRetrospection.windowCaption)
                                .companionFont(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        CompanionClipboardField(
                            text: $dataSearch,
                            placeholder: "搜索标题、联系人或内容",
                            kind: .plain,
                            accessibilityLabel: "搜索整理过的记录"
                        )
                        .frame(maxWidth: 240)
                    }
                    HStack(spacing: 8) {
                        ForEach(DataSection.allCases, id: \.self) { section in
                            CompanionFilterPill(title: section.rawValue, selected: selectedSection == section, tint: SettingsView.Tab.system.accentColor) {
                                selectedSection = section
                                reloadData()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                SettingsRowDivider()
                switch selectedSection {
                case .recalls:     recallsList
                case .commitments: commitmentsList
                case .pendingAsks: pendingAsksList
                }
            }
        }
    }

    private func sectionHeaderIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .companionFont(size: 13)
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
                        Text(msg.senderRole.icon).companionFont(size: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(msg.senderName)
                                    .companionFont(size: 13, weight: .medium)
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text(msg.chatName)
                                    .companionFont(size: 12)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(msg.recallDelaySeconds) 秒后撤回")
                                    .companionFont(size: 11)
                                    .foregroundColor(.orange)
                            }
                            Text("「\(msg.originalText)」")
                                .companionFont(size: 13)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = msg.aiReason {
                                HStack(spacing: 4) {
                                    pill(reason, color: msg.aiIntelligenceValue == "high" ? .red : .gray)
                                    if let d = msg.aiDetail, !d.isEmpty {
                                        Text(d).companionFont(size: 11).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                            }
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
                emptyRow(LocalDataRetrospection.emptyCommitments)
            } else {
                ForEach(commitments.filter { matchesDataSearch($0.content, $0.commitTo) }) { item in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(commitmentColor(item))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.content)
                                .companionFont(size: 13, weight: .medium)
                            HStack(spacing: 6) {
                                Text("→ \(item.commitTo)")
                                    .companionFont(size: 12)
                                    .foregroundColor(.secondary)
                                if item.status == .fulfilled {
                                    Text("已完成")
                                        .companionFont(size: 12)
                                        .foregroundColor(CompanionPalette.jadeInk)
                                } else if item.status == .pending || item.status == .overdue, let d = item.deadlineAt {
                                    Text(CommitmentPresentation.deadlineCaption(d))
                                        .companionFont(size: 12)
                                        .foregroundColor(d < Date() ? .red : .secondary)
                                }
                            }
                        }
                        Spacer()
                        if item.status == .pending {
                            // Sized and coloured for what they do.
                            //
                            // Measured at 34×13pt with 8.5pt between them, and
                            // 取消 was plain secondary grey — a mis-click
                            // away from 完成, discarding a commitment the app
                            // tracked from the user's own message, with no
                            // confirmation. macOS asks for two things here and
                            // this had neither: a target the pointer can hit,
                            // and a red, confirmed destructive action.
                            Button("完成") {
                                mutateData { try store.updateCommitmentStatus(msgUID: item.msgUID, status: .fulfilled) }
                            }
                            .controlSize(.small)
                            .frame(minHeight: 22)
                            Button("取消", role: .destructive) {
                                pendingCommitmentCancel = item
                            }
                            .controlSize(.small)
                            .frame(minHeight: 22)
                            .foregroundColor(.red)
                        } else {
                            Text(commitmentStatusLabel(item.status))
                                .companionFont(size: 12)
                                .foregroundColor(item.status == .fulfilled ? CompanionPalette.jadeInk : .secondary)
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
                emptyRow(LocalDataRetrospection.emptyPendingAsks)
            } else {
                ForEach(pendingAsks.filter { matchesDataSearch($0.senderName, $0.chatName, $0.summary) }) { ask in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(urgencyColor(ask))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if let role = ask.senderRole { Text(role.icon).companionFont(size: 12) }
                                Text(ask.senderName).companionFont(size: 13, weight: .medium)
                                Text(ask.chatName).companionFont(size: 12).foregroundColor(.secondary)
                            }
                            Text(ask.summary)
                                .companionFont(size: 13)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 4) {
                                pill(ask.askType.label, color: .blue)
                                Text(String(format: "%.0f%%", ask.confidence * 100))
                                    .companionFont(size: 11).foregroundColor(.secondary)
                                Text(MessageInfo.formatRelative(Int(ask.createdAt.timeIntervalSince1970)))
                                    .companionFont(size: 11).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if ask.status == .pending {
                            Button("已处理") {
                                mutateData { try store.updatePendingAskStatus(msgUID: ask.msgUID, status: .done) }
                            }
                            .controlSize(.small)
                            .frame(minHeight: 22)
                            Button("忽略") {
                                mutateData { try store.dismissPendingAsk(msgUID: ask.msgUID) }
                            }
                            .controlSize(.small)
                            .frame(minHeight: 22)
                        } else {
                            Text(ask.status.rawValue).companionFont(size: 12).foregroundColor(.secondary)
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

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .companionFont(size: 13)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .companionFont(size: 11, weight: .medium)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func commitmentStatusLabel(_ status: CommitmentStatus) -> String {
        switch status {
        case .pending: return "进行中"
        case .fulfilled: return "已完成"
        case .overdue: return "已到期"
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
            saveError = "同步设置保存失败，请重试。"
            syncSaveFailed = true
        }
    }

    @discardableResult
    private func mutateData(_ operation: () throws -> Int) -> Bool {
        do {
            let changes = try operation()
            guard changes > 0 else {
                saveError = "操作未保存，请重试。原记录仍保留。"
                return false
            }
            saveError = ""
            reloadData()
            monitor.refreshNow()
            return true
        } catch {
            saveError = "操作未保存，请重试。原记录仍保留。"
            return false
        }
    }

    private func reloadData() {
        let snapshot = LocalDataRetrospection.load(store: store)
        switch selectedSection {
        case .recalls:     recalledMessages = snapshot.recalls
        case .commitments: commitments = snapshot.commitments
        case .pendingAsks: pendingAsks = snapshot.pendingAsks
        }
    }
}

/// 本地资料 is "近两周整理过的事情". Load windows and empty copy must
/// use the same 14-day cutoff as 待办, not the whole sqlite history.
enum LocalDataRetrospection {
    static let windowDays = DiscussionLiveWindow.pendingDays
    static let exportCaption = "导出一份状态报告到桌面：统计数字之外，还包含待回复与撤回消息的原文片段。文件权限设为只有本账户可读。"
    static let windowCaption = "只看近 \(windowDays) 天整理过的记录。更早的已收起。"
    static let emptyRecalls = "近两周没有撤回记录"
    static let emptyCommitments = "近两周没有记下的承诺"
    static let emptyPendingAsks = "近两周没有未处理的提问"

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
