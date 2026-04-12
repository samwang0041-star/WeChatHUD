import SwiftUI

/// Full autopilot settings panel — matches macOS System Settings style.
struct AutopilotSettingsView: View {
    @EnvironmentObject private var store: HUDStore

    // Config fields
    @State private var confidenceThreshold: Double = 0.8
    @State private var maxRepliesPerHour: Int = 20
    @State private var batchWindowSeconds: Int = 10
    @State private var vipAutoNotify: Bool = true
    @State private var vipBusyTemplate: String = ""
    @State private var handleGroupAt: Bool = false
    @State private var replyStyle: AutopilotReplyStyle = .auto
    @State private var excludedContacts: [String] = []

    // UI state
    @State private var didLoad = false
    @State private var showSaved = false
    @State private var showClearConfirm = false
    @State private var sessions: [AutopilotSession] = []
    @State private var allContacts: [ContactEntry] = []

    let replyLimits = [5, 10, 20, 50]
    let batchOptions = [5, 10, 15, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showSaved {
                Text("已保存")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            replyStyleSection
            Divider()
            confidenceSection
            Divider()
            rateLimitSection
            Divider()
            vipSection
            Divider()
            exclusionSection
            Divider()
            advancedSection
            Divider()
            historySection
        }
        .font(.system(size: 12))
        .foregroundColor(.primary)
        .toggleStyle(.switch)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
    }

    // MARK: - Reply style

    private var replyStyleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("回复风格")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Picker("", selection: $replyStyle) {
                ForEach(AutopilotReplyStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .onChange(of: replyStyle) { save() }

            Text(replyStyle.hint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Confidence

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("自动发送信心阈值")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(confidenceThreshold * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(confidenceColor)
                    .monospacedDigit()
            }
            Slider(value: $confidenceThreshold, in: 0.5...1.0, step: 0.05)
                .onChange(of: confidenceThreshold) { save() }
            HStack {
                Text("← 更多自动回复")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Text("更多人工审核 →")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var confidenceColor: Color {
        if confidenceThreshold >= 0.9 { return .green }
        if confidenceThreshold >= 0.7 { return .orange }
        return .red
    }

    // MARK: - Rate limit

    private var rateLimitSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("频率限制")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每小时最大回复")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: $maxRepliesPerHour) {
                        ForEach(replyLimits, id: \.self) { limit in
                            Text("\(limit)条").tag(limit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .onChange(of: maxRepliesPerHour) { save() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("消息合并窗口")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: $batchWindowSeconds) {
                        ForEach(batchOptions, id: \.self) { sec in
                            Text("\(sec)秒").tag(sec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .onChange(of: batchWindowSeconds) { save() }
                }
            }
            Text("同一对话在合并窗口内的多条消息会被合并为一次回复")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - VIP

    private var vipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("VIP 联系人自动发送忙碌通知", isOn: $vipAutoNotify)
                .onChange(of: vipAutoNotify) { save() }

            if vipAutoNotify {
                VStack(alignment: .leading, spacing: 4) {
                    Text("忙碌通知模板")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("VIP 忙碌通知内容", text: $vipBusyTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { save() }
                    Text("VIP 消息会同时推送 macOS 系统通知提醒你")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Exclusion list

    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("排除联系人")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(excludedContacts.count) 人")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text("以下联系人的消息不会被自动回复，即使在白名单中")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Current exclusions
            if !excludedContacts.isEmpty {
                VStack(spacing: 2) {
                    ForEach(excludedContacts, id: \.self) { username in
                        HStack {
                            let name = contactDisplayName(username)
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Spacer()
                            Button(action: {
                                excludedContacts.removeAll { $0 == username }
                                save()
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }

            // Add contact picker
            let available = allContacts.filter { !excludedContacts.contains($0.username) }
            if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.username) { contact in
                        Button("\(contact.role.icon) \(contact.displayName)") {
                            excludedContacts.append(contact.username)
                            save()
                        }
                    }
                } label: {
                    Label("添加排除", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 120)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("处理群聊 @消息（当前仅记录）", isOn: $handleGroupAt)
                .onChange(of: handleGroupAt) { save() }
            Text("开启后群聊 @消息也会出现在托管日志中，但不会自动回复")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Session history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("托管历史")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !sessions.isEmpty {
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
            }

            if sessions.isEmpty {
                Text("暂无托管记录")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: AutopilotSession) -> some View {
        HStack(spacing: 8) {
            // Date
            Text(formatDate(session.startedAt))
                .font(.system(size: 10))
                .foregroundColor(.primary)
                .frame(width: 65, alignment: .leading)

            // Duration
            Text(sessionDuration(session))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 45, alignment: .leading)

            // Stats
            HStack(spacing: 6) {
                Label("\(session.totalSent)", systemImage: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Label("\(session.totalPending)", systemImage: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Label("\(session.totalHandled)", systemImage: "tray")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Running indicator
            if session.endedAt == nil {
                Text("运行中")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(session.endedAt == nil ? Color.green.opacity(0.05) : Color.clear)
        .cornerRadius(4)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func sessionDuration(_ session: AutopilotSession) -> String {
        let end = session.endedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(session.startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
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
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }
}
