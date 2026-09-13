import SwiftUI

/// One place for this page's promises.
///
/// The group-chat rule used to be stated as two different promises in this
/// one file, only one of which matched the send gate. The behaviour these
/// strings must describe is fixed by ChatMonitor: a group reply is always
/// held for manual confirmation, so it can exist as a draft and can never be
/// sent unattended.
enum AutopilotSettingsCopy {
    static let autoSendTitle = "自动发出去"
    static let autoSendOn = "够把握就发出去。"
    static let autoSendOff = "只写草稿，确认后发送。"

    static let groupAtTitle = "群里 @我 时也准备回复"
    static let groupRule = "群聊默认只记录；打开上面的开关后只写待确认草稿，不会自动发出。"
    static let groupAtOff = "群消息默认只记录，不写回复。"

    static let confidenceTitle = "多有把握才发出去"
    static let confidenceHint = "不到这个数只写草稿。群聊、转账、红包仍要你确认。"
    static let perHourTitle = "每小时最多"
    static let perHourHint = "每小时发送上限。"
    static let sessionTitle = "本次整理最多"
    static let sessionHint = "本次整理期间最多自动发送的条数。"

    static let alwaysManualTitle = "哪些一定交给你"
    static let alwaysManualRule = "群聊、转账、红包、小程序不会自动发送。其他敏感内容需人工确认。"
    static let replyStyleTitle = "回复风格"

    /// The batch option is a window in seconds, not a message count. The old
    /// "连着几条一起回" title read as "reply after N messages", which is not
    /// what `batchWindowSeconds` does.
    static let batchTitle = "连发时等几秒一起回"
    static let batchHint = "连续几条消息会先等这个时长，再合成一次回复。单位是秒，不是条数。"

    static func excludedTitle(count: Int) -> String { "不会自动回复的人 (\(count))" }
    static let excludedEmpty = "还没有排除的人。"
    static let excludedGoContacts = "去关注谁"
    static let excludedAddButton = "添加排除对象"
    static let advancedTitle = "高级设置"
    static let historyTitle = "自动回复记录"
    static let historyEmpty = "暂无记录"
    static let historyClear = "清除历史"
    static let historyClearConfirmTitle = "确定清除所有自动回复记录？"
    static let historyClearConfirm = "清除"
    static let historyClearCancel = "取消"
    static let historyClearFailed = "记录没清掉，请稍后重试（已发出的消息不受影响）"
    static let historyCleared = "记录已清除。"

    static let statusActive = "正在整理回复"
    static let statusIdle = "尚未开始整理"
    static let openPending = "查看待确认回复"
    static let saveOk = "设置已保存"
    static let saveFailed = "设置没保存成功，现在还是上次的规则。请再试一次。"
    static let saveRetry = "再试一次"
    static let sendKeyTitle = "微信发送键"
    static let sendKeyCmd = "Cmd+Enter"
    static let sendKeyEnter = "Enter"
}

struct AutopilotSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor
    @EnvironmentObject private var panelState: PanelState

    @State private var confidenceThreshold: Double = 0.8
    @State private var autoSendEnabled: Bool = false
    @State private var handleGroupAt: Bool = false
    @State private var maxRepliesPerHour: Int = 20
    @State private var batchWindowSeconds: Int = 10
    @State private var replyStyle: AutopilotReplyStyle = .auto
    @State private var excludedContacts: [String] = []
    @State private var sendKey: WeChatSendKey = .cmdEnter

    @State private var isHydrating = true
    @State private var didLoad = false
    @State private var showClearConfirm = false
    @State private var sessions: [AutopilotSession] = []
    @State private var allContacts: [ContactEntry] = []
    @State private var safetyConfig = AutopilotConfig()
    @State private var pendingEnableAutoSend = false
    @State private var receipt: Receipt = .idle

    let replyLimits = [5, 10, 20, 50]
    let batchOptions = [5, 10, 15, 30]

    private enum Receipt {
        case idle
        case saved
        case saveFailed
        case historyFailed
        case historyCleared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.autopilotActive ? CompanionPalette.jade : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(monitor.autopilotActive ? AutopilotSettingsCopy.statusActive : AutopilotSettingsCopy.statusIdle)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AutopilotSettingsCopy.openPending) {
                    panelState.pendingSettingsTab = "autopilotDashboard"
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
            }

            SettingsSection("自动回复") {
                SettingsToggleRow(
                    AutopilotSettingsCopy.autoSendTitle,
                    subtitle: autoSendEnabled ? AutopilotSettingsCopy.autoSendOn : AutopilotSettingsCopy.autoSendOff,
                    isOn: Binding(
                        get: { autoSendEnabled },
                        set: { newValue in
                            if newValue && !autoSendEnabled {
                                pendingEnableAutoSend = true
                            } else {
                                autoSendEnabled = newValue
                                save()
                            }
                        }
                    )
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    AutopilotSettingsCopy.groupAtTitle,
                    subtitle: handleGroupAt
                        ? AutopilotSettingsCopy.groupRule
                        : AutopilotSettingsCopy.groupAtOff,
                    isOn: Binding(
                        get: { handleGroupAt },
                        set: { handleGroupAt = $0; save() }
                    )
                )
                SettingsRowDivider()
                confidenceRow
                SettingsRowDivider()
                // The batch window lives in the main section: it is part of
                // "when do replies go out", not an expert tweak, and its old
                // home behind 高级设置 hid the answer from the question it
                // answers.
                limitsBatchRow
                SettingsRowDivider()
                DisclosureGroup(AutopilotSettingsCopy.advancedTitle) {
                    VStack(alignment: .leading, spacing: 12) {
                        advancedSection
                        exclusionSection
                        historySection
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            receiptBar
        }
        .onAppear {
            if !didLoad {
                didLoad = true
                load()
                DispatchQueue.main.async { isHydrating = false }
            }
        }
        .companionDialogBackdrop(pendingEnableAutoSend) {
            if pendingEnableAutoSend {
                CompanionDialog(title: CompanionProductCopy.autoSendConfirmTitle, onClose: {
                    pendingEnableAutoSend = false
                    autoSendEnabled = false
                }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.autoSendConfirmMessage)
                            .workspaceBody()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Button(CompanionProductCopy.autoSendKeepManual) {
                                pendingEnableAutoSend = false
                                autoSendEnabled = false
                            }
                            .buttonStyle(CompanionPressStyle())
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                            Button(CompanionProductCopy.autoSendAllow) {
                                pendingEnableAutoSend = false
                                autoSendEnabled = true
                                save()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var receiptBar: some View {
        switch receipt {
        case .idle:
            EmptyView()
        case .saved:
            Text(AutopilotSettingsCopy.saveOk)
                .workspaceMeta()
                .foregroundStyle(CompanionPalette.jade)
        case .saveFailed:
            saveFailureRow(AutopilotSettingsCopy.saveFailed, retry: save)
        case .historyFailed:
            saveFailureRow(AutopilotSettingsCopy.historyClearFailed, retry: retryClearHistory)
        case .historyCleared:
            Text(AutopilotSettingsCopy.historyCleared)
                .workspaceMeta()
                .foregroundStyle(CompanionPalette.jade)
        }
    }

    private func saveFailureRow(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .workspaceMeta()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(AutopilotSettingsCopy.saveRetry, action: retry)
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
        }
    }

    private var confidenceRow: some View {
        SettingsRow(AutopilotSettingsCopy.confidenceTitle, subtitle: AutopilotSettingsCopy.confidenceHint) {
            HStack(spacing: 8) {
                Slider(value: $confidenceThreshold, in: 0.5...1.0, step: 0.05)
                    .tint(CompanionPalette.jade)
                    .accessibilityLabel(AutopilotSettingsCopy.confidenceTitle)
                    .frame(width: 120)
                    .onChange(of: confidenceThreshold) { save() }
                Text("\(Int(confidenceThreshold * 100))%")
                    .companionFont(size: WorkspaceType.body, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var limitsBatchRow: some View {
        SettingsRow(AutopilotSettingsCopy.batchTitle, subtitle: AutopilotSettingsCopy.batchHint) {
            HStack(spacing: 6) {
                ForEach(batchOptions, id: \.self) { seconds in
                    batchChip(seconds)
                }
            }
        }
    }

    private func batchChip(_ seconds: Int) -> some View {
        Button("\(seconds) 秒") {
            batchWindowSeconds = seconds
            save()
        }
        .buttonStyle(CompanionPressStyle())
        .workspaceMeta()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(batchWindowSeconds == seconds ? CompanionPalette.selectedFill : Color.clear, in: Capsule())
        .foregroundStyle(batchWindowSeconds == seconds ? .primary : .secondary)
        .accessibilityAddTraits(batchWindowSeconds == seconds ? .isSelected : [])
    }

    // MARK: - Exclusion

    private var exclusionSection: some View {
        let available = allContacts.filter { !excludedContacts.contains($0.username) }
        return SettingsSection(AutopilotSettingsCopy.excludedTitle(count: excludedContacts.count)) {
            if excludedContacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AutopilotSettingsCopy.excludedEmpty)
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                    if available.isEmpty {
                        Button(AutopilotSettingsCopy.excludedGoContacts) {
                            panelState.pendingSettingsTab = "contacts"
                        }
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                    } else {
                        addExclusionMenu(available: available)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else {
                ForEach(Array(excludedContacts.enumerated()), id: \.element) { idx, username in
                    if idx > 0 { SettingsRowDivider() }
                    HStack(spacing: 8) {
                        Text(contactDisplayName(username))
                            .workspaceBody()
                        Spacer()
                        Button {
                            excludedContacts.removeAll { $0 == username }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .workspaceRowTitle()
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(CompanionPressStyle())
                        .accessibilityLabel("去掉 \(contactDisplayName(username))")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if !available.isEmpty {
                    SettingsRowDivider()
                    HStack {
                        Spacer()
                        addExclusionMenu(available: available)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func addExclusionMenu(available: [ContactEntry]) -> some View {
        Menu {
            ForEach(available, id: \.username) { contact in
                Button("\(contact.role.icon) \(contact.displayName)") {
                    excludedContacts.append(contact.username)
                    save()
                }
            }
        } label: {
            Text(AutopilotSettingsCopy.excludedAddButton)
                .workspaceMeta()
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(CompanionPressStyle())
        .foregroundStyle(.secondary)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(spacing: 0) {
            replyStyleRow
            SettingsRowDivider()
            alwaysManualRow
            SettingsRowDivider()
            Text(AutopilotSettingsCopy.groupRule)
                .workspaceBody()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            SettingsRowDivider()
            SettingsRow(AutopilotSettingsCopy.perHourTitle, subtitle: AutopilotSettingsCopy.perHourHint) {
                Picker(AutopilotSettingsCopy.perHourTitle, selection: $maxRepliesPerHour) {
                    ForEach(replyLimits, id: \.self) { Text("\($0) 条").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: maxRepliesPerHour) { save() }
            }
            SettingsRowDivider()
            SettingsRow(AutopilotSettingsCopy.sessionTitle, subtitle: AutopilotSettingsCopy.sessionHint) {
                Text(safetyConfig.maxSendsPerSession > 0 ? "\(safetyConfig.maxSendsPerSession) 条" : "未设置上限")
                    .foregroundStyle(.secondary)
            }
            SettingsRowDivider()
            SettingsRow(
                AutopilotSettingsCopy.sendKeyTitle,
                subtitle: sendKey == .cmdEnter ? "默认：Enter 换行，Cmd+Enter 发送" : "你已在微信里改成 Enter 直接发送",
                icon: "paperplane.fill"
            ) {
                HStack(spacing: 6) {
                    sendKeyChip(AutopilotSettingsCopy.sendKeyCmd, .cmdEnter)
                    sendKeyChip(AutopilotSettingsCopy.sendKeyEnter, .enter)
                }
            }
        }
    }

    private var replyStyleRow: some View {
        SettingsRow(AutopilotSettingsCopy.replyStyleTitle, subtitle: replyStyle.hint) {
            Picker(AutopilotSettingsCopy.replyStyleTitle, selection: $replyStyle) {
                ForEach(AutopilotReplyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: replyStyle) { save() }
        }
    }

    private var alwaysManualRow: some View {
        SettingsRow(AutopilotSettingsCopy.alwaysManualTitle, subtitle: AutopilotSettingsCopy.alwaysManualRule) {
            EmptyView()
        }
    }

    private func sendKeyChip(_ title: String, _ key: WeChatSendKey) -> some View {
        Button(title) {
            sendKey = key
            save()
        }
        .buttonStyle(CompanionPressStyle())
        .workspaceMeta()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sendKey == key ? CompanionPalette.selectedFill : Color.clear, in: Capsule())
        .foregroundStyle(sendKey == key ? .primary : .secondary)
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection(AutopilotSettingsCopy.historyTitle) {
            if sessions.isEmpty {
                Text(AutopilotSettingsCopy.historyEmpty)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                    if idx > 0 { SettingsRowDivider() }
                    sessionRow(session)
                }
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Button(AutopilotSettingsCopy.historyClear) { showClearConfirm = true }
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.red)
                        .alert(AutopilotSettingsCopy.historyClearConfirmTitle, isPresented: $showClearConfirm) {
                            Button(AutopilotSettingsCopy.historyClearCancel, role: .cancel) {}
                            Button(AutopilotSettingsCopy.historyClearConfirm, role: .destructive) {
                                retryClearHistory()
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func sessionRow(_ session: AutopilotSession) -> some View {
        HStack(spacing: 8) {
            Text(formatDate(session.startedAt))
                .workspaceMeta()
                .monospacedDigit()
            Text(sessionDuration(session))
                .workspaceMicro()
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(session.totalSent)")
                .workspaceMicro()
                .foregroundStyle(CompanionPalette.jade)
                .accessibilityLabel("已发送 \(session.totalSent)")
            Text("\(session.totalPending)")
                .workspaceMicro()
                .foregroundStyle(.secondary)
                .accessibilityLabel("待确认 \(session.totalPending)")
            if session.endedAt == nil {
                Text("运行中")
                    .workspaceMicro()
                    .foregroundStyle(CompanionPalette.jade)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func sessionDuration(_ session: AutopilotSession) -> String {
        let end = session.endedAt ?? Date()
        let s = Int(end.timeIntervalSince(session.startedAt))
        return s >= 3600 ? "\(s/3600)h\((s%3600)/60)m" : "\(s/60)m"
    }

    private func contactDisplayName(_ username: String) -> String {
        allContacts.first { $0.username == username }?.displayName ?? username
    }

    // MARK: - Persistence

    private func load() {
        let cfg = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
        autoSendEnabled = cfg.autoSendEnabled
        handleGroupAt = cfg.handleGroupAt
        confidenceThreshold = cfg.confidenceThreshold
        maxRepliesPerHour = cfg.maxRepliesPerHour
        batchWindowSeconds = cfg.batchWindowSeconds
        replyStyle = cfg.replyStyle
        excludedContacts = cfg.excludedContacts
        sendKey = cfg.sendKey
        safetyConfig = cfg
        sessions = store.loadAutopilotSessions(limit: 10)
        allContacts = store.loadContacts(level: nil)
    }

    private func save() {
        guard didLoad, !isHydrating else { return }
        // Merge-update so we don't clobber fields the settings UI doesn't
        // surface yet (maxSendsPerSession, sensitiveKeywords, proactive*,
        // etc. all default-construct and would blow away user values if
        // we rebuilt from scratch).
        var cfg = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
        cfg.autoSendEnabled = autoSendEnabled
        cfg.handleGroupAt = handleGroupAt
        cfg.confidenceThreshold = confidenceThreshold
        cfg.maxRepliesPerHour = maxRepliesPerHour
        cfg.batchWindowSeconds = batchWindowSeconds
        cfg.excludedContacts = excludedContacts
        cfg.replyStyle = replyStyle
        cfg.sendKey = sendKey
        do {
            try store.setSettingJSON("autopilot", value: cfg)
            safetyConfig = cfg
            receipt = .saved
        } catch {
            receipt = .saveFailed
        }
    }

    private func retryClearHistory() {
        do {
            try store.clearAutopilotHistory()
            sessions = store.loadAutopilotSessions(limit: 10)
            receipt = .historyCleared
        } catch {
            receipt = .historyFailed
        }
    }

}
