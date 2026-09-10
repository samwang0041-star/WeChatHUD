import SwiftUI

/// Master-detail task inbox matching 不漏事 figure 02 / 35 / 36 / 28.
struct DiscussionWorkspaceView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @State private var scope: DiscussionScope = .all
    @State private var query = ""
    @State private var showHistory = false
    @State private var selectedID: Int64?
    @State private var showingSource = false
    @State private var correcting: DiscussionItem?
    @State private var error: String?
    @State private var receipt: String?
    @State private var undo: (id: Int64, status: DiscussionItemStatus)?
    @State private var historyItems: [DiscussionItem] = []
    @State private var groupingAnchor = Calendar.current.startOfDay(for: Date())

    private var sourceItems: [DiscussionItem] {
        showHistory ? historyItems : monitor.discussionItems
    }

    private var items: [DiscussionItem] {
        DiscussionPresentation.items(sourceItems, scope: scope, query: query, history: showHistory)
    }

    private var selected: DiscussionItem? {
        items.first(where: { $0.id == selectedID }) ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                HSplitView {
                    listPane.frame(minWidth: 320, idealWidth: 420)
                    detailPane.frame(minWidth: 300, idealWidth: 380)
                }
            }
            if let receipt {
                receiptBar(receipt)
            }
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear {
            applyPendingScope()
            reconcileSelection()
        }
        .onChange(of: monitor.discussionItems) { _, _ in
            reconcileSelection()
        }
        .onChange(of: showHistory) { _, on in
            if on { refreshHistory() }
            reconcileSelection()
        }
        .onChange(of: scope) { _, _ in reconcileSelection() }
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onReceive(panelState.$pendingDiscussionScope) { value in
            if let value { scope = value; showHistory = false; panelState.pendingDiscussionScope = nil }
        }
        .onReceive(panelState.$pendingDiscussionChatUsername) { _ in
            applyPendingScope()
        }
        .companionDialogBackdrop(correcting != nil) {
            if let item = correcting {
                CompanionDialog(title: "更正这件事", onClose: { correcting = nil }) {
                    DiscussionCorrectionForm(item: item) { content, owner, dueAt in
                        do {
                            try monitor.setDiscussionItemCorrection(id: item.id, content: content, owner: owner, dueAt: dueAt)
                            if showHistory { refreshHistory() }
                            error = nil
                            receipt = "修改已保存"
                            correcting = nil
                        } catch {
                            self.error = "更正没有保存，原文待办还在。请重试。"
                        }
                    } onCancel: {
                        correcting = nil
                    }
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(DiscussionScope.allCases) { value in
                    Button {
                        scope = value
                    } label: {
                        Text(value.rawValue)
                            .font(.system(size: 13, weight: scope == value ? .semibold : .regular))
                            .foregroundStyle(scope == value ? Color.white : .primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(scope == value ? CompanionPalette.jade : CompanionPalette.surface, in: Capsule())
                    }
                    .buttonStyle(CompanionPressStyle())
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
                Spacer()
                Toggle("看已完成的", isOn: $showHistory)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索待办或对话", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索待办或对话")
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
            Text("未完成的都会留下。已结束的只留近 \(DiscussionLiveWindow.historyDays) 天。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            query.isEmpty ? "还没有待办" : "没有匹配的待办",
            systemImage: query.isEmpty ? "checklist" : "magnifyingglass",
            description: Text(query.isEmpty
                ? (showHistory ? "近 \(DiscussionLiveWindow.historyDays) 天做完或忽略的事情会留在这里，可以再打开。" : "连上微信并选好对话后，还没做完的事会出现在这里。")
                : "当前搜索：\(query)")
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

    private var listPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(DiscussionPresentation.groups(items, now: groupingAnchor), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.items) { item in
                            listRow(item)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.trailing, 12)
        }
    }

    private func listRow(_ item: DiscussionItem) -> some View {
        Button {
            withMotion(CompanionMotion.rowExpand()) {
                selectedID = item.id
                showingSource = false
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(item.status == .done ? CompanionPalette.jade : .secondary)
                    .frame(width: 22)
                    .accessibilityLabel(item.status == .done ? "已完成" : "未完成")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.content)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text("\(item.chatName) · \(item.owner.workspaceLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(DiscussionPresentation.dueLabel(item.dueAt, now: groupingAnchor))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected?.id == item.id ? CompanionPalette.selectedFill : CompanionPalette.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected?.id == item.id ? CompanionPalette.jade.opacity(0.35) : CompanionPalette.border)
            )
        }
        .buttonStyle(CompanionPressStyle())
        .accessibilityLabel(item.content)
    }

    @ViewBuilder private var detailPane: some View {
        if showingSource, let item = selected {
            DiscussionSourceView(item: item, embedded: true, onClose: { showingSource = false }) {
                correcting = item
            }
        } else if let item = selected {
            taskDetail(item)
        } else {
            ContentUnavailableView("选择一条待办", systemImage: "checklist", description: Text("看清谁来做、截止时间和原文。"))
        }
    }

    private func taskDetail(_ item: DiscussionItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(item.content)
                        .font(.system(size: 22, weight: .bold))
                        .textSelection(.enabled)
                    Spacer()
                    Menu {
                        Button("更正归属") { correcting = item }
                        Button("查看原文") { showingSource = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
                metaRow("归属", systemImage: "person", value: item.owner.workspaceLabel)
                metaRow("截止时间", systemImage: "calendar", value: DiscussionPresentation.absoluteDueLabel(item.dueAt))
                metaRow("来源", systemImage: "bubble.left", value: item.chatName)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Spacer(minLength: 12)
                if item.status == .pending {
                    Button {
                        update(id: item.id, to: .done, previous: item.status, title: item.content)
                    } label: {
                        Text("标记完成")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("恢复为未完成") { update(id: item.id, to: .pending, previous: item.status, title: item.content) }
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 18) {
                    Button { correcting = item } label: {
                        Label("更正归属", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .accessibilityIdentifier("workspace.correctOwnership")
                    Button { showingSource = true } label: {
                        Label("查看原文", systemImage: "doc.text")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(CompanionPalette.jade)
                .font(.system(size: 13, weight: .medium))
                Text("这是助手从聊天里整理的，只改这里不会改微信原文。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(CompanionPalette.canvas)
    }

    private func metaRow(_ title: String, systemImage: String, value: String) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value).font(.system(size: 13, weight: .medium))
            Spacer()
        }
    }

    private func receiptBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.jade)
            Text(text).font(.system(size: 13, weight: .medium))
            Spacer()
            if let undo {
                Button("撤销") { update(id: undo.id, to: undo.status, previous: nil, title: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.jade)
                    .font(.system(size: 13, weight: .semibold))
            }
            Button { receipt = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭回执")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(CompanionPalette.selectedFill, in: Capsule())
        .padding(.vertical, 10)
    }

    private func refreshHistory() {
        historyItems = monitor.loadDiscussionHistory()
    }

    private func reconcileSelection() {
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }

    private func applyPendingScope() {
        if let value = panelState.pendingDiscussionScope {
            scope = value; showHistory = false; panelState.pendingDiscussionScope = nil
        }
        if let chat = panelState.pendingDiscussionChatUsername {
            query = monitor.displayName(for: chat)
            showHistory = false
            if let match = monitor.discussionItems.first(where: { $0.chatUsername == chat && $0.status == .pending }) {
                selectedID = match.id
            }
            panelState.pendingDiscussionChatUsername = nil
        }
    }

    private func update(id: Int64, to status: DiscussionItemStatus, previous: DiscussionItemStatus?, title: String?) {
        do {
            try monitor.setDiscussionItemStatus(id: id, status: status)
            if showHistory { refreshHistory() }
            error = nil
            undo = previous.map { (id, $0) }
            if status == .done, let title {
                receipt = "\(title)已标记完成"
            } else if previous != nil {
                receipt = "事项状态已保存"
            } else {
                receipt = nil
            }
        } catch {
            self.error = "保存失败，事项状态未更改。请重试。"
            receipt = nil
        }
    }
}

struct DiscussionCorrectionForm: View {
    let item: DiscussionItem
    let onSave: (String, DiscussionItemOwner, Date?) -> Void
    let onCancel: () -> Void
    @State private var content: String
    @State private var owner: DiscussionItemOwner
    @State private var dueAt: Date
    @State private var hasDue: Bool
    @FocusState private var contentFocused: Bool

    init(item: DiscussionItem, onSave: @escaping (String, DiscussionItemOwner, Date?) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.onSave = onSave
        self.onCancel = onCancel
        _content = State(initialValue: item.content)
        _owner = State(initialValue: item.owner)
        _dueAt = State(initialValue: item.dueAt ?? Date().addingTimeInterval(3600))
        _hasDue = State(initialValue: item.dueAt != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("内容").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("待办内容", text: $content)
                    .textFieldStyle(.roundedBorder)
                    .focused($contentFocused)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("谁来做").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("谁来做", selection: $owner) {
                    Text(DiscussionItemOwner.mine.workspaceLabel).tag(DiscussionItemOwner.mine)
                    Text(DiscussionItemOwner.theirs.workspaceLabel).tag(DiscussionItemOwner.theirs)
                    Text(DiscussionItemOwner.shared.workspaceLabel).tag(DiscussionItemOwner.shared)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("有截止时间", isOn: $hasDue)
                if hasDue {
                    DatePicker("截止时间", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                }
            }
            if let detail = item.detail, !detail.isEmpty {
                Text("来源：\(detail)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
            }
            Label("只修改助手里的待办，不会修改聊天原文。", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存更正") {
                    onSave(content.trimmingCharacters(in: .whitespacesAndNewlines), owner, hasDue ? dueAt : nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(CompanionPalette.jade)
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .companionAnimation(CompanionMotion.dialog(), value: hasDue)
        .onAppear { contentFocused = true }
    }
}

enum DiscussionScope: String, CaseIterable, Identifiable {
    case all = "全部", mine = "我要做", theirs = "等对方", shared = "共同推进", notes = "信息备忘"
    var id: String { rawValue }
}

/// Pending-only live list. Completing a row drops it; restoring patches it back.
enum DiscussionLiveList {
    static func applying(_ items: [DiscussionItem], replacement: DiscussionItem) -> [DiscussionItem] {
        if replacement.status == .pending {
            if let index = items.firstIndex(where: { $0.id == replacement.id }) {
                var next = items
                next[index] = replacement
                return next
            }
            return [replacement] + items
        }
        return items.filter { $0.id != replacement.id }
    }
}

enum DiscussionPresentation {
    struct Group {
        let title: String
        let items: [DiscussionItem]
    }

    static func items(_ items: [DiscussionItem], scope: DiscussionScope, query: String, history: Bool) -> [DiscussionItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard history ? item.status != .pending : item.status == .pending else { return false }
            let matches: Bool
            switch scope {
            case .all: matches = true
            case .notes: matches = item.kind == .info
            case .mine: matches = item.owner == .mine && item.kind != .info
            case .theirs: matches = item.owner == .theirs && item.kind != .info
            case .shared: matches = item.owner == .shared && item.kind != .info
            }
            return matches && (query.isEmpty || [item.content, item.detail ?? "", item.chatName].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            if history { return $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id > $1.id }
            let lhs = $0.dueAt ?? .distantFuture, rhs = $1.dueAt ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            return $0.sourceTimestamp != $1.sourceTimestamp ? $0.sourceTimestamp > $1.sourceTimestamp : $0.id > $1.id
        }
    }

    static func groups(_ items: [DiscussionItem], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let order = ["已过期", "今天", "明天", "本周", "之后", "无期限"]
        let mapped = Dictionary(grouping: items) { groupTitle(for: $0.dueAt, now: now, calendar: calendar) }
        return order.compactMap { title in
            mapped[title].map { Group(title: title, items: $0) }
        }
    }

    static func dueLabel(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "无期限" }
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 " + date.formatted(date: .omitted, time: .shortened)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func absoluteDueLabel(_ date: Date?) -> String {
        guard let date else { return "没有截止时间" }
        return date.formatted(date: .complete, time: .shortened)
    }

    private static func groupTitle(for date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "无期限" }
        if date < now && !calendar.isDate(date, inSameDayAs: now) { return "已过期" }
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "本周" }
        return "之后"
    }
}

/// 聊天回顾「仍需跟进」只读同一份待办，完成/撤销后各页一致。
enum ChatReviewFollowUps {
    struct Item: Equatable {
        let title: String
        let owner: String
        let due: String
        let chatUsername: String
    }

    static func items(chatUsername: String, discussion: [DiscussionItem]) -> [Item] {
        discussion
            .filter { $0.chatUsername == chatUsername && $0.status == .pending && $0.kind != .info }
            .prefix(3)
            .map {
                Item(
                    title: $0.content,
                    owner: $0.owner.workspaceLabel,
                    due: DiscussionPresentation.absoluteDueLabel($0.dueAt),
                    chatUsername: $0.chatUsername
                )
            }
    }
}
