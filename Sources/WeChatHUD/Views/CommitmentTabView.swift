import SwiftUI
import AppKit

/// 我答应的事 — expand/collapse cards matching 不漏事 figure 03 / 28.
struct CommitmentTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var filter: CommitmentPresentation.Filter = .active
    @State private var query = ""
    @State private var expandedID: Int64?
    @State private var pendingCancel: Commitment?
    @State private var receipt: String?
    @State private var undo: (msgUID: String, status: CommitmentStatus)?
    @State private var actionError: String?

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
                                    .font(.system(size: 12, weight: .semibold))
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
            }
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 28).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(CompanionPalette.canvas)
        .onAppear {
            if expandedID == nil { expandedID = filteredCommitments.first?.id }
        }
        .alert(CompanionProductCopy.cancelCommitmentTitle, isPresented: Binding(
            get: { pendingCancel != nil },
            set: { if !$0 { pendingCancel = nil } }
        )) {
            Button("取消承诺", role: .destructive) {
                if let commitment = pendingCancel {
                    pendingCancel = nil
                    updateStatus(commitment, .cancelled)
                }
            }
            Button("保留", role: .cancel) { pendingCancel = nil }
        } message: {
            Text(CompanionProductCopy.cancelCommitmentMessage)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CompanionFilterPill(title: "进行中 \(activeCount)", selected: filter == .active) { filter = .active }
                CompanionFilterPill(title: "已超期 \(overdueCount)", selected: filter == .overdue) { filter = .overdue }
                CompanionFilterPill(title: "已完成", selected: filter == .fulfilled) { filter = .fulfilled }
                CompanionFilterPill(title: "全部", selected: filter == .all) { filter = .all }
                Spacer()
                if overdueCount > 0 {
                    Button {
                        filter = .overdue
                    } label: {
                        Label("有 \(overdueCount) 项已超期，去查看", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索承诺、原话或对象", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button("清除搜索") { query = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CompanionPalette.jade)
                }
            }
            .padding(10)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CompanionPalette.border))
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            query.isEmpty ? CommitmentPresentation.emptyTitle(for: filter) : "没有匹配的承诺",
            systemImage: query.isEmpty ? emptyIcon : "magnifyingglass",
            description: Text(query.isEmpty ? CommitmentPresentation.emptyDescription(for: filter) : "当前搜索：\(query)")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
        .overlay(alignment: .bottom) {
            if !query.isEmpty {
                Button("清除搜索") { query = "" }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
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

    private func card(_ commitment: Commitment) -> some View {
        let expanded = expandedID == commitment.id
        let isActive = commitment.status == .pending || commitment.status == .overdue
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withMotion(CompanionMotion.rowExpand()) {
                    expandedID = expanded ? nil : commitment.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: commitment.status == .fulfilled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(commitment.status == .fulfilled ? CompanionPalette.jade : .secondary)
                        .frame(width: 22)
                        .accessibilityLabel(commitment.status == .fulfilled ? "已完成" : "未完成")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(CommitmentPresentation.deadlineText(for: commitment))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(commitment.content.isEmpty ? "未命名承诺" : commitment.content)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        Text("答应 \(monitor.commitmentTargetName(commitment.commitTo, chatUsername: commitment.chatUsername))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

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
                            .buttonStyle(.borderedProminent)
                            Button("取消承诺") { pendingCancel = commitment }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("查看对话") {
                                WeChatLauncher.openChat(named: monitor.displayName(for: commitment.chatUsername))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(CompanionPalette.jade)
                        }
                        .controlSize(.regular)
                    } else {
                        Button("恢复进行中") { updateStatus(commitment, .pending) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(expanded ? CompanionPalette.jade.opacity(0.45) : CompanionPalette.border, lineWidth: 1)
        )
        .companionAnimation(CompanionMotion.rowExpand(), value: expanded)
    }

    private func contextBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.primary).textSelection(.enabled)
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
                .foregroundStyle(CompanionPalette.jade)
            Spacer()
            if undo != nil {
                Button("撤销") { undoLast() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.top, 10)
    }

    private func updateStatus(_ commitment: Commitment, _ status: CommitmentStatus) {
        do {
            let previous = commitment.status
            try monitor.updateCommitmentStatus(msgUID: commitment.msgUID, status: status)
            actionError = nil
            if status == .fulfilled {
                undo = (commitment.msgUID, previous)
                receipt = "\(commitment.content)已标记完成"
            } else if status == .cancelled {
                undo = (commitment.msgUID, previous)
                receipt = "已取消承诺"
            } else {
                undo = nil
                receipt = "已恢复为进行中"
            }
        } catch {
            actionError = "状态没有保存，这条承诺还在原来的位置。请重试。"
        }
    }

    private func undoLast() {
        guard let undo else { return }
        do {
            try monitor.updateCommitmentStatus(msgUID: undo.msgUID, status: undo.status)
            self.undo = nil
            receipt = "已撤销"
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
        case overdue = "已超期"
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

    static func deadlineText(for commitment: Commitment, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let date = commitment.deadlineAt {
            return timeLabel(date, now: now, calendar: calendar)
        }
        return visibleDeadlineLabel(commitment.deadlineLabel) ?? "无期限"
    }

    static func emptyTitle(for filter: Filter) -> String {
        switch filter {
        case .active: return "没有进行中的承诺"
        case .overdue: return "没有已超期的承诺"
        case .fulfilled: return "近两周没有已完成的承诺"
        case .all: return "没有正在跟进的承诺"
        }
    }

    static func emptyDescription(for filter: Filter) -> String {
        switch filter {
        case .fulfilled:
            return "更早完成的记录还在本地，不会堆在这一栏。"
        case .all:
            return "更早完成或取消的记录还在本地，不会堆在这一栏。"
        default:
            return "答应过别人的话会留在这里，带着原话和截止时间。"
        }
    }

    static func sectionTitle(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "无期限" }
        if date < now && !calendar.isDate(date, inSameDayAs: now) { return "已过期" }
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
        if title == "已过期" { return 0 }
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
