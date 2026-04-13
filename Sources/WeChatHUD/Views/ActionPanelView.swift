import SwiftUI

/// Expanded action panel shown when user clicks an inbox row.
/// Provides on-demand AI analysis buttons: group/private analysis,
/// reply suggestions, and open in WeChat.
struct ActionPanelView: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: InboxItem

    // MARK: - State

    enum AnalysisState {
        case idle
        case loading
        case groupResult(ChatAnalyzer.GroupAnalysis)
        case privateResult(ChatAnalyzer.PrivateAnalysis)
        case error
    }

    enum ReplyState {
        case idle
        case loading
        case results([SuggestedReply])
        case error
    }

    @State private var analysisState: AnalysisState = .idle
    @State private var replyState: ReplyState = .idle
    @State private var hasProfile: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                // Action buttons row
                actionButtons

                // Analysis result (if any)
                switch analysisState {
                case .loading:
                    loadingRow(label: "正在分析…")
                case .groupResult(let result):
                    groupAnalysisView(result)
                case .privateResult(let result):
                    privateAnalysisView(result)
                case .error:
                    errorRow(label: "分析失败，请重试")
                case .idle:
                    EmptyView()
                }

                // Reply suggestions (if any)
                switch replyState {
                case .loading:
                    loadingRow(label: "正在生成回复建议…")
                case .results(let replies):
                    replySuggestionsView(replies)
                case .error:
                    errorRow(label: "回复建议生成失败")
                case .idle:
                    EmptyView()
                }

                // Open in WeChat — always available
                openWeChatButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
        }
        .onAppear {
            hasProfile = monitor.hasRelationshipProfile(for: item.chatUsername)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 6) {
            // Primary analysis button
            Button(action: runAnalysis) {
                HStack(spacing: 4) {
                    if case .loading = analysisState {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 10, height: 10)
                    }
                    Text(item.isGroup ? "在聊什么" : "帮我分析")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.75))
            .disabled(analysisIsLoading)

            // Reply suggestions — only if has relationship profile
            if hasProfile {
                Button(action: runReplySuggestions) {
                    HStack(spacing: 4) {
                        if case .loading = replyState {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 10, height: 10)
                        }
                        Text("回复建议")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.75))
                .disabled(replyIsLoading)
            }

            Spacer()
        }
    }

    private var analysisIsLoading: Bool {
        if case .loading = analysisState { return true }
        return false
    }

    private var replyIsLoading: Bool {
        if case .loading = replyState { return true }
        return false
    }

    // MARK: - Actions

    private func runAnalysis() {
        analysisState = .loading
        Task {
            if item.isGroup {
                if let result = await monitor.analyzeGroupChat(item: item) {
                    analysisState = .groupResult(result)
                } else {
                    analysisState = .error
                }
            } else {
                if let result = await monitor.analyzePrivateChat(item: item) {
                    analysisState = .privateResult(result)
                } else {
                    analysisState = .error
                }
            }
        }
    }

    private func runReplySuggestions() {
        replyState = .loading
        Task {
            if let results = await monitor.loadReplySuggestions(for: item) {
                replyState = .results(results)
            } else {
                replyState = .error
            }
        }
    }

    // MARK: - Loading / Error

    private func loadingRow(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.vertical, 2)
    }

    private func errorRow(label: String) -> some View {
        Text(label)
            .font(.system(size: 10))
            .foregroundColor(.red.opacity(0.6))
            .padding(.vertical, 2)
    }

    // MARK: - Group Analysis

    private func groupAnalysisView(_ result: ChatAnalyzer.GroupAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("在聊什么")

            // one_liner summary
            Text(result.one_liner)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Color.white.opacity(0.06))

            // Topics
            labeledRow(icon: "bubble.left.and.bubble.right", label: "话题", value: result.topics)

            // Decisions (if present)
            if let decisions = result.decisions, !decisions.isEmpty {
                labeledRow(icon: "checkmark.seal", label: "决议", value: decisions)
            }

            // My action items — highlighted orange
            if let actions = result.my_action_items, !actions.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("我需要做")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.orange.opacity(0.7))
                        Text(actions)
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.06))
                .cornerRadius(5)
            }

            // Key speakers (if present)
            if let speakers = result.key_speakers, !speakers.isEmpty {
                labeledRow(icon: "person.2", label: "主要发言", value: speakers)
            }

            // Status badge
            statusBadge(result.status)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Private Analysis

    private func privateAnalysisView(_ result: ChatAnalyzer.PrivateAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("分析结果")

            // one_liner
            Text(result.one_liner)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Color.white.opacity(0.06))

            // Intent
            labeledRow(icon: "text.bubble", label: "意图", value: result.intent)

            // Urgency
            HStack(alignment: .top, spacing: 6) {
                urgencyBadge(result.urgency)
                Text(result.urgency_reason)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Mood
            HStack(alignment: .top, spacing: 6) {
                moodBadge(result.mood)
                Text(result.mood_evidence)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Context (if present)
            if let ctx = result.context, !ctx.isEmpty {
                labeledRow(icon: "clock", label: "背景", value: ctx)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Reply Suggestions

    private func replySuggestionsView(_ replies: [SuggestedReply]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("回复建议")

            ForEach(replies) { suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    private func suggestionRow(_ suggestion: SuggestedReply) -> some View {
        Button(action: {
            WeChatLauncher.copyText(suggestion.text)
            WeChatLauncher.openChat(named: item.chatName)
        }) {
            HStack(alignment: .top, spacing: 6) {
                toneBadge(suggestion.tone)
                Text(suggestion.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(suggestion.recommended
                ? Color.blue.opacity(0.10)
                : Color.white.opacity(0.04))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Open WeChat

    private var openWeChatButton: some View {
        HStack {
            Spacer()
            Button(action: {
                WeChatLauncher.openChat(named: item.chatName)
            }) {
                Text("打开微信")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.35))
    }

    private func labeledRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                Text(value)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color = {
            switch status.lowercased() {
            case let s where s.contains("活跃") || s.contains("热") || s.contains("active"): return .green
            case let s where s.contains("平静") || s.contains("normal") || s.contains("普通"): return .blue
            case let s where s.contains("争") || s.contains("紧张") || s.contains("urgent"): return .red
            default: return .gray
            }
        }()
        return HStack(spacing: 4) {
            Text("状态")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            pill(status, color: color)
        }
    }

    private func urgencyBadge(_ urgency: String) -> some View {
        let color: Color = {
            switch urgency.lowercased() {
            case "高", "urgent", "high": return .red
            case "中", "medium": return .orange
            default: return .gray
            }
        }()
        return HStack(spacing: 3) {
            Text("紧急度")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            pill(urgency, color: color)
        }
    }

    private func moodBadge(_ mood: String) -> some View {
        let color: Color = {
            switch mood.lowercased() {
            case let s where s.contains("积极") || s.contains("开心") || s.contains("positive"): return .green
            case let s where s.contains("消极") || s.contains("愤怒") || s.contains("negative"): return .red
            case let s where s.contains("焦虑") || s.contains("anxious"): return .orange
            default: return .blue
            }
        }()
        return HStack(spacing: 3) {
            Text("情绪")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            pill(mood, color: color)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func toneBadge(_ tone: String) -> some View {
        let color: Color = {
            switch tone {
            case "友好": return .green
            case "正式": return .blue
            case "简洁": return Color(red: 0.9, green: 0.6, blue: 0.1)
            default: return .gray
            }
        }()
        return Text(tone)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }
}
