import SwiftUI
import AppKit

/// 我答应的事 — expand/collapse cards matching 不漏事 figure 03 / 28.
struct CommitmentTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var filter: CommitmentPresentation.Filter = .active
    @State private var query = ""
    @State private var expandedID: Int64?
    @State private var pendingCancel: Commitment?
    @State private var showBatchClearConfirm = PreviewRuntime.parksBatchClearDialog
    @State private var batchUndo: [(msgUID: String, status: CommitmentStatus)]?
    @State private var isBatchClearing = false
    @State private var receipt: String?
    @State private var isCancelling = false
    @State private var undo: (msgUID: String, status: CommitmentStatus)?
    @State private var actionError: String?
    @FocusState private var searchFocused: Bool
    @State private var isUndoing = false

    private var activeCount: Int { CommitmentPresentation.activeCount(monitor.commitments) }
    private var overdueCount: Int { CommitmentPresentation.overdueCount(monitor.commitments) }

    private var filteredCommitments: [Commitment] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitor.commitments
            .filter { CommitmentPresentation.matches($0, filter: filter) }
            .filter { commitment in
                guard !normalizedQuery.isEmpty else { return true }
                return [
                    commitment.content,
                    commitment.chatName,
                    commitment.commitTo,
                    commitment.sourceText,
                    commitment.contextText,
                    commitment.captureReason,
                    commitment.nextStep
                ].contains { $0.lowercased().contains(normalizedQuery) }
            }
            .sorted(by: commitmentSort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters
            Divider()
            if filteredCommitments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(CommitmentPresentation.groups(filteredCommitments), id: \.title) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .companionFont(size: 12, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                ForEach(group.items) { commitment in
                                    card(commitment)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            if let receipt {
                receiptBar(receipt)
                    .transition(.companionStatusReveal)
            }
        }
        .workspacePage(WorkspacePage.wideWidth)
        .background(CompanionPalette.canvas)
        .companionAnimation(CompanionMotion.ease(), value: receipt)
        .onAppear {
            if expandedID == nil { expandedID = filteredCommitments.first?.id }
        }
        .companionDialogBackdrop(showBatchClearConfirm || pendingCancel != nil) {
            if showBatchClearConfirm {
                CompanionDialog(title: "一键清空当前承诺？", onClose: { if !isBatchClearing { showBatchClearConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("将当前显示的 \(filteredCommitments.count) 项承诺标记为已完成。14 天内可在「已完成」列表中查看和撤销。")
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let actionError {
                            Text(actionError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { showBatchClearConfirm = false }
                                .companionBusyHold(isBatchClearing, "正在把当前承诺标为已完成")
                            Button {
                                guard !isBatchClearing else { return }
                                isBatchClearing = true
                                Task { @MainActor in
                                    let ok = batchClear()
                                    isBatchClearing = false
                                    if ok { showBatchClearConfirm = false }
                                }
                            } label: {
                                Text(isBatchClearing ? "正在清空承诺…" : "全部完成")
                            }
                            .tint(SettingsView.Tab.commitments.accentColor)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBatchClearing)
                            .help(isBatchClearing ? "正在把当前承诺标为已完成" : "")
                            .accessibilityHint(isBatchClearing ? "正在把当前承诺标为已完成" : "")
                        }
                    }
                }
            } else if let commitment = pendingCancel {
                CompanionDialog(title: CompanionProductCopy.cancelCommitmentTitle, onClose: { if !isCancelling { pendingCancel = nil } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.cancelCommitmentMessage)
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let actionError {
                            Text(actionError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("保留") { pendingCancel = nil }
                                .companionBusyHold(isCancelling, "正在取消这条承诺")
                            Button(role: .destructive) {
                                guard !isCancelling else { return }
                                isCancelling = true
                                Task { @MainActor in
                                    let ok = updateStatus(commitment, .cancelled)
                                    isCancelling = false
                                    if ok { pendingCancel = nil }
                                }
                            } label: {
                                Text(isCancelling ? "正在取消承诺…" : "取消承诺")
                            }
                            .disabled(isCancelling)
                            .help(isCancelling ? "正在取消这条承诺" : "")
                            .accessibilityHint(isCancelling ? "正在取消这条承诺" : "")
                        }
                    }
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            // This page is not governed by 待办's strictness level, and saying
            // so here is the point: a promise the user made is already the
            // narrowest category there is (extraction applies a 0.72 gate and
            // only keeps explicit commitments). Without this line the two
            // pages look like they disagree about what was promised.
            Text("这里只记你明确答应过的事；14 天内创建、到期或动过的都会显示。")
                .companionFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                CompanionFilterPill(title: "进行中 \(activeCount)", selected: filter == .active, tint: SettingsView.Tab.commitments.accentColor) { filter = .active }
                // The overdue notice used to be a second control in this same
                // row — 「有 1 项到期了，去查看」, whose action was literally
                // `filter = .overdue`, the same thing the pill two slots to its
                // left already did. One control now: the pill carries the count
                // and turns amber when there is something overdue.
                CompanionFilterPill(title: "已到期 \(overdueCount)", selected: filter == .overdue,
                                    tint: overdueCount > 0 ? .orange : SettingsView.Tab.commitments.accentColor) { filter = .overdue }
                CompanionFilterPill(title: "已完成", selected: filter == .fulfilled, tint: SettingsView.Tab.commitments.accentColor) { filter = .fulfilled }
                CompanionFilterPill(title: "全部", selected: filter == .all, tint: SettingsView.Tab.commitments.accentColor) { filter = .all }
                Spacer()
                if (filter == .active || filter == .overdue) && !filteredCommitments.isEmpty {
                    CompanionBatchClearButton(help: "将当前承诺全部标记为已完成") {
                        showBatchClearConfirm = true
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索承诺、原话或对象", text: $query).textFieldStyle(.plain)
                    // The prompt alone is not a spoken name: the live AX tree
                    // reported this field as `AXTextField` with an empty label,
                    // while the identically-built fields on 待办 and 草稿 read
                    // their titles out. VoiceOver users got an unnamed box.
                    .focused($searchFocused)
                    .accessibilityLabel("搜索承诺、原话或对象")
                if !query.isEmpty {
                    Button("清除搜索") { query = "" }
                        .buttonStyle(CompanionPressStyle())
                        .companionFont(size: 12, weight: .medium)
                        .foregroundStyle(CompanionPalette.jadeInk)
                }
            }
            .padding(10)
            // The field's AX face is its 16pt text line; the well is the
            // target instead (same rule as 今天's search).
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).companionHairline())
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .transition(.companionStatusReveal)
            }
        }
        .padding(.bottom, 12)
        .companionAnimation(CompanionMotion.ease(), value: actionError)
    }

   private var emptyState: some View {
       ContentUnavailableView(
            emptyTitle,
           systemImage: query.isEmpty ? emptyIcon : "magnifyingglass",
            description: Text(emptyDetail)
       )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !query.isEmpty {
                Button("清除搜索") { query = "" }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
            } else if filter != .all, !monitor.commitments.isEmpty {
                Button("看全部") {
                    withMotion(CompanionMotion.pageChange()) { filter = .all }
                }
                .buttonStyle(CompanionPressStyle())
                .companionFont(size: 13, weight: .medium)
                .foregroundStyle(CompanionPalette.jadeInk)
                .padding(.bottom, 24)
                .accessibilityLabel("看全部承诺")
            }
            else if monitor.commitments.isEmpty {
                if monitor.stats.lastSyncAt == nil {
                    Button("检查连接") {
                        NotificationCenter.default.post(name: .hudSwitchTab, object: "system")
                    }
                    .buttonStyle(CompanionPressStyle())
                    .companionFont(size: 13, weight: .medium)
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .padding(.bottom, 24)
                    .accessibilityLabel("检查微信连接")
                } else if !monitor.store.hasWhitelistEntries() {
                    Button("关注谁") {
                        NotificationCenter.default.post(name: .hudSwitchTab, object: "contacts")
                    }
                    .buttonStyle(CompanionPressStyle())
                    .companionFont(size: 13, weight: .medium)
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .padding(.bottom, 24)
                    .accessibilityLabel("去选要关注的对话")
                } else {
                    Button("打开今天") {
                        NotificationCenter.default.post(name: .hudSwitchTab, object: "today")
                    }
                    .buttonStyle(CompanionPressStyle())
                    .companionFont(size: 13, weight: .medium)
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .padding(.bottom, 24)
                    .accessibilityLabel("打开今天，从对话里记下承诺")
                }
            }
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .active: return "checkmark.seal"
        case .overdue: return "clock.badge.exclamationmark"
       case .fulfilled, .all: return "tray"
       }
   }

    private var emptyTitle: String {
        if !query.isEmpty { return "没有匹配的承诺" }
        if monitor.commitments.isEmpty { return "还没有记下的承诺" }
        return CommitmentPresentation.emptyTitle(for: filter)
    }

    private var emptyDetail: String {
        if !query.isEmpty { return "当前搜索：\(query)" }
        if monitor.commitments.isEmpty {
            if monitor.stats.lastSyncAt == nil { return "连上微信后，答应过别人的话会出现在这里。" }
            if !monitor.store.hasWhitelistEntries() { return "先选要关注的对话，答应过别人的话会出现在这里。" }
            return "关注的对话里还没有记下的承诺。今天里答应过的话会出现在这里。"
        }
        return CommitmentPresentation.emptyDescription(for: filter)
    }


   private func card(_ commitment: Commitment) -> some View {
        let expanded = expandedID == commitment.id
        let isActive = commitment.status == .pending || commitment.status == .overdue
        // The group header says 已到期 once at the top of a section; scroll past
        // it and the row is the only thing left. The deadline is what slipped, so
        // it is the thing that carries the warning colour.
        let isLate = isActive && CommitmentPresentation.isOverdue(commitment)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withMotion(CompanionMotion.rowExpand()) {
                    expandedID = expanded ? nil : commitment.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: commitment.status == .fulfilled ? "checkmark.circle.fill" : "circle")
                        .companionFont(size: WorkspaceType.title, weight: .medium)
                        .foregroundStyle(commitment.status == .fulfilled ? CompanionPalette.jadeInk : .secondary)
                        .frame(width: 22)
                        .accessibilityLabel(commitment.status == .fulfilled ? "已完成" : "未完成")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(CommitmentPresentation.deadlineText(for: commitment))
                                .companionFont(size: 12, weight: .semibold)
                                .foregroundStyle(isLate ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            Text(commitment.content.isEmpty ? "未命名承诺" : commitment.content)
                                .companionFont(size: 15, weight: .semibold)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        Text("答应 \(monitor.commitmentTargetName(commitment.commitTo, chatUsername: commitment.chatUsername))")
                            .companionFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .companionFont(size: 10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(CompanionRowPressStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    contextBlock("原话", commitment.sourceText.isEmpty ? "这条记录缺少当时原话。" : "“\(commitment.sourceText)”")
                    HStack(alignment: .top, spacing: 16) {
                        contextBlock("来源", sourceLine(commitment))
                        if !bestNextStep(commitment).isEmpty {
                            contextBlock("下一步", bestNextStep(commitment))
                        }
                    }
                    if isActive {
                        HStack(spacing: 8) {
                           Button {
                               updateStatus(commitment, .fulfilled)
                           } label: {
                               Text("标记完成")
                           }
                           .tint(SettingsView.Tab.commitments.accentColor)
                           .buttonStyle(.borderedProminent)
                           Button("取消承诺") { pendingCancel = commitment }
                               .buttonStyle(.bordered)
                            Spacer()
                            Button("查看对话") {
                                monitor.openWeChatChat(commitment.chatUsername)
                            }
                            .buttonStyle(CompanionPressStyle())
                            .foregroundStyle(CompanionPalette.jadeInk)
                        }
                        .controlSize(.regular)
                    } else {
                        Button("恢复进行中") { updateStatus(commitment, .pending) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.companionStatusReveal)
            }
        }
        .padding(16)
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(edgeColor(expanded: expanded, late: isLate), lineWidth: CompanionAccessibility.cardEdgeWidth)
        )
        .companionAnimation(CompanionMotion.rowExpand(), value: expanded)
    }

    /// A jade ring around a promise that has already slipped reads as "done",
    /// which is the opposite of why the card is open.
    private func edgeColor(expanded: Bool, late: Bool) -> Color {
        guard expanded else { return CompanionPalette.border }
        return (late ? Color.orange : CompanionPalette.jade).opacity(0.45)
    }

    private func contextBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).companionFont(size: 11, weight: .semibold).foregroundStyle(.secondary)
            Text(text).companionFont(size: 13).foregroundStyle(.primary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLine(_ commitment: Commitment) -> String {
        let name = commitment.chatName.isEmpty ? monitor.displayName(for: commitment.chatUsername) : commitment.chatName
        let when = commitment.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(when)  ·  \(name)"
    }

    private func bestNextStep(_ commitment: Commitment) -> String {
        if !commitment.nextStep.isEmpty { return commitment.nextStep }
        if !commitment.content.isEmpty { return "推进：\(commitment.content)" }
        return ""
    }

    private func receiptBar(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(CompanionPalette.jadeInk)
            Spacer()
            if undo != nil {
                Button {
                    commitUndo { undoLast() }
                } label: {
                    Text(isUndoing ? "正在撤销…" : "撤销")
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUndoing)
                    .help(isUndoing ? "正在撤销刚才的操作" : "")
                    .accessibilityHint(isUndoing ? "正在撤销刚才的操作" : "")
            } else if let previous = batchUndo {
                Button {
                    commitUndo { undoBatch(previous) }
                } label: {
                    Text(isUndoing ? "正在撤销…" : "撤销")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isUndoing)
                .help(isUndoing ? "正在撤销刚才的操作" : "")
                .accessibilityHint(isUndoing ? "正在撤销刚才的操作" : "")
            }
        }
        .companionFont(size: 13, weight: .medium)
        .padding(.top, 10)
    }

    @discardableResult
    private func updateStatus(_ commitment: Commitment, _ status: CommitmentStatus) -> Bool {
        do {
            let previous = commitment.status
            try monitor.updateCommitmentStatus(msgUID: commitment.msgUID, status: status)
            actionError = nil
            if status == .fulfilled {
                undo = (commitment.msgUID, previous)
                batchUndo = nil
                receipt = "\(commitment.content)已标记完成"
                CompanionMotion.performCommitTick()
            } else if status == .cancelled {
                undo = (commitment.msgUID, previous)
                batchUndo = nil
                receipt = "已取消承诺"
            } else {
                undo = nil
                receipt = "已恢复为进行中"
            }
            return true
        } catch {
            actionError = "状态没有保存，这条承诺还在原来的位置。请重试。"
            return false
        }
    }

    @discardableResult
    private func batchClear() -> Bool {
        let targets = filteredCommitments
        guard !targets.isEmpty else { return false }
        batchUndo = targets.map { ($0.msgUID, $0.status) }
        undo = nil
        do {
            try monitor.batchUpdateCommitmentsStatus(commitments: targets, status: .fulfilled)
            receipt = "已清空 \(targets.count) 项承诺"
            actionError = nil
            CompanionMotion.performCommitTick()
            return true
        } catch {
            actionError = "清空失败，请重试。"
            return false
        }
    }

    private func undoLast() {
        guard let undo else { return }
        do {
            try monitor.updateCommitmentStatus(msgUID: undo.msgUID, status: undo.status)
            self.undo = nil
            receipt = "已撤销"
            actionError = nil
            CompanionMotion.performCommitTick()
        } catch {
            actionError = "撤销没有成功，请重试。"
        }
    }

    private func commitUndo(_ work: @escaping () -> Void) {
        guard !isUndoing else { return }
        isUndoing = true
        Task { @MainActor in
            defer { isUndoing = false }
            work()
        }
    }

    private func undoBatch(_ previous: [(msgUID: String, status: CommitmentStatus)]) {
        do {
            for item in previous {
                try monitor.updateCommitmentStatus(msgUID: item.msgUID, status: item.status)
            }
            batchUndo = nil
            receipt = nil
            actionError = nil
        } catch {
            actionError = "撤销没有成功，请重试。"
        }
    }

    private func commitmentSort(_ lhs: Commitment, _ rhs: Commitment) -> Bool {
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank { return leftRank < rightRank }
        let leftDeadline = lhs.deadlineAt ?? Date.distantFuture
        let rightDeadline = rhs.deadlineAt ?? Date.distantFuture
        if leftDeadline != rightDeadline { return leftDeadline < rightDeadline }
        return lhs.createdAt > rhs.createdAt
    }

    private func statusRank(_ status: CommitmentStatus) -> Int {
        switch status {
        case .overdue:   return 0
        case .pending:   return 1
        case .fulfilled: return 2
        case .cancelled: return 3
        }
    }
}

enum CommitmentPresentation {
    struct Group {
        let title: String
        let items: [Commitment]
    }

    enum Filter: String, CaseIterable {
        case active = "进行中"
        case overdue = "已到期"
        case fulfilled = "已完成"
        case all = "全部"
    }

    static func groups(_ items: [Commitment], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let mapped = Dictionary(grouping: items) { sectionTitle(for: $0, now: now, calendar: calendar) }
        let titles = mapped.keys.sorted { lhs, rhs in
            sectionRank(lhs) < sectionRank(rhs)
        }
        return titles.compactMap { title in
            mapped[title].map { Group(title: title, items: $0) }
        }
    }

    static func matches(_ commitment: Commitment, filter: Filter, now: Date = Date()) -> Bool {
        switch filter {
        case .active:
            return commitment.status == .pending || commitment.status == .overdue
        case .overdue:
            return isOverdue(commitment, now: now)
        case .fulfilled:
            return commitment.status == .fulfilled
        case .all:
            return true
        }
    }

    static func activeCount(_ items: [Commitment]) -> Int {
        items.filter { matches($0, filter: .active) }.count
    }

    static func overdueCount(_ items: [Commitment], now: Date = Date()) -> Int {
        items.filter { matches($0, filter: .overdue, now: now) }.count
    }

    static func isOverdue(_ commitment: Commitment, now: Date = Date()) -> Bool {
        if commitment.status == .overdue { return true }
        guard commitment.status == .pending, let deadline = commitment.deadlineAt else { return false }
        return deadline < now
    }

    static func timeLabel(_ date: Date?) -> String {
        guard let date else { return "无期限" }
        return timeLabel(date, now: Date(), calendar: .current)
    }

    static func timeLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    /// A deadline with its tense already decided: past reads 已到期, future
    /// reads 截止 <absolute time>.
    ///
    /// `MessageInfo.formatRelative` must never be handed a deadline — it is
    /// past-only, and a negative diff falls straight through to 刚刚, so every
    /// future date rendered as 截止 刚刚.
    static func deadlineCaption(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        date < now ? "已到期" : "截止 \(timeLabel(date, now: now, calendar: calendar))"
    }

    static func deadlineText(for commitment: Commitment, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let date = commitment.deadlineAt {
            return timeLabel(date, now: now, calendar: calendar)
        }
        return visibleDeadlineLabel(commitment.deadlineLabel) ?? "无期限"
    }

    static func emptyTitle(for filter: Filter) -> String {
        switch filter {
        case .active: return "没有进行中的承诺"
        case .overdue: return "没有已到期的承诺"
        case .fulfilled: return "近两周没有已完成的承诺"
        case .all: return "还没有记下的承诺"
        }
    }

    static func emptyDescription(for filter: Filter) -> String {
        switch filter {
       case .fulfilled:
           return "更早完成的记录还在本地，不会堆在这一栏。"
       case .all:
            return "答应过别人的话会留在这里，带着原话和截止时间。"
       default:
           return "答应过别人的话会留在这里，带着原话和截止时间。"
        }
    }

    static func sectionTitle(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "无期限" }
        if date < now && !calendar.isDate(date, inSameDayAs: now) { return "已到期" }
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 " + date.formatted(.dateTime.month().day().weekday(.wide))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return "之后"
    }

    static func sectionTitle(for commitment: Commitment, now: Date = Date(), calendar: Calendar = .current) -> String {
        if commitment.status == .cancelled { return "已取消" }
        return sectionTitle(for: commitment.deadlineAt, now: now, calendar: calendar)
    }

    private static func sectionRank(_ title: String) -> Int {
        if title == "已到期" { return 0 }
        if title.hasPrefix("今天") { return 1 }
        if title == "明天" { return 2 }
        if title == "之后" { return 4 }
        if title == "无期限" { return 5 }
        if title == "已取消" { return 6 }
        return 3
    }

    private static func visibleDeadlineLabel(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["", "none", "vague_soon", "inherit", "无期限"]
        if placeholders.contains(label.lowercased()) { return nil }
        return label
    }
}
