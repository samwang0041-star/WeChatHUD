import SwiftUI

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
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var showClearConfirm = false
    @State private var sessions: [AutopilotSession] = []
    @State private var allContacts: [ContactEntry] = []
    @State private var safetyConfig = AutopilotConfig()
    @State private var saved = false
    @State private var pendingEnableAutoSend = false

    let replyLimits = [5, 10, 20, 50]
    let batchOptions = [5, 10, 15, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.autopilotActive ? CompanionPalette.jade : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(monitor.autopilotActive ? "正在整理回复" : "尚未开始整理")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看待确认回复") { panelState.pendingSettingsTab = "autopilotDashboard" }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.jade)
                    .font(.system(size: 13, weight: .medium))
            }

            SettingsSection("自动回复") {
                SettingsToggleRow(
                    "自动发出去",
                    subtitle: autoSendEnabled ? "达到阈值则自动发送。" : "只写草稿，确认后发送。",
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
                    "群里 @我 时也准备回复",
                    subtitle: handleGroupAt
                        ? "群 @ 会写成待确认草稿。转账和红包仍不会自动回。"
                        : "群消息默认只记录，不写回复。",
                    isOn: Binding(
                        get: { handleGroupAt },
                        set: { handleGroupAt = $0; save() }
                    )
                )
                SettingsRowDivider()
                SettingsRow("回复风格", subtitle: replyStyle.hint) {
                    Picker("回复风格", selection: $replyStyle) {
                        ForEach(AutopilotReplyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: replyStyle) { save() }
                }
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("自动发送把握程度")
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(Int(confidenceThreshold * 100))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    Slider(value: $confidenceThreshold, in: 0.5...1.0, step: 0.05)
                        .tint(CompanionPalette.jade)
                        .accessibilityLabel("自动发送把握程度")
                        .onChange(of: confidenceThreshold) { save() }
                    Text("达到这个门槛才会尝试自动发送，仍受发送限制约束。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                SettingsRowDivider()
                SettingsRow("每小时最多", subtitle: "每小时发送上限。") {
                    Picker("每小时最多", selection: $maxRepliesPerHour) {
                        ForEach(replyLimits, id: \.self) { Text("\($0) 条").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 80)
                    .onChange(of: maxRepliesPerHour) { save() }
                }
                SettingsRowDivider()
                SettingsRow("本次整理最多", subtitle: "本次整理期间最多自动发送的条数。") {
                    Text(safetyConfig.maxSendsPerSession > 0 ? "\(safetyConfig.maxSendsPerSession) 条" : "未设置上限")
                        .foregroundStyle(.secondary)
                }
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("哪些一定交给你")
                        .font(.system(size: 13, weight: .medium))
                    Text("群聊、转账、红包、小程序不会自动发送。其他敏感内容需人工确认。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                SettingsRowDivider()
                DisclosureGroup("不自动回复的人") {
                    exclusionSection
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                SettingsRowDivider()
                DisclosureGroup("高级设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        limitsBatchRow
                        advancedSection
                        historySection
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                Button("重试保存设置") { save() }
            } else if saved {
                Label("设置已保存", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(CompanionPalette.jade)
            }
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
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.autoSendKeepManual) {
                                pendingEnableAutoSend = false
                                autoSendEnabled = false
                            }
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

    private var limitsBatchRow: some View {
        SettingsSection("连着几条一起回") {
            SettingsRow("连着几条一起回", subtitle: "连发时先等一会儿再回。") {
                Picker("连着几条一起回", selection: $batchWindowSeconds) {
                    ForEach(batchOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: batchWindowSeconds) { save() }
            }
        }
    }

    // MARK: - Exclusion

    private var exclusionSection: some View {
        SettingsSection("排除联系人 (\(excludedContacts.count))") {
            if excludedContacts.isEmpty {
                Text("还没有排除的人。自动回复会看已经记下的私聊对象；要不要真的发出去，仍由上面的开关决定。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(Array(excludedContacts.enumerated()), id: \.element) { idx, username in
                    if idx > 0 { SettingsRowDivider() }
                    HStack {
                        Text(contactDisplayName(username))
                            .font(.system(size: 12))
                        Spacer()
                        Button {
                            excludedContacts.removeAll { $0 == username }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }

            let available = allContacts.filter { !excludedContacts.contains($0.username) }
            if !available.isEmpty {
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Menu {
                        ForEach(available, id: \.username) { contact in
                            Button("\(contact.role.icon) \(contact.displayName)") {
                                excludedContacts.append(contact.username)
                                save()
                            }
                        }
                    } label: {
                        Label("添加", systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 70)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsSection("高级") {
            Text("群聊消息仅记录，不自动发送回复。需要回答时，请在对话详情中整理并确认回复内容。")
                .font(.callout).foregroundStyle(.secondary).padding(14)
            SettingsRowDivider()
            SettingsRow(
                "微信发送键",
                subtitle: sendKey == .cmdEnter ? "默认：Enter 换行，Cmd+Enter 发送" : "你已在微信里改成 Enter 直接发送",
                icon: "paperplane.fill",
                iconColor: .blue
            ) {
                Picker("", selection: $sendKey) {
                    Text("Cmd+Enter").tag(WeChatSendKey.cmdEnter)
                    Text("Enter").tag(WeChatSendKey.enter)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .onChange(of: sendKey) { save() }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection("自动回复记录") {
            if sessions.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                    if idx > 0 { SettingsRowDivider() }
                    sessionRow(session)
                }
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Button("清除历史") { showClearConfirm = true }
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                        .alert("确定清除所有自动回复记录？", isPresented: $showClearConfirm) {
                            Button("取消", role: .cancel) {}
                            Button("清除", role: .destructive) {
                                do {
                                    try store.clearAutopilotHistory()
                                    sessions = store.loadAutopilotSessions(limit: 10)
                                    saveError = nil
                                } catch {
                                    saveError = "记录没清掉。请先停止自动回复，再试一次。"
                                }
                            }
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func sessionRow(_ session: AutopilotSession) -> some View {
        HStack(spacing: 8) {
            Text(formatDate(session.startedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
            Text(sessionDuration(session))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Label("\(session.totalSent)", systemImage: "checkmark.circle")
                    .font(.system(size: 9)).foregroundColor(.green)
                Label("\(session.totalPending)", systemImage: "clock")
                    .font(.system(size: 9)).foregroundColor(.orange)
            }
            if session.endedAt == nil {
                Text("运行中")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
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
            saveError = nil
            safetyConfig = cfg
            saved = true
        } catch {
            saveError = "设置没保存成功，现在还是上次的规则。请再试一次。"
        }
    }

}
