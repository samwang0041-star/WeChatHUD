import SwiftUI

struct AutopilotSettingsView: View {
    @EnvironmentObject private var store: HUDStore

    @State private var confidenceThreshold: Double = 0.8
    @State private var maxRepliesPerHour: Int = 20
    @State private var batchWindowSeconds: Int = 10
    @State private var vipAutoNotify: Bool = true
    @State private var vipBusyTemplate: String = ""
    @State private var handleGroupAt: Bool = false
    @State private var replyStyle: AutopilotReplyStyle = .auto
    @State private var excludedContacts: [String] = []

    @State private var didLoad = false
    @State private var showClearConfirm = false
    @State private var sessions: [AutopilotSession] = []
    @State private var allContacts: [ContactEntry] = []

    let replyLimits = [5, 10, 20, 50]
    let batchOptions = [5, 10, 15, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            styleSection
            thresholdSection
            limitsSection
            vipSection
            exclusionSection
            advancedSection
            historySection
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
    }

    // MARK: - Style

    private var styleSection: some View {
        SettingsSection("回复风格") {
            SettingsRow("风格", subtitle: replyStyle.hint, icon: "text.bubble", iconColor: .purple) {
                Picker("", selection: $replyStyle) {
                    ForEach(AutopilotReplyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .onChange(of: replyStyle) { save() }
            }
        }
    }

    // MARK: - Confidence

    private var thresholdSection: some View {
        SettingsSection("自动发送") {
            VStack(spacing: 4) {
                HStack {
                    Text("信心阈值")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(confidenceThreshold * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(confidenceColor)
                }
                Slider(value: $confidenceThreshold, in: 0.5...1.0, step: 0.05)
                    .onChange(of: confidenceThreshold) { save() }
                HStack {
                    Text("更多自动").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text("更多人工").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var confidenceColor: Color {
        if confidenceThreshold >= 0.9 { return .green }
        if confidenceThreshold >= 0.7 { return .orange }
        return .red
    }

    // MARK: - Rate limits

    private var limitsSection: some View {
        SettingsSection("频率限制") {
            SettingsRow("每小时最大回复", icon: "gauge.with.dots.needle.33percent", iconColor: .orange) {
                Picker("", selection: $maxRepliesPerHour) {
                    ForEach(replyLimits, id: \.self) { Text("\($0)条").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 70)
                .onChange(of: maxRepliesPerHour) { save() }
            }
            SettingsRowDivider()
            SettingsRow("消息合并窗口", subtitle: "窗口内多条消息合并为一次回复", icon: "timer", iconColor: .orange) {
                Picker("", selection: $batchWindowSeconds) {
                    ForEach(batchOptions, id: \.self) { Text("\($0)秒").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 70)
                .onChange(of: batchWindowSeconds) { save() }
            }
        }
    }

    // MARK: - VIP

    private var vipSection: some View {
        SettingsSection("VIP 通知") {
            SettingsToggleRow("VIP 自动忙碌通知", subtitle: "VIP 消息同时推送系统通知", isOn: $vipAutoNotify)
                .onChange(of: vipAutoNotify) { save() }
            if vipAutoNotify {
                SettingsRowDivider()
                SettingsRow("通知模板") {
                    TextField("忙碌通知内容", text: $vipBusyTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 180)
                        .onSubmit { save() }
                }
            }
        }
    }

    // MARK: - Exclusion

    private var exclusionSection: some View {
        SettingsSection("排除联系人 (\(excludedContacts.count))") {
            if excludedContacts.isEmpty {
                Text("无排除项，所有白名单联系人均可自动回复")
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
            SettingsToggleRow(
                "群聊 @消息",
                subtitle: "记录但不自动回复",
                isOn: $handleGroupAt
            )
            .onChange(of: handleGroupAt) { save() }
        }
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection("托管历史") {
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
                        .alert("确定清除所有托管历史？", isPresented: $showClearConfirm) {
                            Button("取消", role: .cancel) {}
                            Button("清除", role: .destructive) {
                                try? store.clearAutopilotHistory()
                                sessions = []
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
        confidenceThreshold = cfg.confidenceThreshold
        maxRepliesPerHour = cfg.maxRepliesPerHour
        batchWindowSeconds = cfg.batchWindowSeconds
        vipAutoNotify = cfg.vipAutoNotify
        vipBusyTemplate = cfg.vipBusyTemplate
        handleGroupAt = cfg.handleGroupAt
        replyStyle = cfg.replyStyle
        excludedContacts = cfg.excludedContacts
        sessions = store.loadAutopilotSessions(limit: 10)
        allContacts = store.loadContacts(level: nil)
    }

    private func save() {
        let existing = store.getSettingJSON("autopilot", as: AutopilotConfig.self)
        let cfg = AutopilotConfig(
            enabled: existing?.enabled ?? false,
            confidenceThreshold: confidenceThreshold,
            maxRepliesPerHour: maxRepliesPerHour,
            handleGroupAt: handleGroupAt,
            vipAutoNotify: vipAutoNotify,
            vipBusyTemplate: vipBusyTemplate,
            batchWindowSeconds: batchWindowSeconds,
            excludedContacts: excludedContacts,
            replyStyle: replyStyle
        )
        try? store.setSettingJSON("autopilot", value: cfg)
    }
}
