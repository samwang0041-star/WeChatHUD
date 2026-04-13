import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    // MARK: - Sync state
    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var cacheStrategy: CacheStrategy = .temporary
    @State private var detectedPath = ""
    @State private var showSaved = false

    // MARK: - Data management state
    @State private var selectedSection: DataSection = .recalls
    @State private var exportMessage: String?
    @State private var recalledMessages: [RecalledMessage] = []
    @State private var commitments: [Commitment] = []
    @State private var pendingAsks: [PendingAsk] = []

    @State private var didLoad = false

    let intervals = [15, 30, 60, 300]

    enum DataSection: String, CaseIterable {
        case recalls = "撤回记录"
        case commitments = "承诺追踪"
        case pendingAsks = "待决事项"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // ── Section 1: 同步 ──────────────────────────────────────────
            sectionHeader("同步")

            if showSaved {
                Text("已保存")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            // Cache strategy
            VStack(alignment: .leading, spacing: 4) {
                Text("解密缓存位置")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: cacheStrategy) { save() }
                Text(cacheStrategy.hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // DB path
            VStack(alignment: .leading, spacing: 4) {
                Text("微信数据路径")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("auto = 自动检测", text: $dbPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { save() }
                if !detectedPath.isEmpty {
                    Text("检测到: \(detectedPath)")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }

            // Poll interval
            VStack(alignment: .leading, spacing: 4) {
                Text("轮询间隔")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i)秒" : "\(i / 60)分钟").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: interval) { save() }
            }

            Divider()

            // ── Section 2: 数据管理 ───────────────────────────────────────
            sectionHeader("数据管理")

            // Export button row
            HStack {
                Spacer()
                Button(action: {
                    if let url = monitor.exportReport() {
                        exportMessage = "已导出到 \(url.lastPathComponent)"
                    } else {
                        exportMessage = "导出失败"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportMessage = nil }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("导出报告")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let msg = exportMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Section picker
            Picker("", selection: $selectedSection) {
                ForEach(DataSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedSection) { reloadData() }

            switch selectedSection {
            case .recalls:
                recallsSection
            case .commitments:
                commitmentsSection
            case .pendingAsks:
                pendingAsksSection
            }

            Divider()

            // ── Section 3: 关于 ───────────────────────────────────────────
            sectionHeader("关于")

            VStack(alignment: .leading, spacing: 4) {
                Text("WeChatHUD v1.0")
                    .font(.system(size: 11))
                Text("快捷键: Esc 折叠 · Cmd+, 设置")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            loadSync()
            reloadData()
        }
    }

    // MARK: - Section header helper

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }

    // MARK: - Sync persistence

    private func loadSync() {
        let cfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        dbPath = cfg.wechatDBPath
        interval = cfg.intervalSeconds
        cacheStrategy = cfg.cacheStrategy
        if let path = WeChatReader.autoDetectDBDir() {
            detectedPath = path
        }
    }

    private func save() {
        let cfg = SyncConfig(
            intervalSeconds: interval,
            wechatDBPath: dbPath,
            cacheStrategy: cacheStrategy
        )
        try? store.setSettingJSON("sync", value: cfg)
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    // MARK: - Data sections

    private var recallsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近被撤回的消息")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(recalledMessages.count) 条")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if recalledMessages.isEmpty {
                    emptyState("暂无撤回记录")
                } else {
                    ForEach(recalledMessages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(msg.senderRole.icon)
                                    .font(.system(size: 12))
                                Text(msg.senderName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(msg.chatName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(msg.recallDelaySeconds)秒后撤回")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange.opacity(0.7))
                                Text(MessageInfo.formatRelative(msg.recalledAt))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Text("「\(msg.originalText)」")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            if let reason = msg.aiReason {
                                HStack(spacing: 6) {
                                    aiPill(reason, color: msg.aiIntelligenceValue == "high" ? .red : .gray)
                                    if let detail = msg.aiDetail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private var commitmentsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("你的未完成承诺")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let overdue = commitments.filter {
                        $0.status == .pending && $0.deadlineAt != nil && $0.deadlineAt! < Date()
                    }.count
                    if overdue > 0 {
                        Text("\(overdue) 已超期")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red)
                    }
                }

                if commitments.isEmpty {
                    emptyState("暂无承诺记录")
                } else {
                    ForEach(commitments) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(commitmentColor(item))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.content)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                HStack(spacing: 6) {
                                    Text("→ \(item.commitTo)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    if let deadline = item.deadlineAt {
                                        Text(deadline < Date() ? "已超期" : "截止 \(MessageInfo.formatRelative(Int(deadline.timeIntervalSince1970)))")
                                            .font(.system(size: 10))
                                            .foregroundColor(deadline < Date() ? .red : .secondary)
                                    }
                                }
                            }

                            Spacer()

                            if item.status == .pending {
                                Button("已完成") {
                                    try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .fulfilled)
                                    reloadData()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.green)

                                Button("取消") {
                                    try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .cancelled)
                                    reloadData()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            } else {
                                Text(item.status.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private var pendingAsksSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI 识别的待决事项")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let pending = pendingAsks.filter { $0.status == .pending }.count
                    Text("\(pending) 待处理")
                        .font(.system(size: 10))
                        .foregroundColor(pending > 0 ? .orange : .secondary)
                }

                if pendingAsks.isEmpty {
                    emptyState("暂无待决事项")
                } else {
                    ForEach(pendingAsks) { ask in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(urgencyColor(ask))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if let role = ask.senderRole {
                                        Text(role.icon)
                                            .font(.system(size: 10))
                                    }
                                    Text(ask.senderName)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(ask.chatName)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Text(ask.summary)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    aiPill(ask.askType.label, color: .blue)
                                    Text(String(format: "%.0f%%", ask.confidence * 100))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(MessageInfo.formatRelative(Int(ask.createdAt.timeIntervalSince1970)))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if ask.status == .pending {
                                Button("已处理") {
                                    try? store.updatePendingAskStatus(msgUID: ask.msgUID, status: .done)
                                    reloadData()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.green)

                                Button("忽略") {
                                    try? store.dismissPendingAsk(msgUID: ask.msgUID)
                                    reloadData()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            } else {
                                Text(ask.status.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Data helpers

    private func emptyState(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 20)
            Spacer()
        }
    }

    private func aiPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func commitmentColor(_ item: Commitment) -> Color {
        switch item.status {
        case .pending:
            if let d = item.deadlineAt, d < Date() { return .red }
            return .orange
        case .fulfilled: return .green
        case .overdue: return .red
        case .cancelled: return .gray
        }
    }

    private func urgencyColor(_ ask: PendingAsk) -> Color {
        switch ask.urgency {
        case .urgent: return .red
        case .timely: return .orange
        case .routine: return .blue
        case .none: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func reloadData() {
        switch selectedSection {
        case .recalls:
            recalledMessages = store.loadRecalledMessages(since: 0, limit: 50)
        case .commitments:
            let pending = store.loadCommitments(status: .pending)
            let fulfilled = store.loadCommitments(status: .fulfilled)
            commitments = pending + fulfilled
        case .pendingAsks:
            let main = store.loadPendingAsks(bucket: .main, status: .pending)
            let review = store.loadPendingAsks(bucket: .review, status: .pending)
            let done = store.loadPendingAsks(bucket: .main, status: .done)
            pendingAsks = main + review + done.prefix(10)
        }
    }
}
