import SwiftUI

extension Notification.Name {
    static let hudAIConfigDidChange = Notification.Name("WeChatHUD.AIConfigDidChange")
    static let hudReplyDebtAIConfigDidChange = Notification.Name("WeChatHUD.ReplyDebtAIConfigDidChange")
}

struct AISettingsView: View {
    @EnvironmentObject private var store: HUDStore

    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var replyDebtAIEnabled = false
    @State private var replyDebtShadowMode = true
    @State private var recentReplyDebtAudit: [AIAuditEntry] = []
    @State private var recentGroupContextAudit: [AIAuditEntry] = []
    @State private var recentReplyDebtFeedback: [AIFeedbackEntry] = []
    @State private var replyDebtFeedbackByKey: [String: AIFeedbackEntry] = [:]
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var didLoad = false
    @State private var showSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsField("API 地址", text: $baseURL)
            settingsField("模型", text: $model)
            settingsField("API Key", text: $apiKey, isSecure: true)

            if showSaved {
                Text("已保存")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("启用待回 AI 判定", isOn: $replyDebtAIEnabled)
                Toggle("仅 Shadow Mode（只记录差异，不改排序）", isOn: $replyDebtShadowMode)
                    .disabled(!replyDebtAIEnabled)
            }
            .toggleStyle(.switch)
            .font(.system(size: 12))

            HStack {
                Button(action: testConnection) {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(isTesting ? "测试中..." : "测试连接")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)

                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundColor(testResult.contains("成功") ? .green : .red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("待回 AI 审计")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("刷新") {
                        reloadRecentReplyDebtAudit()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                }

                if recentReplyDebtAudit.isEmpty {
                    Text("最近还没有待回 AI 审计记录。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recentReplyDebtAudit, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(Self.auditTimestampFormatter.string(from: entry.ts))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(auditStatusLabel(entry))
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(auditStatusColor(entry).opacity(0.15))
                                        .foregroundColor(auditStatusColor(entry))
                                        .cornerRadius(4)
                                    Text(entry.model)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Text(auditSummary(entry))
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)

                                if entry.status == .ok {
                                    HStack(spacing: 6) {
                                        feedbackButton(
                                            title: "正确",
                                            type: .truePositive,
                                            entry: entry
                                        )
                                        feedbackButton(
                                            title: "误判",
                                            type: .falsePositive,
                                            entry: entry
                                        )
                                        Spacer()
                                        if let feedback = replyDebtFeedbackByKey[feedbackKey(for: entry)] {
                                            Text(feedbackLabel(feedback))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(feedbackColor(feedback))
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("群聊上下文 AI 审计")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("刷新") {
                        reloadRecentGroupContextAudit()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                }

                if recentGroupContextAudit.isEmpty {
                    Text("最近还没有群聊上下文简报记录。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recentGroupContextAudit, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(Self.auditTimestampFormatter.string(from: entry.ts))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(auditStatusLabel(entry))
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(auditStatusColor(entry).opacity(0.15))
                                        .foregroundColor(auditStatusColor(entry))
                                        .cornerRadius(4)
                                    Text(entry.model)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Text(auditSummary(entry))
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if !recentReplyDebtFeedbackWindow.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("近 7 天反馈")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 8) {
                        feedbackStatPill(
                            title: "正确",
                            value: feedbackStats.correct,
                            color: .green
                        )
                        feedbackStatPill(
                            title: "误判",
                            value: feedbackStats.incorrect,
                            color: .orange
                        )
                        feedbackStatPill(
                            title: "准确率",
                            value: feedbackStats.accuracyText,
                            color: .blue
                        )
                    }

                    if !recentFalsePositives.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近误判")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            ForEach(Array(recentFalsePositives.prefix(3)), id: \.id) { feedback in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(Self.auditTimestampFormatter.string(from: feedback.ts))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(feedback.note ?? "无摘要")
                                        .font(.system(size: 11))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: baseURL) { _, _ in saveAIConfig() }
        .onChange(of: model) { _, _ in saveAIConfig() }
        .onChange(of: apiKey) { _, _ in saveAIConfig() }
        .onChange(of: replyDebtAIEnabled) { _, _ in saveReplyDebtAIConfig() }
        .onChange(of: replyDebtShadowMode) { _, _ in saveReplyDebtAIConfig() }
    }

    private func settingsField(_ label: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if isSecure {
                SecureField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = ""
        let cfg = AIConfig(baseURL: baseURL, model: model, apiKey: apiKey)
        Task {
            let service = AIService(config: cfg)
            do {
                let result = try await service.testConnection()
                await MainActor.run {
                    testResult = "连接成功: \(result.prefix(20))"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        // Read via the helper so source code never names the "ai" key
        // or constructs an AIConfig directly. After HUDStore.open()'s
        // seed runs on first launch this always returns populated values.
        let cfg = store.loadAIConfig()
        baseURL = cfg.baseURL
        model = cfg.model
        apiKey = cfg.apiKey

        if let cfg = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self) {
            replyDebtAIEnabled = cfg.enabled
            replyDebtShadowMode = cfg.shadowMode
        }
        reloadRecentReplyDebtAudit()
        reloadRecentGroupContextAudit()
        reloadReplyDebtFeedback()
    }

    private func saveAIConfig() {
        guard didLoad else { return }
        let cfg = AIConfig(baseURL: baseURL, model: model, apiKey: apiKey)
        try? store.setSettingJSON("ai", value: cfg)
        NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    private func saveReplyDebtAIConfig() {
        guard didLoad else { return }
        var cfg = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self) ?? ReplyDebtAIConfig()
        cfg.enabled = replyDebtAIEnabled
        cfg.shadowMode = replyDebtShadowMode
        try? store.setSettingJSON("replyDebtAI", value: cfg)
        NotificationCenter.default.post(name: .hudReplyDebtAIConfigDidChange, object: nil)
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    private func reloadRecentReplyDebtAudit() {
        recentReplyDebtAudit = store.loadRecentAIAudit(
            limit: 8,
            role: .ranker,
            promptVersionPrefix: "reply_debt_"
        )
    }

    private func reloadRecentGroupContextAudit() {
        recentGroupContextAudit = store.loadRecentAIAudit(
            limit: 6,
            role: .retrospector,
            promptVersionPrefix: "group_context_"
        )
    }

    private func reloadReplyDebtFeedback() {
        recentReplyDebtFeedback = store.loadAIFeedback(
            limit: 200,
            msgUIDPrefix: replyDebtFeedbackPrefix
        )
        replyDebtFeedbackByKey = store.loadLatestAIFeedbackByMsgUID(
            limit: 200,
            msgUIDPrefix: replyDebtFeedbackPrefix
        )
    }

    private func auditStatusLabel(_ entry: AIAuditEntry) -> String {
        switch entry.status {
        case .ok:
            return entry.promptVersion.contains("reply_debt") ? "OK" : entry.status.rawValue.uppercased()
        case .parseError:
            return "PARSE"
        case .httpError:
            return "HTTP"
        case .timeout:
            return "TIMEOUT"
        }
    }

    private func auditStatusColor(_ entry: AIAuditEntry) -> Color {
        switch entry.status {
        case .ok:
            return .green
        case .parseError:
            return .orange
        case .httpError, .timeout:
            return .red
        }
    }

    private func auditSummary(_ entry: AIAuditEntry) -> String {
        if let message = entry.errorMessage, !message.isEmpty {
            return message
        }
        if !entry.outputText.isEmpty {
            return String(entry.outputText.prefix(120))
        }
        return "无额外说明"
    }

    private func feedbackButton(
        title: String,
        type: AIFeedbackType,
        entry: AIAuditEntry
    ) -> some View {
        let selected = replyDebtFeedbackByKey[feedbackKey(for: entry)]?.feedbackType == type
        return Button(title) {
            writeFeedback(type: type, for: entry)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: selected ? .semibold : .regular))
        .foregroundColor(selected ? .white : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(selected ? feedbackColor(type).opacity(0.75) : Color.gray.opacity(0.15))
        .cornerRadius(4)
    }

    private func writeFeedback(type: AIFeedbackType, for entry: AIAuditEntry) {
        let snapshot = ReplyDebtAuditFeedbackSnapshot(
            auditID: entry.id,
            model: entry.model,
            promptVersion: entry.promptVersion,
            status: entry.status.rawValue,
            outputText: entry.outputText,
            summary: auditSummary(entry)
        )
        let payloadData = try? JSONEncoder().encode(snapshot)
        let payload = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? entry.outputText
        let feedback = AIFeedbackEntry(
            id: 0,
            ts: Date(),
            msgUID: feedbackKey(for: entry),
            feedbackType: type,
            originalOutput: payload,
            userAction: type == .truePositive ? "confirmed_audit" : "rejected_audit",
            note: auditSummary(entry)
        )
        try? store.writeAIFeedback(feedback)
        reloadReplyDebtFeedback()
    }

    private func feedbackKey(for entry: AIAuditEntry) -> String {
        "\(replyDebtFeedbackPrefix)\(entry.id)"
    }

    private func feedbackLabel(_ feedback: AIFeedbackEntry) -> String {
        switch feedback.feedbackType {
        case .truePositive:
            return "已标记: 正确"
        case .falsePositive:
            return "已标记: 误判"
        case .trueNegative:
            return "已标记: 无需处理"
        case .falseNegative:
            return "已标记: 漏判"
        }
    }

    private func feedbackColor(_ feedback: AIFeedbackEntry) -> Color {
        feedbackColor(feedback.feedbackType)
    }

    private func feedbackColor(_ type: AIFeedbackType) -> Color {
        switch type {
        case .truePositive, .trueNegative:
            return .green
        case .falsePositive, .falseNegative:
            return .orange
        }
    }

    private func feedbackStatPill(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(value)")
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }

    private func feedbackStatPill(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }

    private var recentReplyDebtFeedbackWindow: [AIFeedbackEntry] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return recentReplyDebtFeedback.filter { $0.ts >= cutoff }
    }

    private var recentFalsePositives: [AIFeedbackEntry] {
        recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .falsePositive }
    }

    private var feedbackStats: (correct: Int, incorrect: Int, accuracyText: String) {
        let correct = recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .truePositive }.count
        let incorrect = recentReplyDebtFeedbackWindow.filter { $0.feedbackType == .falsePositive }.count
        let total = correct + incorrect
        let accuracy = total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
        return (correct, incorrect, "\(accuracy)%")
    }

    private static let auditTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static let replyDebtFeedbackPrefix = "reply_debt_audit:"

    private var replyDebtFeedbackPrefix: String {
        Self.replyDebtFeedbackPrefix
    }
}

private struct ReplyDebtAuditFeedbackSnapshot: Encodable {
    let auditID: Int64
    let model: String
    let promptVersion: String
    let status: String
    let outputText: String
    let summary: String
}
