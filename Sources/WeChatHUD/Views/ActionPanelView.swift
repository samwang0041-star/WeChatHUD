import SwiftUI

/// Expanded action panel shown when user clicks an inbox row.
///
/// One unified headline + CTAs + inline reply suggestions. Earlier
/// versions split the information across five separate blocks
/// (action item / intent / collapsibles / urgency-mood badges /
/// background context) which made every row feel scattered and hard
/// to scan. The AI is already asked to produce a single actionable
/// sentence — showing that sentence + a couple of primary actions
/// is enough for the user to decide what to do without hunting.
///
/// Analysis + reply suggestions are pre-fetched by ChatMonitor
/// right after each scan, so by the time the user clicks in the
/// content is already cached and the panel renders instantly.
struct ActionPanelView: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: InboxItem

    // MARK: - State

    enum AnalysisState {
        case idle
        case loading
        case groupResult(ChatAnalyzer.GroupAnalysis)
        case privateResult(ChatAnalyzer.PrivateAnalysis)
        case error(String)
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

            VStack(alignment: .leading, spacing: 12) {
                // One headline card — condenses everything the old
                // panel used to scatter across 4-5 separate blocks
                // (intent + urgency + mood + context + reasoning)
                // into a single actionable sentence. Detail-hunting
                // happens in the detail window; the row expansion is
                // about "tell me in one line what to do" and getting
                // the user back to the task fast.
                headlineBlock

                primaryCTAs

                switch replyState {
                case .loading:
                    loadingRow(label: "正在生成回复建议…")
                case .results(let replies) where !replies.isEmpty:
                    replySuggestionsView(replies)
                case .error:
                    errorRow(label: "回复建议生成失败")
                default:
                    EmptyView()
                }

                if case .error(let msg) = analysisState {
                    errorRow(label: msg)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.03))
        }
        .onAppear {
            hasProfile = monitor.hasRelationshipProfile(for: item.chatUsername)
            applyPrefetch()

            // If the prefetch slot exists (even partially — replies
            // maybe arrived first and analysis is still in flight),
            // mark the missing slots as .loading and trust the
            // background prefetch to commit results. Only when there
            // is NO prefetch entry at all do we fall back to firing
            // on-demand — otherwise we'd duplicate the in-flight
            // round-trip and defeat the whole prefetch design.
            let ts = Int(item.timestamp.timeIntervalSince1970)
            let hasEntry = monitor.actionPrefetch[item.chatUsername]?.timestamp == ts
            if !hasEntry {
                if case .idle = analysisState { runAnalysis() }
                if case .idle = replyState, hasProfile { runReplySuggestions() }
            } else {
                if case .idle = analysisState { analysisState = .loading }
                if case .idle = replyState, hasProfile { replyState = .loading }
            }
        }
        // Pick up prefetch slots as they land. Progressive commits
        // — replies arrive, analysis arrives — update whichever
        // part is still waiting without re-firing work that the
        // background prefetch has already claimed.
        .onReceive(monitor.$actionPrefetch) { _ in
            applyPrefetch()
        }
    }

    // MARK: - Headline (single unified block)

    /// One card. Contains everything the user needs to decide how
    /// to reply: what the sender wants, the background context, and
    /// their attitude/urgency — in one coherent block so the user
    /// doesn't have to hunt across 5 separate widgets.
    @ViewBuilder
    private var headlineBlock: some View {
        switch analysisState {
        case .loading, .idle:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                Text("AI 正在整理重点…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .groupResult(let result):
            headlineCard(
                primary: groupPrimary(result),
                context: groupContext(result),
                vibe: nil
            )

        case .privateResult(let result):
            headlineCard(
                primary: result.intent,
                context: privateContext(result),
                vibe: privateVibe(result)
            )

        case .error:
            EmptyView()
        }
    }

    /// Render the rich headline. `primary` is the one-sentence
    /// "what do they want". `context` is the background prose that
    /// situates the message (what's being discussed, what you said
    /// last, etc.). `vibe` is a compact tonal/urgency descriptor
    /// — lives in a discreet pill to the right of the header label.
    private func headlineCard(primary: String, context: String?, vibe: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("他想要什么")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor.opacity(0.85))
                if let vibe = vibe, !vibe.isEmpty {
                    Text(vibe)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
                Spacer()
            }

            Text(primary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            if let context = context, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    // MARK: - Headline content helpers

    private func groupPrimary(_ r: ChatAnalyzer.GroupAnalysis) -> String {
        if let actions = r.my_action_items, !actions.isEmpty { return actions }
        return r.one_liner
    }

    /// Background paragraph for group chats: combines the big-picture
    /// one-liner (if it's different from the action item), relevant
    /// topics, and any decisions that have already been locked in.
    private func groupContext(_ r: ChatAnalyzer.GroupAnalysis) -> String? {
        var parts: [String] = []
        if let actions = r.my_action_items, !actions.isEmpty,
           !r.one_liner.isEmpty, r.one_liner != actions {
            parts.append("大局:\(r.one_liner)")
        }
        if !r.topics.isEmpty {
            parts.append("话题:\(r.topics)")
        }
        if let decisions = r.decisions, !decisions.isEmpty {
            parts.append("已有决议:\(decisions)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Background paragraph for private chats: explicit context +
    /// the reasoning behind the urgency signal (so the user
    /// understands WHY the AI flagged it as urgent).
    private func privateContext(_ r: ChatAnalyzer.PrivateAnalysis) -> String? {
        var parts: [String] = []
        if let ctx = r.context, !ctx.isEmpty {
            parts.append("背景:\(ctx)")
        }
        if !r.urgency_reason.isEmpty {
            parts.append(r.urgency_reason)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact tonal pill: combines urgency + mood into a single
    /// short label (e.g. "急·焦虑"). Hidden when there's nothing
    /// noteworthy to say — no "normal·neutral" clutter.
    private func privateVibe(_ r: ChatAnalyzer.PrivateAnalysis) -> String? {
        var parts: [String] = []
        let u = r.urgency.lowercased()
        if u == "高" || u == "urgent" || u == "high" { parts.append("急") }
        else if u == "中" || u == "medium" { parts.append("一般") }
        let mood = r.mood
        let moodShort: String?
        if mood.contains("焦虑") || mood.lowercased().contains("anxious") {
            moodShort = "焦虑"
        } else if mood.contains("愤怒") || mood.contains("消极") {
            moodShort = "负面"
        } else if mood.contains("开心") || mood.contains("积极") {
            moodShort = "积极"
        } else {
            moodShort = nil
        }
        if let m = moodShort { parts.append(m) }
        return parts.isEmpty ? nil : parts.joined(separator: "·")
    }

    // MARK: - 2. Primary CTAs

    private var primaryCTAs: some View {
        HStack(spacing: 8) {
            Button(action: {
                WeChatLauncher.openChat(named: item.chatName)
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11))
                    Text("打开微信回复")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            if hasProfile {
                Button(action: runReplySuggestions) {
                    HStack(spacing: 5) {
                        if case .loading = replyState {
                            ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 11))
                        }
                        Text("回复建议")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(replyIsLoading)
            }
        }
    }

    // MARK: - Reply suggestions

    private func replySuggestionsView(_ replies: [SuggestedReply]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow.opacity(0.8))
                Text("回复建议")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
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
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(suggestion.recommended
                ? Color.blue.opacity(0.1)
                : Color.white.opacity(0.04))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Copy whatever is present in the prefetch cache into local
    /// state. Called on appear and every time `actionPrefetch`
    /// updates (progressive commits). Leaves non-idle states alone
    /// so a completed result doesn't get overwritten by a stale
    /// partial entry. When the prefetch finishes with no usable
    /// result (API error / timeout), flips state to `.error` so
    /// the user sees a failure message instead of an endless
    /// spinner.
    private func applyPrefetch() {
        let ts = Int(item.timestamp.timeIntervalSince1970)
        guard let entry = monitor.actionPrefetch[item.chatUsername],
              entry.timestamp == ts else { return }

        let isAnalysisWaitable: Bool = {
            if case .loading = analysisState { return true }
            if case .idle = analysisState { return true }
            return false
        }()
        if isAnalysisWaitable {
            if let g = entry.groupAnalysis {
                analysisState = .groupResult(g)
            } else if let p = entry.privateAnalysis {
                analysisState = .privateResult(p)
            } else if entry.analysisAttempted {
                analysisState = .error("分析失败，可能是 AI 服务超时")
            }
        }

        let isReplyWaitable: Bool = {
            if case .loading = replyState { return true }
            if case .idle = replyState { return true }
            return false
        }()
        if isReplyWaitable {
            if !entry.replies.isEmpty {
                replyState = .results(entry.replies)
            } else if entry.repliesAttempted && hasProfile {
                replyState = .error
            }
        }
    }

    private func runAnalysis() {
        analysisState = .loading
        Task {
            if item.isGroup {
                let (result, err) = await monitor.analyzeGroupChat(item: item)
                if let result = result {
                    analysisState = .groupResult(result)
                } else {
                    analysisState = .error(err ?? "分析失败")
                }
            } else {
                let (result, err) = await monitor.analyzePrivateChat(item: item)
                if let result = result {
                    analysisState = .privateResult(result)
                } else {
                    analysisState = .error(err ?? "分析失败")
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

    private var replyIsLoading: Bool {
        if case .loading = replyState { return true }
        return false
    }

    // MARK: - Loading / Error

    private func loadingRow(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
            Text(label).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
        }
        .padding(.vertical, 2)
    }

    private func errorRow(label: String) -> some View {
        Text(label)
            .font(.system(size: 10))
            .foregroundColor(.red.opacity(0.6))
            .padding(.vertical, 2)
    }

    // MARK: - Tone badge (for reply suggestions)

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
