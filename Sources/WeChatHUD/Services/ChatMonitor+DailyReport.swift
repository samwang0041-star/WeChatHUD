import Foundation

/// Daily report loading, generation, and markdown export.
/// Extracted from ChatMonitor to reduce the God Object. Extension on
/// the same class — @Published properties stay in the main file so
/// SwiftUI observation is unchanged.
extension ChatMonitor {

    func loadDailyReport(force: Bool = false) async {
        await loadDailyReport(for: dailyReportViewedDate, force: force)
    }

    func loadDailyReport(for date: Date, force: Bool = false) async {
        let dateKey = date.dailyReportDateKey
        let factsStamp = currentDailyReportFactsStamp()
        if !force, let cached = dailyReportCache[dateKey],
           Date().timeIntervalSince(cached) < 1800,
           dailyReport?.date.dailyReportDateKey == dateKey {
            if dailyReportCacheStamp[dateKey] == factsStamp {
                return
            }
        }
        let generation = beginDailyReportLoad()
        dailyReportError = nil
        dailyReportIsLoading = true

        let builder = DailyReportBuilder(
            store: store,
            replyDebtItems: replyDebtItems,
            stats: stats,
            strictness: discussionStrictness
        )
        let baseReport = builder.build(for: date)
        dailyReport = baseReport
        dailyReportGeneratedAt = baseReport.generatedAt

        // Seed insights dict from cache so cards can render annotations immediately.
        dailyReportActionInsights = store.loadActionInsights(dateKey: dateKey)
            .reduce(into: [:]) { $0[$1.actionID] = $1 }

        let urgentActions = baseReport.actions.filter {
            $0.urgency == .critical || $0.urgency == .high
        }

        async let enrichedReport = dailyReportGenerator.enrich(baseReport)
        let aiConfig = await aiService.currentConfig()
        let insightsTask: Task<[DailyReportActionInsight], Never>? = aiConfig.dailyReportActionInsightsEnabled
            ? Task { await dailyReportActionInsightGenerator.generate(for: urgentActions, dateKey: dateKey) }
            : nil

        let report = await enrichedReport
        let insights = await insightsTask?.value ?? []

        // A newer date request may have started while AI enrichment was in
        // flight. Keep that request's base/enriched report and loading state.
        guard dailyReportLoadGeneration == generation else { return }

        dailyReport = report
        dailyReportGeneratedAt = report.generatedAt
        dailyReportCache[dateKey] = report.generatedAt
        dailyReportCacheStamp[dateKey] = factsStamp
        dailyReportError = report.aiErrorMessage
        for ins in insights { dailyReportActionInsights[ins.actionID] = ins }
        dailyReportIsLoading = false
    }

    /// Local facts the 30-minute cache must not outlive: reply debt, live
    /// todos, open promises, and last successful sync.
    func currentDailyReportFactsStamp() -> String {
        let debts = replyDebtItems.map(\.id).sorted().joined(separator: ",")
        let tasks = discussionItems
            // Deliberately NOT keyed on the strictness level. The report's
            // numbers do follow the level, but the level is a display choice,
            // not a change in the facts — folding it into the stamp would
            // invalidate the 30-minute cache and re-run the AI pass every time
            // the user drags the control.
            .filter { $0.status == .pending && !$0.kind.isRecord }
            .map { String($0.id) }
            .sorted()
            .joined(separator: ",")
        let commits = commitments
            .filter { $0.status == .pending || $0.status == .overdue }
            .map(\.msgUID)
            .sorted()
            .joined(separator: ",")
        let sync = stats.lastSyncAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return debts + "|" + tasks + "|" + commits + "|" + sync
    }

    /// Re-derives the level-dependent slice of the loaded report after the user
    /// moves the strictness control, without re-running the AI pass. The
    /// builder's base pass is local and cheap; AI enrichment is keyed by action
    /// id, so insights for still-visible actions stay valid and the numbers
    /// agree with the badge/今天/the workspace immediately instead of going
    /// stale for the rest of the 30-minute cache window.
    func refreshDailyReportForStrictnessChange() {
        guard let current = dailyReport,
              current.date.dailyReportDateKey == dailyReportViewedDate.dailyReportDateKey else { return }
        let builder = DailyReportBuilder(
            store: store,
            replyDebtItems: replyDebtItems,
            stats: stats,
            strictness: discussionStrictness
        )
        let base = builder.build(for: dailyReportViewedDate)
        dailyReport = DailyReport(
            date: base.date,
            dateRange: base.dateRange,
            generatedAt: base.generatedAt,
            metrics: base.metrics,
            highlights: base.highlights,
            actions: base.actions,
            risks: base.risks,
            pendingAsks: base.pendingAsks,
            retrospectiveRunID: base.retrospectiveRunID,
            status: current.status,
            statusMessage: current.statusMessage,
            aiErrorMessage: current.aiErrorMessage,
            narrative: current.narrative,
            tomorrowFocus: current.tomorrowFocus,
            wechatDraft: current.wechatDraft
        )
        dailyReportGeneratedAt = base.generatedAt
    }

    func markDailyReportActionDone(_ action: DailyReportAction) {
        let dateKey = dailyReportViewedDate.dailyReportDateKey
        let state = DailyReportCommandState(
            dateKey: dateKey,
            itemID: action.id,
            state: .completed,
            completedAt: Date()
        )
        try? store.upsertDailyReportCommandState(state)

        switch action.type {
        case .todo:
            if let todoID = Int(action.relatedID) {
                store.updateTodoStatus(todoID: todoID, status: .completed, completedAt: Date())
            }
        case .ask:
            try? store.updatePendingAskStatus(msgUID: action.relatedID, status: .done)
        case .commitment:
            try? store.updateCommitmentStatus(msgUID: action.relatedID, status: .fulfilled)
        case .replyDebt:
            dismissReplyDebtFromLiveInbox(action)
        }

        reloadAIData()
        Task {
            await loadDailyReport(for: dailyReportViewedDate, force: true)
        }
    }

    /// 「今日小结」标记完成 for reply debt must use the same watermark as
    /// inbox 「标记完成」. Command-state alone is not enough: reply debt is
    /// recomputed from unread WeChat messages and would otherwise return
    /// to 今天 / 收件箱.
    private func dismissReplyDebtFromLiveInbox(_ action: DailyReportAction) {
        if let item = inboxItems.first(where: {
            $0.chatUsername == action.relatedID || $0.chatUsername == action.sourceChatUsername
        }) {
            _ = dismissInboxItem(item)
            return
        }

        let chatUsername = DailyReportCompletion.replyDebtChatUsername(for: action)
        guard !chatUsername.isEmpty else { return }

        if let debt = replyDebtItems.first(where: {
            $0.chatUsername == chatUsername || $0.chatUsername == action.sourceChatUsername
        }), let item = InboxBuilder.build(
            replyDebtItems: [debt],
            notifications: [],
            dismissed: [:]
        ).active.first {
            _ = dismissInboxItem(item)
            return
        }

        let ts = DailyReportCompletion.replyDebtDismissTimestamp(debtTimestamp: nil, now: Date())
        _ = dismissInboxItem(
            DailyReportCompletion.syntheticInboxItem(
                chatUsername: chatUsername,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts))
            )
        )
    }

    func dismissDailyReportRisk(_ risk: DailyReportRisk) {
        let dateKey = dailyReportViewedDate.dailyReportDateKey
        let state = DailyReportCommandState(
            dateKey: dateKey,
            itemID: risk.id,
            state: .dismissed,
            dismissedAt: Date()
        )
        try? store.upsertDailyReportCommandState(state)

        Task {
            await loadDailyReport(for: dailyReportViewedDate, force: true)
        }
    }

    func exportDailyReport() -> URL? {
        guard let report = dailyReport else { return nil }
        let states = store.loadDailyReportCommandStates(dateKey: report.date.dailyReportDateKey)
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report, commandStates: states)
        let md = DailyReportPresentationPolicy.markdown(for: report, viewModel: vm)

        let dateStr = report.date.dailyReportDateKey
        let filename = "WeChatHUD-日报-\(dateStr).md"
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let url = desktop.appendingPathComponent(filename)

        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[WCHUD] exportDailyReport failed: \(error)")
            return nil
        }
    }


    func exportReport() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        let filename = "WeChatHUD-\(dateStr).md"
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        var md = "# WeChatHUD 报告 — \(dateStr)\n\n"

        // Stats
        md += "## 概览\n\n"
        md += "- 未读: \(stats.unreadCount)\n"
        md += "- @提醒: \(stats.atMentionCount)\n"
        md += "- VIP: \(stats.vipCount)\n"
        md += "- 待回复: \(stats.replyDebtCount)\n\n"

        // Daily report
        if let report = dailyReport {
            md += "## 日报\n\n"
            if let narrative = report.narrative {
                md += "\(narrative)\n\n"
            }
            if let tomorrowFocus = report.tomorrowFocus {
                md += "### 明天重点\n\n\(tomorrowFocus)\n\n"
            }
        }

        // Commitments
        let pending = commitments.filter { $0.status == .pending }
        if !pending.isEmpty {
            md += "## 进行中的承诺 (\(pending.count))\n\n"
            for c in pending {
                md += "- \(c.content) → \(c.commitTo)"
                if let d = c.deadlineAt { md += " (截止: \(df.string(from: d)))" }
                md += "\n"
            }
            md += "\n"
        }

        // Reply debt
        if !replyDebtItems.isEmpty {
            md += "## 待回复 (\(replyDebtItems.count))\n\n"
            for item in replyDebtItems.prefix(10) {
                md += "- [\(item.priority.rawValue.uppercased())] \(item.chatName): \(item.preview)\n"
            }
            md += "\n"
        }

        // Recalled messages (intelligence)
        let recalls = store.loadRecalledMessages(limit: 10)
        if !recalls.isEmpty {
            md += "## 撤回消息 (\(recalls.count))\n\n"
            for r in recalls {
                md += "- \(r.senderName) 撤回了: \(r.originalText.prefix(50))\n"
            }
            md += "\n"
        }

        // Whitelist stats
        let whitelist = store.getWhitelist()
        md += "## 关注对象 (\(whitelist.count))\n\n"
        let vips = whitelist.filter { $0.attentionLevel == .vip }
        let watches = whitelist.filter { $0.attentionLevel == .watch }
        md += "- VIP: \(vips.count) 人\n"
        md += "- 关注: \(watches.count) 人\n\n"

        md += "---\n*由 WeChatHUD 自动生成*\n"

        do {
            try md.write(to: desktop, atomically: true, encoding: .utf8)
            return desktop
        } catch {
            print("[WCHUD] export failed: \(error)")
            return nil
        }
    }


}

/// Watermark helpers for daily-report reply-debt completion.
/// Kept tiny and side-effect free so the inbox dismiss rule can be tested
/// without constructing ChatMonitor.
enum DailyReportCompletion {
    /// `relatedID` is the chat username for `.replyDebt` actions.
    static func replyDebtChatUsername(for action: DailyReportAction) -> String {
        action.relatedID.isEmpty ? action.sourceChatUsername : action.relatedID
    }

    /// Prefer the live debt's own timestamp so a newer inbound can still
    /// resurface — the same rule InboxBuilder uses for dismissed watermarks.
    static func replyDebtDismissTimestamp(debtTimestamp: Date?, now: Date) -> Int {
        Int((debtTimestamp ?? now).timeIntervalSince1970)
    }

    /// Fallback inbox row so `dismissInboxItem` can persist the watermark
    /// when the chat is not currently in `inboxItems`.
    static func syntheticInboxItem(chatUsername: String, timestamp: Date) -> InboxItem {
        InboxItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatUsername,
            senderName: "",
            preview: "",
            isGroup: chatUsername.contains("@chatroom"),
            timestamp: timestamp,
            actionRequired: true,
            priority: .p2,
            isVIP: false,
            isWhitelisted: true,
            unreadCount: 0,
            isAtMention: false,
            askType: .none,
            reasons: [],
            suggestedReplyMinutes: 0,
            status: .active,
            dismissedAtMsgId: nil
        )
    }
}
