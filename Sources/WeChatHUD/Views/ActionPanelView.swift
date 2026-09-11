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
    @EnvironmentObject var panelState: PanelState
    let item: InboxItem
    var showsConversationLink = true

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
    @State private var replyRequested: Bool = false
    @State private var generationKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(IslandInk.divider)

            VStack(alignment: .leading, spacing: 10) {
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
                    errorRowWithRetry(label: "回复建议生成失败", retry: { runReplySuggestions() })
                default:
                    EmptyView()
                }

                EmptyView()
            }
            .padding(.horizontal, IslandMetrics.rowInset)
            .padding(.vertical, 10)
            .background(IslandInk.bar)
        }
        .onAppear { prepareForCurrentItem(reset: generationKey != itemGenerationKey) }
        .onChange(of: itemGenerationKey) { _, _ in
            prepareForCurrentItem(reset: true)
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
                    .islandMeta()
                    .foregroundColor(IslandInk.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .groupResult(let result):
            groupHeadlineCard(result)

        case .privateResult(let result):
            headlineCard(
                title: privateHeadlineTitle(result),
                primary: privatePrimary(result),
                context: privateContext(result),
                vibe: privateVibe(result)
            )

        case .error(let message):
            headlineCard(
                title: "分析暂不可用",
                primary: item.aiSummary ?? item.preview,
                context: message,
                vibe: nil
            )
        }
    }

    /// Render the rich headline. `primary` is the one-sentence
    /// "what do they want". `context` is the background prose that
    /// situates the message (what's being discussed, what you said
    /// last, etc.). `vibe` is a compact tonal/urgency descriptor
    /// — lives in a discreet pill to the right of the header label.
    private func headlineCard(title: String, primary: String, context: String?, vibe: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .islandMeta()
                    .foregroundColor(.accentColor)
                Text(title)
                    .islandSection()
                    .foregroundColor(.accentColor.opacity(0.85))
                if let vibe = vibe, !vibe.isEmpty {
                    Text(vibe)
                        .islandMicro()
                        .foregroundColor(.orange.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
                Spacer()
            }

            Text(primary)
                .islandRowTitle()
                .foregroundColor(IslandInk.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let context = context, !context.isEmpty {
                Text(context)
                    .islandMeta()
                    .foregroundColor(IslandInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    private func groupHeadlineCard(_ result: ChatAnalyzer.GroupAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .islandMeta()
                    .foregroundColor(.accentColor)
                Text(item.actionPanelTitle)
                    .islandSection()
                    .foregroundColor(.accentColor.opacity(0.9))
                Spacer(minLength: 0)
                statusPill(for: result.status)
            }

            Text(groupPrimary(result))
                .islandRowTitle()
                .foregroundColor(IslandInk.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                if !cleanDisplayText(result.topics).isEmpty {
                    compactInfoLine(icon: "number", label: "话题", text: cleanDisplayText(result.topics, limit: 34))
                }
                if let decisions = result.decisions, !cleanDisplayText(decisions).isEmpty {
                    compactInfoLine(icon: "checkmark.seal", label: "决议", text: cleanDisplayText(decisions, limit: 34))
                }
                if let speakers = result.key_speakers, !cleanDisplayText(speakers).isEmpty {
                    compactInfoLine(icon: "quote.bubble", label: "依据", text: cleanEvidenceText(speakers))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    private func statusPill(for status: String) -> some View {
        let normalized = status.lowercased()
        let text: String
        let color: Color
        if normalized == "waiting_for_me" {
            text = "等你"
            color = .orange
        } else if normalized == "concluded" {
            text = "已定"
            color = .green
        } else {
            text = "讨论中"
            color = .blue
        }
        return Text(text)
            .islandMicro()
            .foregroundColor(color.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .cornerRadius(5)
    }

    private func compactInfoLine(icon: String, label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .islandMicro()
                .foregroundColor(IslandInk.tertiary)
                .frame(width: 12, height: 14)
            Text(label)
                .islandMicro()
                .foregroundColor(IslandInk.tertiary)
                .frame(width: 28, alignment: .leading)
            Text(text)
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Headline content helpers

    private func privateHeadlineTitle(_ r: ChatAnalyzer.PrivateAnalysis) -> String {
        privateIsLowSignalSmalltalk(r) ? "对方在说什么" : item.actionPanelTitle
    }

    private func privatePrimary(_ r: ChatAnalyzer.PrivateAnalysis) -> String {
        if privateIsLowSignalSmalltalk(r),
           let summary = item.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if !r.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return r.intent
        }
        if !r.one_liner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return r.one_liner
        }
        return item.preview
    }

    private func groupPrimary(_ r: ChatAnalyzer.GroupAnalysis) -> String {
        if item.semanticState == .groupActionRequired,
           let actions = r.my_action_items,
           !actions.isEmpty {
            return cleanDisplayText(actions, limit: 42)
        }
        let oneLiner = cleanDisplayText(r.one_liner, limit: 42)
        if !oneLiner.isEmpty { return oneLiner }
        return cleanDisplayText(r.topics, limit: 42)
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
        if let speakers = r.key_speakers, !speakers.isEmpty {
            parts.append("依据:\(speakers)")
        }
        if r.status == "waiting_for_me" {
            parts.append("状态:等你回应")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func cleanDisplayText(_ text: String, limit: Int = 60) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "null", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(max(1, limit - 1))) + "…"
    }

    private func cleanEvidenceText(_ text: String) -> String {
        cleanDisplayText(
            text
                .replacingOccurrences(of: "；", with: " · ")
                .replacingOccurrences(of: ";", with: " · "),
            limit: 72
        )
    }

    /// Background paragraph for private chats: explicit context +
    /// the reasoning behind the urgency signal (so the user
    /// understands WHY the AI flagged it as urgent).
    private func privateContext(_ r: ChatAnalyzer.PrivateAnalysis) -> String? {
        var parts: [String] = []
        if let ctx = r.context, !ctx.isEmpty, !privateIsLowSignalSmalltalk(r) {
            parts.append("背景:\(ctx)")
        }
        if !r.urgency_reason.isEmpty {
            parts.append(r.urgency_reason)
        }
        if !r.mood_evidence.isEmpty,
           let vibe = privateVibe(r),
           !vibe.isEmpty {
            parts.append("语气依据:\(r.mood_evidence)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func privateIsLowSignalSmalltalk(_ r: ChatAnalyzer.PrivateAnalysis) -> Bool {
        let urgency = r.urgency.lowercased()
        guard urgency == "low" || urgency == "低" else { return false }
        guard item.askType == .none else { return false }
        let text = [r.intent, r.one_liner, r.urgency_reason, r.context ?? ""].joined(separator: " ")
        let casualSignals = ["闲聊", "分享", "告知", "同步", "近况", "寒暄", "无请求", "无任务"]
        return casualSignals.contains { text.contains($0) }
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
            if showsConversationLink || item.semanticState != .groupMentionFYI {
            Button(action: {
                runPrimaryCTA()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .islandMeta()
                    Text(item.primaryCTATitle)
                        .islandButton()
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            }

            if item.replySuggestionMode != .hidden {
                Button(action: runReplySuggestions) {
                    HStack(spacing: 5) {
                        if case .loading = replyState {
                            ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "lightbulb.fill")
                                .islandMeta()
                        }
                        Text(item.replySuggestionButtonTitle)
                            .islandButton()
                    }
                    .foregroundColor(IslandInk.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
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
                    .islandMicro()
                    .foregroundColor(.yellow.opacity(0.8))
                Text("回复建议")
                    .islandSection()
                    .foregroundColor(IslandInk.secondary)
            }
            ForEach(replies) { suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    private func suggestionRow(_ suggestion: SuggestedReply) -> some View {
        Button(action: {
            monitor.openWeChatChatAndPaste(item.chatUsername, text: suggestion.text)
        }) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        toneBadge(suggestion.tone)
                        Text(suggestion.text)
                            .islandRowBody()
                            .foregroundColor(IslandInk.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let rationale = suggestion.rationale, !rationale.isEmpty {
                        Text(rationale)
                            .islandMicro()
                            .foregroundColor(IslandInk.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .islandMicro()
                    .foregroundColor(IslandInk.quaternary)
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

    private var itemGenerationKey: String {
        item.generationKey
    }

    private func prepareForCurrentItem(reset: Bool) {
        if reset {
            analysisState = .idle
            replyState = .idle
            replyRequested = false
        }
        generationKey = itemGenerationKey
        applyPrefetch()

        // If the prefetch slot exists (even partially — replies
        // maybe arrived first and analysis is still in flight),
        // mark the missing slots as .loading and trust the
        // background prefetch to commit results. Only when there
        // is NO prefetch entry at all do we fall back to firing
        // on-demand — otherwise we'd duplicate the in-flight
        // round-trip and defeat the whole prefetch design.
        let hasEntry = monitor.actionPrefetch[item.chatUsername]?.generationKey == item.generationKey
        if !hasEntry {
            if case .idle = analysisState { runAnalysis() }
            if case .idle = replyState, item.automaticReplySuggestionsAllowed { runReplySuggestions() }
        } else {
            if case .idle = analysisState { analysisState = .loading }
            if case .idle = replyState, item.automaticReplySuggestionsAllowed { replyState = .loading }
        }
    }

    /// Copy whatever is present in the prefetch cache into local
    /// state. Called on appear and every time `actionPrefetch`
    /// updates (progressive commits). Leaves non-idle states alone
    /// so a completed result doesn't get overwritten by a stale
    /// partial entry. When the prefetch finishes with no usable
    /// result (API error / timeout), flips state to `.error` so
    /// the user sees a failure message instead of an endless
    /// spinner.
    private func applyPrefetch() {
        guard let entry = monitor.actionPrefetch[item.chatUsername],
              entry.generationKey == item.generationKey else { return }

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
                analysisState = .error(entry.analysisError ?? "分析失败，可能是 AI 服务超时")
            }
        }

        let isReplyWaitable: Bool = {
            if case .loading = replyState { return true }
            if case .idle = replyState { return true }
            return false
        }()
        if isReplyWaitable {
            if !entry.replies.isEmpty && shouldExposeReplies {
                replyState = .results(entry.replies)
            } else if entry.repliesAttempted && item.automaticReplySuggestionsAllowed {
                replyState = .error
            }
        }
    }

    private func runPrimaryCTA() {
        switch item.semanticState {
        case .groupMentionFYI:
            panelState.showChatDetail(chatUsername: item.chatUsername,
                                      chatName: monitor.displayName(for: item.chatUsername))
        case .handled:
            monitor.restoreInboxItem(item)
        default:
            monitor.openWeChatChat(item.chatUsername)
        }
    }

    private func runAnalysis() {
        let expectedKey = itemGenerationKey
        analysisState = .loading
        Task {
            if item.isGroup {
                let (result, err) = await monitor.analyzeGroupChat(item: item)
                guard generationKey == expectedKey else { return }
                if let result = result {
                    analysisState = .groupResult(result)
                } else {
                    analysisState = .error(err ?? "分析失败")
                }
            } else {
                let (result, err) = await monitor.analyzePrivateChat(item: item)
                guard generationKey == expectedKey else { return }
                if let result = result {
                    analysisState = .privateResult(result)
                } else {
                    analysisState = .error(err ?? "分析失败")
                }
            }
        }
    }

    private func runReplySuggestions() {
        guard item.replySuggestionMode != .hidden else { return }
        let expectedKey = itemGenerationKey
        replyRequested = true
        replyState = .loading
        Task {
            if let results = await monitor.loadReplySuggestions(for: item) {
                guard generationKey == expectedKey else { return }
                replyState = .results(results)
            } else {
                guard generationKey == expectedKey else { return }
                replyState = .error
            }
        }
    }

    private var replyIsLoading: Bool {
        if case .loading = replyState { return true }
        return false
    }

    private var shouldExposeReplies: Bool {
        item.automaticReplySuggestionsAllowed || replyRequested
    }

    // MARK: - Loading / Error

    private func loadingRow(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
            Text(label).islandMeta().foregroundColor(IslandInk.tertiary)
        }
        .padding(.vertical, 2)
    }


    private func errorRowWithRetry(label: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .islandMeta()
                .foregroundColor(.red.opacity(0.6))
            Button(action: retry) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.clockwise")
                        .islandMicro()
                    Text("重试")
                        .islandMicro()
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tone badge (for reply suggestions)

    private func toneBadge(_ tone: String) -> some View {
        let label: String = {
            switch tone.lowercased() {
            case "recommended": return "推荐"
            case "friendly": return "友好"
            case "formal", "professional": return "正式"
            case "brief", "concise": return "简洁"
            default: return tone
            }
        }()
        let color: Color = {
            switch label {
            case "推荐": return .accentColor
            case "友好": return .green
            case "正式": return .blue
            case "简洁": return Color(red: 0.9, green: 0.6, blue: 0.1)
            default: return .gray
            }
        }()
        return Text(label)
            .islandMicro()
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }
}
