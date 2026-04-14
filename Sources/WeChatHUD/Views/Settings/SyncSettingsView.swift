import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    // MARK: - Sync state
    @State private var dbPath = "auto"
    @State private var interval = 30
    @State private var cacheStrategy: CacheStrategy = .temporary
    @State private var displayScreen: DisplayScreen = .builtIn
    @State private var detectedPath = ""

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
        VStack(alignment: .leading, spacing: 16) {
            syncSection
            dataSection
            aboutSection
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            loadSync()
            reloadData()
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection("同步") {
            // Poll interval
            SettingsRow("轮询间隔", icon: "clock.arrow.2.circlepath", iconColor: .blue) {
                Picker("", selection: $interval) {
                    ForEach(intervals, id: \.self) { i in
                        Text(i < 60 ? "\(i)秒" : "\(i/60)分钟").tag(i)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .onChange(of: interval) { save() }
            }

            SettingsRowDivider()

            // Cache strategy
            SettingsRow("解密缓存", subtitle: cacheStrategy.hint, icon: "externaldrive", iconColor: .orange) {
                Picker("", selection: $cacheStrategy) {
                    ForEach(CacheStrategy.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .onChange(of: cacheStrategy) { save() }
            }

            SettingsRowDivider()

            // Display screen
            SettingsRow("显示屏幕", icon: "display", iconColor: .cyan) {
                Picker("", selection: $displayScreen) {
                    ForEach(DisplayScreen.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .onChange(of: displayScreen) { save() }
            }

            SettingsRowDivider()

            // DB path
            SettingsRow(
                "数据路径",
                subtitle: detectedPath.isEmpty ? nil : "检测到: \(shortenPath(detectedPath))",
                icon: "folder", iconColor: .green
            ) {
                TextField("auto", text: $dbPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 180)
                    .onSubmit { save() }
            }
        }
    }

    // MARK: - Data management

    private var dataSection: some View {
        SettingsSection("数据管理") {
            // Export
            SettingsRow("导出报告", icon: "square.and.arrow.up", iconColor: .blue) {
                HStack(spacing: 8) {
                    if let msg = exportMessage {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                    Button("导出") {
                        if let url = monitor.exportReport() {
                            exportMessage = url.lastPathComponent
                        } else {
                            exportMessage = "失败"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportMessage = nil }
                    }
                    .controlSize(.small)
                }
            }

            SettingsRowDivider()

            // Section picker
            VStack(spacing: 0) {
                Picker("", selection: $selectedSection) {
                    ForEach(DataSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onChange(of: selectedSection) { reloadData() }

                switch selectedSection {
                case .recalls:     recallsList
                case .commitments: commitmentsList
                case .pendingAsks: pendingAsksList
                }
            }
        }
    }

    // MARK: - Data lists

    private var recallsList: some View {
        Group {
            if recalledMessages.isEmpty {
                emptyRow("暂无撤回记录")
            } else {
                ForEach(recalledMessages) { msg in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Text(msg.senderRole.icon).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(msg.senderName)
                                    .font(.system(size: 11, weight: .medium))
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text(msg.chatName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(msg.recallDelaySeconds)秒后撤回")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                            }
                            Text("「\(msg.originalText)」")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if let reason = msg.aiReason {
                                HStack(spacing: 4) {
                                    pill(reason, color: msg.aiIntelligenceValue == "high" ? .red : .gray)
                                    if let d = msg.aiDetail, !d.isEmpty {
                                        Text(d).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
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
                emptyRow("暂无承诺记录")
            } else {
                ForEach(commitments) { item in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(commitmentColor(item))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.content)
                                .font(.system(size: 11, weight: .medium))
                            HStack(spacing: 6) {
                                Text("→ \(item.commitTo)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                if let d = item.deadlineAt {
                                    Text(d < Date() ? "已超期" : "截止 \(MessageInfo.formatRelative(Int(d.timeIntervalSince1970)))")
                                        .font(.system(size: 10))
                                        .foregroundColor(d < Date() ? .red : .secondary)
                                }
                            }
                        }
                        Spacer()
                        if item.status == .pending {
                            Button("完成") {
                                try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .fulfilled)
                                reloadData()
                            }
                            .controlSize(.mini)
                            Button("取消") {
                                try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .cancelled)
                                reloadData()
                            }
                            .controlSize(.mini)
                            .foregroundColor(.secondary)
                        } else {
                            Text(item.status.rawValue)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
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
                emptyRow("暂无待决事项")
            } else {
                ForEach(pendingAsks) { ask in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(urgencyColor(ask))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if let role = ask.senderRole { Text(role.icon).font(.system(size: 10)) }
                                Text(ask.senderName).font(.system(size: 11, weight: .medium))
                                Text(ask.chatName).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Text(ask.summary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            HStack(spacing: 4) {
                                pill(ask.askType.label, color: .blue)
                                Text(String(format: "%.0f%%", ask.confidence * 100))
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text(MessageInfo.formatRelative(Int(ask.createdAt.timeIntervalSince1970)))
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if ask.status == .pending {
                            Button("已处理") {
                                try? store.updatePendingAskStatus(msgUID: ask.msgUID, status: .done)
                                reloadData()
                            }
                            .controlSize(.mini)
                            Button("忽略") {
                                try? store.dismissPendingAsk(msgUID: ask.msgUID)
                                reloadData()
                            }
                            .controlSize(.mini)
                            .foregroundColor(.secondary)
                        } else {
                            Text(ask.status.rawValue).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection("关于") {
            SettingsRow("版本", icon: "info.circle", iconColor: .gray) {
                Text("WeChatHUD v1.0")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            SettingsRowDivider()
            SettingsRow("快捷键", icon: "command", iconColor: .gray) {
                Text("Esc 折叠 · ⌘, 设置")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private func pill(_ text: String, color: Color) -> some View {
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
        let cfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        dbPath = cfg.wechatDBPath
        interval = cfg.intervalSeconds
        cacheStrategy = cfg.cacheStrategy
        displayScreen = cfg.displayScreen
        if let path = WeChatReader.autoDetectDBDir() { detectedPath = path }
    }

    private func save() {
        let cfg = SyncConfig(
            intervalSeconds: interval,
            wechatDBPath: dbPath,
            cacheStrategy: cacheStrategy,
            displayScreen: displayScreen
        )
        try? store.setSettingJSON("sync", value: cfg)
    }

    private func reloadData() {
        switch selectedSection {
        case .recalls:
            recalledMessages = store.loadRecalledMessages(since: 0, limit: 50)
        case .commitments:
            commitments = store.loadCommitments(status: .pending) + store.loadCommitments(status: .fulfilled)
        case .pendingAsks:
            let main = store.loadPendingAsks(bucket: .main, status: .pending)
            let review = store.loadPendingAsks(bucket: .review, status: .pending)
            let done = store.loadPendingAsks(bucket: .main, status: .done)
            pendingAsks = main + review + done.prefix(10)
        }
    }
}
