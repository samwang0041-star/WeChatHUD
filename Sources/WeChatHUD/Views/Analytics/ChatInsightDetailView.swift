import SwiftUI

struct ChatInsightMessageStats: Equatable {
    let total: Int
    let mine: Int
    let others: Int

    var myRatio: Double {
        total > 0 ? Double(mine) / Double(total) : 0
    }

    init(stats: ChatStatsData?, result: ChatInsightResult?) {
        // Message totals are measured from the local scan. AI topics are a
        // derived summary and may be empty or incomplete.
        _ = result
        let localTotal = max(0, stats?.messageCount ?? 0)
        let localMine = min(max(0, stats?.myMessageCount ?? 0), localTotal)
        total = localTotal
        mine = localMine
        others = localTotal - localMine
    }
}

/// Detail view for a single chat — macOS native style with card modules.
/// Shows pure-algorithm stats immediately, AI results overlay when available.
struct ChatInsightDetailView: View {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let stats: ChatStatsData?
    let result: ChatInsightResult?
    @ObservedObject var insightCoordinator: InsightCoordinator
    @Binding var selectedDate: Date

    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore
    @State private var surface: ReviewSurface = .overview

   private enum ReviewSurface: String, CaseIterable {
       case overview = "概览"
       case timeline = "对话时间线"
   }

    private var isAnalyzing: Bool {
        insightCoordinator.chatInsightLoading.contains(chatUsername)
    }

    private var analysisError: String? {
        insightCoordinator.chatInsightErrors[chatUsername]
    }

    private var analyzeActionTitle: String {
        if isAnalyzing { return "正在分析…" }
        switch analysisError {
        case CompanionInteractionCopy.followListUnreadableAnalysis:
            return "再试一次"
        case CompanionInteractionCopy.notOnFollowList:
            return "去关注谁"
        default:
           return result == nil ? "分析" : "重新分析"
       }
   }

    private var analyzeActionSymbol: String {
        if isAnalyzing { return "sparkles" }
        switch analysisError {
        case CompanionInteractionCopy.followListUnreadableAnalysis:
            return "arrow.clockwise"
        case CompanionInteractionCopy.notOnFollowList:
            return "person.badge.plus"
        default:
            return "sparkles"
        }
    }

   private var analyzeActionHint: String {
        if isAnalyzing { return "正在分析这段聊天" }
        switch analysisError {
        case CompanionInteractionCopy.followListUnreadableAnalysis:
            return "先重读关注名单，再分析这段聊天"
        case CompanionInteractionCopy.notOnFollowList:
            return "先把这个对话加进关注名单"
        default:
           return result == nil ? "分析这段聊天" : "按这个日期重新分析"
       }
   }

    /// Filled jade is for starting analysis. Retrying a failed follow-list
    /// read, or sending the user to 关注谁, is a recovery — same weight as
    /// the other jade-ink actions on this page, not a second primary.
    private var analyzeActionIsPrimary: Bool {
        if isAnalyzing { return true }
        switch analysisError {
        case CompanionInteractionCopy.followListUnreadableAnalysis,
             CompanionInteractionCopy.notOnFollowList:
            return false
        default:
            return true
        }
    }

   private func runAnalyzeAction() {
       if analysisError == CompanionInteractionCopy.notOnFollowList {
            panelState.insightSelectedChatUsername = chatUsername
            panelState.pendingSettingsTab = "contacts"
           NotificationCenter.default.post(name: .hudSwitchTab, object: "contacts")
           return
       }
        Task { await monitor.analyzeOneChat(chatUsername: chatUsername, date: selectedDate) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if result != nil || stats != nil {
                analysisContent
            } else {
                loadingState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

   // MARK: - Header

    @ViewBuilder
    private var headerAnalyzeButton: some View {
        let button = Button(action: runAnalyzeAction) {
            Label(analyzeActionTitle, systemImage: analyzeActionSymbol)
        }
        .controlSize(.small)
        .disabled(isAnalyzing)
        .help(analyzeActionHint)
        .accessibilityHint(analyzeActionHint)
        if analyzeActionIsPrimary {
            button
                .tint(SettingsView.Tab.insight.accentColor)
                .buttonStyle(.borderedProminent)
        } else {
            button
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
        }
    }

   private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                   Circle()
                       .fill(CompanionPalette.jade.opacity(0.14))
                       .frame(width: 44, height: 44)
                    if let monogram = ContactIdentityIndex.avatarMonogram(from: chatName) {
                        Text(monogram)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CompanionPalette.jadeInk)
                    } else {
                        Image(systemName: isGroup ? "person.3" : "person")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CompanionPalette.jadeInk)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(chatName)
                        .workspaceTitle()
                    Text(headerSummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                DatePicker("回顾日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(width: 120)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("回顾日期")

                headerAnalyzeButton
           }

           HStack(spacing: 16) {
               ForEach(ReviewSurface.allCases, id: \.self) { tab in
                   Button(tab.rawValue) { surface = tab }
                       .buttonStyle(CompanionPressStyle())
                       .companionAnimation(CompanionMotion.hover(), value: surface)
                       .font(.system(size: 13, weight: surface == tab ? .semibold : .regular))
                        .foregroundStyle(surface == tab ? SettingsView.Tab.insight.accentColor : .secondary)
                       .padding(.bottom, 6)
                       .overlay(alignment: .bottom) {
                           Rectangle()
                                .fill(surface == tab ? SettingsView.Tab.insight.accentColor : Color.clear)
                               .frame(height: 2)
                       }
               }
                Spacer()
                // Page-level or contextual, not both. 查看待办 lives next to the
                // 待办 list it opens, so it is not repeated here; 查看原文 only
                // needs the header on 对话时间线, where the body has no link of
                // its own (and the empty state tells you to use one).
                if surface == .timeline {
                    Button("查看原文") {
                        panelState.showChatDetail(chatUsername: chatUsername, chatName: chatName)
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .workspaceGround()
    }

    private var headerSummary: String {
        var parts = [dateLabel]
        if let stats {
            if isGroup, stats.participantCount > 0 {
                parts.append("当天 \(stats.participantCount) 人发过言")
            }
            if stats.messageCount > 0 {
                parts.append("\(stats.messageCount) 条消息")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var categoryColor: Color {
        switch category {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }

    private var dateLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 EEEE"
        fmt.locale = Locale(identifier: "zh_CN")
        let dateStr = fmt.string(from: selectedDate)

        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) {
            return "今天 · \(dateStr)"
        } else if cal.isDateInYesterday(selectedDate) {
            return "昨天 · \(dateStr)"
        } else {
            return dateStr
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            if insightCoordinator.chatInsightLoading.contains(chatUsername) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在整理 \(dateLabel)…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
           } else if let error = insightCoordinator.chatInsightErrors[chatUsername] {
               Image(systemName: "exclamationmark.circle")
                   .font(.system(size: WorkspaceType.title))
                   .foregroundColor(.orange.opacity(0.7))
                   .transition(.companionStatusReveal)
               Text(error)
                   .font(.system(size: 13))
                   .foregroundColor(.secondary)
                   .transition(.companionStatusReveal)
                Button(analyzeActionTitle) { runAnalyzeAction() }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .help(analyzeActionHint)
                    .accessibilityHint(analyzeActionHint)
           } else {
                Image(systemName: "sparkles")
                    .font(.system(size: WorkspaceType.title))
                    .foregroundColor(.orange.opacity(0.4))
                Text("选一个日期后，这里会整理这段聊天发生了什么。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .companionAnimation(CompanionMotion.ease(), value: insightCoordinator.chatInsightErrors[chatUsername])
    }

    // MARK: - Analysis content

    @ViewBuilder
    private var analysisContent: some View {
        let messageStats = ChatInsightMessageStats(stats: stats, result: result)
        let msgCount = messageStats.total

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if surface == .timeline {
                    timelineContent
                } else {
                    overviewContent(msgCount: msgCount)
                }
                Spacer().frame(height: 20)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func overviewContent(msgCount: Int) -> some View {
        if let snap = store.loadRelationshipRadarSnapshot(chatUsername: chatUsername) {
            RelationshipRadarCard(
                snapshots: [snap],
                displayName: { _ in chatName }
            )
        }
       if let result {
           VStack(alignment: .leading, spacing: 10) {
               Text(result.headline)
                   .workspaceTitle()
                   .fixedSize(horizontal: false, vertical: true)
               // Not "AI 解读": the block further down labels the day's read
               // (result.insight) with exactly that word, and two cards on one
               // screen called AI 解读 showed different fields.
               Label("行动建议", systemImage: "sparkles")
                   .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsView.Tab.insight.accentColor)
               if !result.suggestion.isEmpty {
                   Text(result.suggestion)
                       .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .companionSurface(padding: 20)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if insightCoordinator.chatInsightLoading.contains(chatUsername) {
                        ProgressView().controlSize(.small)
                        Text("正在整理这段聊天…")
                    } else {
                        Image(systemName: "sparkles")
                        Text(insightCoordinator.chatInsightErrors[chatUsername] ?? "还没有 AI 解读，先看来源和待办。")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
               if !insightCoordinator.chatInsightLoading.contains(chatUsername) {
                    Button(analyzeActionTitle) {
                        runAnalyzeAction()
                    }
                   .buttonStyle(CompanionPressStyle())
                   .foregroundStyle(CompanionPalette.jadeInk)
                    .help(analyzeActionHint)
                    .accessibilityHint(analyzeActionHint)
               }
            }
        }

        // The day's read belongs under the headline it expands on. It used to
        // sit below the activity chart and both 待办 lists — the last thing on
        // the page for the one paragraph that explains the day.
        if let result, !result.insight.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let split = ChatInsightService.splitCoverageNotice(result.insight)
                if let notice = split.notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("AI 解读")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(split.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Button("查看原文") {
                    panelState.showChatDetail(chatUsername: chatUsername, chatName: chatName)
                }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(SettingsView.Tab.insight.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .companionSurface(padding: 18)
        } else if msgCount > 0 {
            Button("查看原文") {
                panelState.showChatDetail(chatUsername: chatUsername, chatName: chatName)
            }
            .buttonStyle(CompanionPressStyle())
            .foregroundStyle(SettingsView.Tab.insight.accentColor)
        }

        if let hourly = stats?.messagesByHour, hourly.contains(where: { $0 > 0 }) {
            moduleCard("对话活跃度", icon: "chart.bar") {
                hourlyBarChart(hourly)
                    .frame(height: 100)
            }
        }

        if !followUps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(ChatReviewFollowUps.heading(selectedDate: selectedDate))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(followUps.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 15, weight: .semibold))
                            Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Bordered, not a second filled accent.
                        //
                        // This page already has one filled primary action in the
                        // header (分析 / 重新分析). Two filled accent controls on
                        // one screen — in two different hues, mint in the header
                        // and jade here — leaves the eye no ranking to follow;
                        // macOS gives a view one prominent action and styles the
                        // rest as bordered or plain.
                        Button("查看待办") {
                            panelState.pendingDiscussionChatUsername = chatUsername
                            panelState.pendingSettingsTab = "tasks"
                            panelState.showDetail()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                          .stroke(CompanionPalette.jade.opacity(0.28), lineWidth: 1)
                   )
               }
                if livePendingCount > followUps.count {
                    Button("还有 \(livePendingCount - followUps.count) 件在待办里") {
                        panelState.pendingDiscussionChatUsername = chatUsername
                        panelState.pendingSettingsTab = "tasks"
                        panelState.showDetail()
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .font(.system(size: 13, weight: .medium))
                }
           }
       }

        if let result {
            let aiWait = result.waitingForMe.map(\.what).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let aiActions = result.actionItems.map(\.what).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !aiWait.isEmpty || !aiActions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // "候选", not a second "待办": the block above this one is
                    // the authoritative list, and two adjacent lists both named
                    // 待办 is what the disclaimer below then has to undo.
                    Text("AI 读到的候选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array((aiActions + aiWait).prefix(5).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 14))
                    }
                    Text("这是模型从这一天的聊天里抽的，不是待办页的权威列表。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }

   }

   private var timelineContent: some View {
       VStack(alignment: .leading, spacing: 16) {
           if let result, !result.topics.isEmpty {
               Text("下面的条数和人数是模型估计，不是逐条统计。")
                   .font(.system(size: 11))
                   .foregroundStyle(.secondary)
               ForEach(Array(result.topics.enumerated()), id: \.offset) { index, topic in
                   HStack(alignment: .top, spacing: 12) {
                       VStack(spacing: 0) {
                           Circle()
                                .strokeBorder(SettingsView.Tab.insight.accentColor, lineWidth: 2)
                                .background(Circle().fill(topic.status.contains("待") ? Color.clear : SettingsView.Tab.insight.accentColor))
                               .frame(width: 12, height: 12)
                           if index < result.topics.count - 1 {
                               Rectangle()
                                    .fill(SettingsView.Tab.insight.accentColor.opacity(0.2))
                                    .frame(width: 2)
                           }
                       }
                        topicCard(topic)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有时间线。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                   HStack(spacing: 12) {
                       Button {
                            runAnalyzeAction()
                       } label: {
                           Label(
                                analyzeActionTitle,
                                systemImage: analyzeActionSymbol
                           )
                       }
                       .buttonStyle(CompanionPressStyle())
                       .foregroundStyle(CompanionPalette.jadeInk)
                        .disabled(isAnalyzing)
                        .help(analyzeActionHint)
                        .accessibilityHint(analyzeActionHint)
                        Button("查看原文") {
                            panelState.showChatDetail(chatUsername: chatUsername, chatName: chatName)
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                    }
                }
            }
        }
    }

    private struct FollowUpItem {
        let title: String
        let owner: String
        let due: String
    }

    private var followUps: [FollowUpItem] {
        ChatReviewFollowUps.items(chatUsername: chatUsername, discussion: monitor.discussionItems)
            .map { FollowUpItem(title: $0.title, owner: $0.owner, due: $0.due) }
    }

    private var livePendingCount: Int {
        monitor.discussionItems.filter {
            $0.chatUsername == chatUsername && $0.status == .pending && !$0.kind.isRecord
        }.count
    }

    // MARK: - Chart Components

    private func hourlyBarChart(_ messagesByHour: [Int]) -> some View {
        let messagesByHour = MessageHelpers.buckets(messagesByHour, count: 24)
        let maxVal = messagesByHour.max() ?? 1
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 2) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(hour >= 9 && hour < 18 ? 0.7 : 0.4))
                        .frame(width: 12, height: maxVal > 0 ? CGFloat(messagesByHour[hour]) / CGFloat(maxVal) * 80 : 0)
                    if hour % 3 == 0 {
                        Text("\(hour)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("")
                            .font(.system(size: 10))
                    }
                }
            }
        }
    }

    private func messageDonut(my: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(my) / Double(total) : 0
        return ZStack {
            Circle().stroke(Color.blue.opacity(0.15), lineWidth: 12)
            Circle().trim(from: 0, to: fraction)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 14, weight: .bold))
                Text("我的消息")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 80, height: 80)
    }

    private func legendRow(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func statsParticipantRow(name: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 26, height: 26)
                Text(String(name.prefix(1)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
            }

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4) {
                GeometryReader { geo in
                    let fraction = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(width: 60, height: 6)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Existing Components

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: WorkspaceType.title, weight: .semibold).monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .companionPanelFace()
    }

    @ViewBuilder
    private func moduleCard(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionPanelFace()
    }

    @ViewBuilder
    private func moduleCardFull(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionPanelFace()
    }

    private func topicCard(_ topic: TopicInsight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(topic.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                statusBadge(topic.status)
            }
            HStack(spacing: 12) {
                Label("约 \(topic.messageCount) 条", systemImage: "bubble.left")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Label("约 \(topic.participantCount) 人", systemImage: "person.2")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(topic.summary)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(3)
            if let involvement = topic.myInvolvement {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text("你：\(involvement)")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }
            // No 「也在：某群」 chip. The single-chat analysis is handed one
            // chat's messages and that chat's own memory — no other chat's name
            // ever reaches it — so anything it listed here was invented or
            // smuggled in from the summary. Still decoded, because older stored
            // insights carry the field.
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func darkSignalRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Small helpers

    private func statusBadge(_ status: String) -> some View {
        let color: Color = status == "已决" ? .green : status == "搁置" ? .gray : .orange
        return Text(status)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private func moodIcon(_ mood: String) -> some View {
        let (icon, color): (String, Color) = {
            if mood.contains("焦虑") || mood.contains("紧张") { return ("exclamationmark.triangle", .red) }
            if mood.contains("轻松") { return ("face.smiling", .green) }
            if mood.contains("正式") { return ("briefcase", .blue) }
            return ("minus.circle", .secondary)
        }()
        return Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundColor(color)
    }

    private func signalBar(_ ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(ratio > 0.6 ? Color.green : Color.orange)
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(width: 80, height: 8)
    }

}
