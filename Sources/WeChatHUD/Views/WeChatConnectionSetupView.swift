import AppKit
import SwiftUI

/// Surfaced through the existing 「连接设置没有保存成功，请重试。」 channel: refusing to
/// save is better than saving factory values over a record this app could not read.
enum ConnectionPersistenceError: Error {
    case currentSettingsUnreadable
}

@MainActor
enum ConnectionSetupFlow {
    /// Apply a connection root without discarding settings edited elsewhere
    /// since this view last hydrated its local state.
    nonisolated static func configurationUpdatingRoot(_ root: String, from configuration: SyncConfig) -> SyncConfig {
        var updated = configuration
        updated.wechatDBPath = root
        return updated
    }

    /// Waits for the current-process probe before deciding whether an
    /// unconfigured connection may be persisted. Explicit choices always
    /// win and never get replaced by process evidence.
    static func prepareRoot(
        configuredRoot: String?,
        candidateRoots: [String],
        processProbe: () async -> [String],
        persist: (String) throws -> Void
    ) async throws -> String? {
        if case .useConfiguredRoot(let root) = ConnectionSetupPolicy.resolve(
            configuredRoot: configuredRoot, candidateRoots: [], processRoots: []
        ) {
            return root
        }

        let observed = await processProbe()
        guard observed.count == 1 else { return nil }
        guard case .useProcessEvidence(let root) = ConnectionSetupPolicy.resolve(
            configuredRoot: nil, candidateRoots: candidateRoots, processRoots: observed
        ) else { return nil }
        try persist(root)
        return root
    }
}

/// The same connection task is used in first launch and ongoing settings.
/// A picker grants access; only the monitor's successful read completes setup.
struct WeChatConnectionSetupView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var candidates: [String] = []
    @State private var configuration = SyncConfig()
    @State private var showAccounts = false
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var revision = 0
    @State private var processRoots: [String] = []
    @State private var processEvidenceToken = UUID()
    @State private var probing = false
    @State private var showPreparationConsent = false
    @State private var showChangeAccountConfirm = false
    @State private var changeAccountReceipt: String?
    @State private var isChangingAccount = false
    @State private var preparationToken = UUID()
    @State private var isStartingPreparation = false
    @StateObject private var keyPreparation = WeChatKeyPreparationService()

    private var wechatURL: URL? {
        ["com.tencent.xinWeChat", "com.tencent.WeChat"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    private var wechatRunning: Bool {
        runningWeChatApplication != nil
    }

    private var runningWeChatApplication: NSRunningApplication? {
        ["com.tencent.xinWeChat", "com.tencent.WeChat"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first { !$0.isTerminated && $0.launchDate != nil }
    }

    private var selectedRoot: String? {
        // With no explicit choice, only a verified, single process root may
        // be handed to the policy. An empty evidence set intentionally
        // prevents a unique on-disk directory from being guessed as active.
        let evidenceCandidates = processRoots.isEmpty ? [] : candidates
        switch ConnectionSetupPolicy.resolve(configuredRoot: configuration.wechatDBPath,
                                             candidateRoots: evidenceCandidates, processRoots: processRoots) {
        case .useConfiguredRoot(let root), .useProcessEvidence(let root), .useUniqueCandidate(let root): return root
        default: return nil
        }
    }

    private var accessReady: Bool {
        guard !PreviewRuntime.isEnabled else { return false }
        _ = revision
        guard let root = selectedRoot else { return false }
        return FileManager.default.isReadableFile(atPath: root)
            && FileManager.default.fileExists(atPath: root + "/session/session.db")
    }

    private var preparationReady: Bool {
        guard !PreviewRuntime.isEnabled else { return false }
        let path = configuration.keysFilePath ?? NSHomeDirectory() + "/.wechat-cli/all_keys.json"
        return WeChatReader.validateKeyFile(at: path)
    }

    private var requiresRestart: Bool {
        guard !PreviewRuntime.isEnabled else { return false }
        guard let root = selectedRoot else { return false }
        let canonical = WeChatAccountEvidence.canonicalRoot
        let pendingKeys = configuration.keysFilePath ?? NSHomeDirectory() + "/.wechat-cli/all_keys.json"
        return canonical(root) != canonical(monitor.reader.dbDir)
            || canonical(pendingKeys) != canonical(monitor.reader.configuredKeysPath)
    }

    private var connected: Bool {
        if PreviewRuntime.isEnabled {
            if case .ok = monitor.stats.syncStatus, monitor.stats.lastSyncAt != nil { return true }
            return false
        }
        guard accessReady, !requiresRestart, monitor.stats.lastSyncAt != nil else { return false }
        if case .ok = monitor.stats.syncStatus { return true }
        return false
    }

    private var syncing: Bool {
        if case .syncing = monitor.stats.syncStatus { return true }
        return false
    }

    private var syncFailed: Bool {
        guard accessReady, !requiresRestart else { return false }
        if case .error = monitor.stats.syncStatus { return true }
        return false
    }

    private var needsAccountSelection: Bool {
        ConnectionSetupPolicy.needsAccountSelection(
            selectedRoot: selectedRoot,
            readerRoot: monitor.reader.dbDir,
            syncStatus: monitor.stats.syncStatus
        )
    }

    /// Access is granted but the decrypted-reading material is not prepared
    /// yet. This used to be a dead end; it now drives the guided flow below.
    private var preparationNeeded: Bool {
        guard !PreviewRuntime.isEnabled else { return false }
        return accessReady && !preparationReady
    }

    private var preparationFlowBusy: Bool {
        switch keyPreparation.phase {
        case .waitingForWeChatRelogin, .extracting, .succeeded: return true
        default: return false
        }
    }

    private var canCancelPreparation: Bool {
        switch keyPreparation.phase {
        case .waitingForWeChatRelogin, .extracting: return true
        default: return false
        }
    }

    private var primaryHoldReason: String? {
        if applying { return "正在应用连接" }
        if probing { return "正在检测微信账号" }
        if syncing { return "正在读取聊天" }
        switch keyPreparation.phase {
        case .waitingForWeChatRelogin: return "正在等微信重新登录"
        case .extracting: return "正在准备密钥文件"
        case .succeeded: return "准备已完成"
        default: return nil
        }
    }

    private var hasConfiguredSelection: Bool {
        ConnectionSetupPolicy.hasConfiguredRoot(configuration.wechatDBPath)
    }

    private var launchState: FirstLaunchGuide.ConnectionState {
        if applying { return .applying }
        if probing { return .probing }
        if syncing { return .syncing }
        if connected { return .connected }
        if wechatURL == nil && !PreviewRuntime.isEnabled { return .wechatNotInstalled }
        if !wechatRunning && !PreviewRuntime.isEnabled { return .wechatNotRunning }
        if preparationNeeded {
            switch keyPreparation.phase {
            case .waitingForWeChatRelogin: return .preparingWaitingRelogin
            case .extracting: return .preparingExtracting
            case .failed: return .preparingFailed
            default: return .preparingIdle
            }
        }
        if accessReady && preparationReady && requiresRestart { return .readyToRestart }
        if needsAccountSelection { return .needsAccountSelection }
        if syncFailed { return .syncFailed }
        return .idle
    }

    private var preparationFailureReason: String? {
        if case .failed(let reason) = keyPreparation.phase { return reason }
        return nil
    }

    private var connectionCopy: FirstLaunchGuide.ConnectionCopy {
        FirstLaunchGuide.connection(
            state: launchState,
            wechatRunning: wechatRunning || PreviewRuntime.isEnabled,
            accessReady: accessReady,
            connected: connected,
            preparationSigned: preparationSigned,
            preparationReloginComplete: preparationReloginComplete,
            preparationExtractComplete: preparationExtractComplete,
            failureReason: preparationFailureReason
        )
    }

    private var title: String { connectionCopy.title }
    private var detail: String { connectionCopy.detail }
    private var buttonTitle: String { connectionCopy.buttonTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: connected ? "checkmark.bubble.fill" : "bubble.left.and.bubble.right.fill")
                    .font(.system(size: WorkspaceType.display, weight: .medium))
                    .foregroundStyle(CompanionPalette.accent)
                    .frame(width: 48, height: 48)
                    .background(CompanionPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !connected {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(connectionCopy.checkpoints.enumerated()), id: \.offset) { _, item in
                        checkpoint(item.title, complete: item.complete)
                    }
                }
            } else if let date = monitor.stats.lastSyncAt {
                VStack(alignment: .leading, spacing: 4) {
                    if PreviewRuntime.isEnabled {
                        Text("演示数据 · 林晓")
                            .font(.callout.weight(.medium))
                    }
                    Label("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if preparationNeeded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(connectionCopy.preparationCheckpoints.enumerated()), id: \.offset) { _, item in
                            checkpoint(item.title, complete: item.complete)
                        }
                    }
                    if canCancelPreparation {
                        Button("取消") { cancelPreparation() }
                            .buttonStyle(CompanionPressStyle())
                            .help("停止这次准备")
                            .accessibilityLabel("取消准备")
                            .accessibilityHint("停止等待微信重新登录或停止准备密钥文件，连接尚未完成")
                    }
                }
            }

            if showAccounts {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择要连接的微信账号").font(.callout.weight(.medium))
                    ForEach(candidates, id: \.self) { root in
                        Button {
                            select(root)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                Text(URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(CompanionRowPressStyle())
                    }
                }
                .transition(.companionStatusReveal)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.companionStatusReveal)
            }

            HStack(spacing: 12) {
                Button(buttonTitle) { performPrimaryAction() }
                    .tint(CompanionPalette.accent)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large).disabled(applying || syncing || probing || preparationFlowBusy)
                    .help(primaryHoldReason ?? "")
                    .accessibilityHint(primaryHoldReason ?? "")
                    .accessibilityIdentifier("connection.setup.primary")
                if PreviewRuntime.isEnabled || (hasConfiguredSelection && !needsAccountSelection) {
                    Button("更换微信账号") { showChangeAccountConfirm = true }
                        .buttonStyle(CompanionPressStyle())
                        .disabled(applying || syncing || probing)
                        // The scope sentence used to be printed here in
                        // permanent caption text *and* verbatim inside the
                        // confirm dialog. The dialog is where it is needed.
                        .help(primaryHoldReason ?? "新账号只读自己的聊天；已整理的待办、草稿和关注名单按账号分开，不会混用旧账号的操作目标。")
                        .accessibilityHint(primaryHoldReason ?? "新账号只读自己的聊天；已整理的待办、草稿和关注名单按账号分开，不会混用旧账号的操作目标。")
                        .accessibilityIdentifier("connection.change-account")
                }
                Spacer(minLength: 0)
            if applying || syncing || probing || preparationFlowBusy { ProgressView().controlSize(.small) }
            }
            Text("连接步骤只用于读取聊天。AI 分析使用你在设置中选择的服务。")
                .font(.caption).foregroundStyle(.secondary)
            if PreviewRuntime.isEnabled {
                Text("演示界面 · 不读取真实微信，也不申请权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let changeAccountReceipt {
                Text(changeAccountReceipt)
                    .font(.caption)
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: connected)
        .companionAnimation(CompanionMotion.drawer(), value: showAccounts)
        .companionAnimation(CompanionMotion.ease(), value: errorMessage)
        .companionAnimation(CompanionMotion.ease(), value: changeAccountReceipt)
        .companionDialogBackdrop(showChangeAccountConfirm || showPreparationConsent) {
            if showChangeAccountConfirm {
                CompanionDialog(title: "更换微信账号？", onClose: { if !isChangingAccount { showChangeAccountConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("更换后只读取新账号的聊天。已整理的待办、草稿和关注名单按账号分开，不会混用旧账号的操作目标。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("先不换") { showChangeAccountConfirm = false }
                                .companionBusyHold(isChangingAccount, "正在选择新的微信账号资料")
                            Button {
                                guard !isChangingAccount else { return }
                                isChangingAccount = true
                                if PreviewRuntime.isEnabled {
                                    changeAccountReceipt = "演示：更换后资料按账号分开保存，不会读取或混用真实微信。"
                                    showChangeAccountConfirm = false
                                } else if authorizeDirectory(changeAccount: true) {
                                    showChangeAccountConfirm = false
                                }
                                isChangingAccount = false
                            } label: {
                                Text(isChangingAccount ? "正在更换账号…" : "继续更换")
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isChangingAccount)
                            .help(isChangingAccount ? "正在选择新的微信账号资料" : "")
                            .accessibilityHint(isChangingAccount ? "正在选择新的微信账号资料" : "")
                        }
                    }
                }
            }
            else if showPreparationConsent {
                CompanionDialog(title: connectionCopy.consentTitle, onClose: { if !isStartingPreparation { showPreparationConsent = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(connectionCopy.consentMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("暂不") { showPreparationConsent = false }
                                .companionBusyHold(isStartingPreparation, "正在开始本机读取准备")
                            Button {
                                guard !isStartingPreparation else { return }
                                isStartingPreparation = true
                                startPreparationFlow()
                                isStartingPreparation = false
                                showPreparationConsent = false
                            } label: {
                                Text(isStartingPreparation ? "正在开始准备…" : "开始准备")
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isStartingPreparation)
                            .help(isStartingPreparation ? "正在开始本机读取准备" : "")
                            .accessibilityHint(isStartingPreparation ? "正在开始本机读取准备" : "")
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .hudConnectionConfigurationDidChange)) { _ in refresh() }
    }

    private func checkpoint(_ text: String, complete: Bool) -> some View {
        Label(text, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(.callout.weight(.medium))
            .foregroundStyle(complete ? CompanionPalette.accent : Color.secondary)
    }

    private var preparationSigned: Bool {
        switch keyPreparation.phase {
        case .waitingForWeChatRelogin, .extracting, .needsResignAgain, .succeeded: return true
        default: return false
        }
    }

    private var preparationReloginComplete: Bool {
        switch keyPreparation.phase {
        case .extracting, .succeeded: return true
        default: return false
        }
    }

    private var preparationExtractComplete: Bool {
        if case .succeeded = keyPreparation.phase { return true }
        return false
    }

    private func refresh() {
        configuration = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        candidates = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        beginProcessEvidenceProbe(candidateRoots: candidates)
        revision += 1
    }

    private func beginProcessEvidenceProbe(candidateRoots: [String]) {
        let token = UUID()
        processEvidenceToken = token
        processRoots = []
        guard !PreviewRuntime.isEnabled,
              let application = runningWeChatApplication,
              let launchDate = application.launchDate else { return }

        let processID = application.processIdentifier
        Task { @MainActor in
            let observed = await WeChatAccountEvidence.inspectRoots(processID: processID)
            guard token == processEvidenceToken,
                  let current = Self.runningWeChatApplication(processID: processID),
                  WeChatAccountEvidence.processMatches(
                    expectedPID: processID,
                    expectedLaunch: launchDate,
                    actualPID: current.processIdentifier,
                    actualLaunch: current.launchDate,
                    terminated: current.isTerminated
                  ) else { return }

            let normalizedCandidates = Set(candidateRoots.map(WeChatAccountEvidence.canonicalRoot))
            guard observed.count == 1,
                  let root = observed.first,
                  normalizedCandidates.contains(WeChatAccountEvidence.canonicalRoot(root)) else { return }
            processRoots = [WeChatAccountEvidence.canonicalRoot(root)]
            revision += 1
        }
    }

    private static func runningWeChatApplication(processID: pid_t) -> NSRunningApplication? {
        ["com.tencent.xinWeChat", "com.tencent.WeChat"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first { $0.processIdentifier == processID && !$0.isTerminated && $0.launchDate != nil }
    }

    private func performPrimaryAction() {
        guard !PreviewRuntime.isEnabled else {
            NotificationCenter.default.post(name: .hudOnboardingAdvance, object: nil)
            errorMessage = "演示里不会读取真实微信。正式使用时，这里会打开系统授权。"
            return
        }
       errorMessage = nil
       guard let wechatURL else {
            if let url = URL(string: "https://mac.weixin.qq.com/"), NSWorkspace.shared.open(url) {
                return
            }
            errorMessage = "没能打开微信下载页。请从“应用程序”安装微信，或在浏览器打开 mac.weixin.qq.com。"
            return
       }
        guard wechatRunning else {
            NSWorkspace.shared.openApplication(at: wechatURL, configuration: .init()) { _, error in
                Task { @MainActor in
                    if error != nil { errorMessage = "微信没有打开，请从“应用程序”打开微信后再试。" }
                }
            }
            return
        }
        if needsAccountSelection {
            authorizeDirectory(changeAccount: true)
            return
        }
        guard !probing else { return }
        refresh()
        let candidateSnapshot = candidates
        probing = true
        Task { @MainActor in
            defer { probing = false }
            do {
                let root = try await ConnectionSetupFlow.prepareRoot(
                    configuredRoot: configuration.wechatDBPath,
                    candidateRoots: candidateSnapshot,
                    processProbe: { await Self.probeProcessEvidence(candidateRoots: candidateSnapshot) },
                    persist: { root in try persistRoot(root) }
                )
                processRoots = root.map { [$0] } ?? []
                revision += 1
                guard let root else {
                    authorizeDirectory(changeAccount: false)
                    return
                }
                _ = root
                guard accessReady else {
                    authorizeDirectory(changeAccount: false)
                    return
                }
                guard preparationReady else {
                    showPreparationConsent = true
                    return
                }
                if requiresRestart {
                    applying = true
                    do { try await AppRestartController.restart() }
                    catch {
                        errorMessage = FirstLaunchGuide.userFacingPreparationError(error.localizedDescription)
                        applying = false
                    }
                } else {
                    monitor.refreshNow()
                }
            } catch {
                errorMessage = "连接设置没有保存成功，请重试。"
            }
        }
    }

    @discardableResult
    private func authorizeDirectory(changeAccount: Bool) -> Bool {
        guard !PreviewRuntime.isEnabled else { return false }
        let picker = NSOpenPanel()
        picker.title = FirstLaunchGuide.pickerTitle
        picker.message = FirstLaunchGuide.pickerMessage
        picker.prompt = "允许读取"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        let base = NSHomeDirectory() + "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
        picker.directoryURL = URL(fileURLWithPath: changeAccount ? base : (selectedRoot ?? base))
        guard picker.runModal() == .OK, let url = picker.url else { return false }
        let roots: [String]
        if FileManager.default.fileExists(atPath: url.path + "/session/session.db") {
            roots = [url.path]
        } else if FileManager.default.fileExists(atPath: url.path + "/db_storage/session/session.db") {
            roots = [url.path + "/db_storage"]
        } else {
            roots = WeChatReader.databaseCandidates(baseDirectory: url.path)
        }
        guard !roots.isEmpty else {
            errorMessage = FirstLaunchGuide.pickerMiss
            return false
        }
        candidates = roots
        if roots.count == 1, let root = roots.first {
            return select(root)
        } else {
            withMotion(CompanionMotion.drawer()) { showAccounts = true }
            return true
        }
    }

    @discardableResult
    private func select(_ root: String) -> Bool {
        do {
            try persistRoot(root)
            withMotion(CompanionMotion.drawer()) { showAccounts = false }
            errorMessage = nil
            revision += 1
            if preparationReady {
                if !requiresRestart { monitor.refreshNow() }
            }
            return true
        } catch {
            errorMessage = "连接设置没有保存成功，请重试。"
            return false
        }
    }

    private func persistRoot(_ root: String) throws {
        // SyncSettingsView owns interval/cache/display preferences and may
        // have saved them while this child view was open. Re-read the latest
        // record before changing only the account root — and if that read fails,
        // save nothing rather than writing factory values over the user's own.
        guard let candidateConfiguration = try store.updatingSettingJSON(
                "sync", as: SyncConfig.self, fallback: { SyncConfig() },
                mutate: { latest in
                    latest = ConnectionSetupFlow.configurationUpdatingRoot(root, from: latest)
                })
        else {
            throw ConnectionPersistenceError.currentSettingsUnreadable
        }
        configuration = candidateConfiguration
        withMotion(CompanionMotion.drawer()) { showAccounts = false }
        errorMessage = nil
        NotificationCenter.default.post(name: .hudConnectionConfigurationDidChange, object: nil)
    }

    // MARK: - Guided key preparation

    private func startPreparationFlow() {
        guard !PreviewRuntime.isEnabled else { return }
        preparationToken = UUID()
        let token = preparationToken
        Task { @MainActor in
            await runPreparationFlow(token: token)
        }
    }

    private func cancelPreparation() {
        preparationToken = UUID()
        keyPreparation.setPhase(.idle)
    }

    private func runPreparationFlow(token: UUID) async {
        guard !PreviewRuntime.isEnabled else { return }
        guard let appURL = wechatURL else {
            keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError("没有找到微信")))
            return
        }
        guard let root = selectedRoot else {
            keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError("还没有选定微信账号资料。")))
            return
        }
        guard let binary = Bundle.main.url(
            forResource: "find_all_keys_macos.arm64",
            withExtension: nil,
            subdirectory: "keytools") else {
            keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError("准备组件没有随应用安装")))
            return
        }

        do {
            var dbRoot = root
            let alreadyEntitled = await keyPreparation.checkWeChatEntitlement(appPath: appURL.path)
            if !alreadyEntitled {
                let resignClock = Date()
                try await keyPreparation.resignWeChat(appPath: appURL.path)
                keyPreparation.setPhase(.waitingForWeChatRelogin)
                guard token == preparationToken else { return }
                guard let evidenceRoot = await awaitFreshWeChatRelogin(
                    since: resignClock, token: token) else { return }
                dbRoot = evidenceRoot
                if WeChatAccountEvidence.canonicalRoot(evidenceRoot) != WeChatAccountEvidence.canonicalRoot(root) {
                    try persistRoot(evidenceRoot)
                }
            }

            guard token == preparationToken else { return }
            guard let keysPath = try await extractAndStore(
                binary: binary, dbRoot: dbRoot, appPath: appURL.path, token: token) else { return }
            try persistKeysPath(keysPath)
            keyPreparation.setPhase(.succeeded(keysPath: keysPath))
            revision += 1

            if requiresRestart {
                applying = true
                do { try await AppRestartController.restart() }
                catch {
                    errorMessage = FirstLaunchGuide.userFacingPreparationError(error.localizedDescription)
                    applying = false
                }
            } else {
                monitor.refreshNow()
            }
        } catch {
            keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError(error.localizedDescription)))
        }
    }

    /// Extract, verify, store. A task_for_pid failure triggers one more
    /// resign + relogin round before giving up.
    private func extractAndStore(
        binary: URL,
        dbRoot: String,
        appPath: String,
        token: UUID
    ) async throws -> String? {
        let workDir = (dbRoot as NSString).deletingLastPathComponent
        var outcome = try await keyPreparation.runExtraction(binaryURL: binary, workDir: workDir)
        while true {
            switch outcome {
            case .extracted(let rawKeys):
                do {
                    return try keyPreparation.verifyAndStore(rawKeys: rawKeys, dbRoot: dbRoot)
                } catch {
                    keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError(error.localizedDescription)))
                    return nil
                }
            case .needsResignAgain:
                let resignClock = Date()
                try await keyPreparation.resignWeChat(appPath: appPath)
                keyPreparation.setPhase(.waitingForWeChatRelogin)
                guard token == preparationToken else { return nil }
                guard let evidenceRoot = await awaitFreshWeChatRelogin(
                    since: resignClock, token: token) else { return nil }
                guard token == preparationToken else { return nil }
                keyPreparation.setPhase(.extracting)
                let retried = try await keyPreparation.runExtraction(
                    binaryURL: binary, workDir: (evidenceRoot as NSString).deletingLastPathComponent)
                if case .needsResignAgain = retried {
                    keyPreparation.setPhase(.failed(reason: "微信重新签名后仍无法读取，请重启助手后再试一次。"))
                    return nil
                }
                outcome = retried
            }
        }
    }

    /// How long the re-login wait polls. Each tick spawns an `lsof`, and the
    /// driving `Task` handle is discarded, so nothing else can end a wait the
    /// user walked away from — without a deadline an abandoned 「等待微信重新
    /// 登录」 leaves the 24/7 overlay polling every 2 s for the rest of the
    /// session. 10 minutes is generous for re-entering a WeChat password.
    static let reloginWaitSeconds = 600

    /// Polls for a WeChat process launched after the resign timestamp and
    /// confirms the fresh process carries exactly one account root. Returns
    /// the observed root, or nil when the user cancels or the wait expires.
    private func awaitFreshWeChatRelogin(since mark: Date, token: UUID) async -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(Self.reloginWaitSeconds))
        var timedOut = false
        while !Task.isCancelled {
            guard Date() < deadline else { timedOut = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard token == preparationToken else { return nil }
            guard let application = runningWeChatApplication,
                  let launchDate = application.launchDate,
                  launchDate > mark else { continue }
            let observed = await WeChatAccountEvidence.inspectRoots(processID: application.processIdentifier)
            guard token == preparationToken,
                  observed.count == 1,
                  let root = observed.first else { continue }
            return WeChatAccountEvidence.canonicalRoot(root)
        }
        if timedOut, token == preparationToken {
            // Leaving the phase at `.waitingForWeChatRelogin` would keep the
            // page claiming a wait that already stopped.
            keyPreparation.setPhase(.failed(reason: FirstLaunchGuide.userFacingPreparationError(
                "等了 10 分钟还没有等到微信重新登录，已停止等待。重新登录微信后再点一次「开始准备」。"
            )))
        }
        return nil
    }

    private func persistKeysPath(_ path: String) throws {
        guard let updated = try store.updatingSettingJSON(
                "sync", as: SyncConfig.self, fallback: { SyncConfig() },
                mutate: { latest in latest.keysFilePath = path })
        else {
            throw ConnectionPersistenceError.currentSettingsUnreadable
        }
        configuration = updated
        NotificationCenter.default.post(name: .hudConnectionConfigurationDidChange, object: nil)
    }

    private static func probeProcessEvidence(candidateRoots: [String]) async -> [String] {
        guard let application = runningWeChatApplication(),
              let launchDate = application.launchDate else { return [] }
        let processID = application.processIdentifier
        let observed = await WeChatAccountEvidence.inspectRoots(processID: processID)
        guard let current = runningWeChatApplication(processID: processID),
              WeChatAccountEvidence.processMatches(
                expectedPID: processID,
                expectedLaunch: launchDate,
                actualPID: current.processIdentifier,
                actualLaunch: current.launchDate,
                terminated: current.isTerminated
              ),
              observed.count == 1,
              let root = observed.first,
              Set(candidateRoots.map(WeChatAccountEvidence.canonicalRoot))
                .contains(WeChatAccountEvidence.canonicalRoot(root)) else { return [] }
        return [WeChatAccountEvidence.canonicalRoot(root)]
    }

    private static func runningWeChatApplication() -> NSRunningApplication? {
        ["com.tencent.xinWeChat", "com.tencent.WeChat"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first { !$0.isTerminated && $0.launchDate != nil }
    }
}

extension Notification.Name {
    static let hudConnectionConfigurationDidChange = Notification.Name("hudConnectionConfigurationDidChange")
}
