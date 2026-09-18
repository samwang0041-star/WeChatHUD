import SwiftUI

/// Master-detail task inbox matching 不漏事 figure 02 / 35 / 36 / 28.
struct DiscussionWorkspaceView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @State private var scope: DiscussionScope = .mine
    @State private var query = ""
    @State private var showHistory = false
    @State private var selectedID: Int64?
    @State private var showingSource = false
    @State private var correcting: DiscussionItem?
    @State private var error: String?
    @State private var receipt: String?
    @State private var undo: (id: Int64, status: DiscussionItemStatus)?
    @State private var batchUndo: [(id: Int64, status: DiscussionItemStatus)]?
    @State private var showBatchClearConfirm = false
    @State private var historyItems: [DiscussionItem] = []
    @State private var groupingAnchor = Calendar.current.startOfDay(for: Date())
    @State private var expandArchived = false
    /// How much of the extracted material counts as work here. Read from the
    /// monitor so the sidebar badge, 今天 and the daily report all agree.
    private var strictness: DiscussionStrictness { monitor.discussionStrictness }
    /// Keeps the filter+sort to one pass per changed input instead of one pass
    /// per read. See `DiscussionItemsCache`.
    @State private var itemsCache = DiscussionItemsCache()

    private var sourceItems: [DiscussionItem] {
        // History is a review of what was handled, so it is never narrowed by
        // the level — hiding completed work would make the level look like it
        // deleted things. The level applies to the live list only.
        // The memo tab is the home for records: it always shows them regardless
        // of level. Filtering first would leave a held-back record with no tab
        // that can ever show it — invisible at every level while still counted
        // as "held back". The level narrows the work tabs only.
        if showHistory { return historyItems }
        if scope == .notes { return monitor.discussionItems }
        return monitor.discussionItems.filter { strictness.admits($0) }
    }

    /// Resolved once per body evaluation. Never read this from a row: rows
    /// receive the resolved value, otherwise every row re-sorts the corpus.
    private var items: [DiscussionItem] {
        itemsCache.items(sourceItems, scope: scope, query: query, history: showHistory)
    }

    private func selection(in items: [DiscussionItem]) -> DiscussionItem? {
        items.first(where: { $0.id == selectedID }) ?? items.first
    }

    /// The strictness control plus its receipt.
    ///
    /// A level that silently removes rows is indistinguishable from one that
    /// ate them, so the bar always says how many it is holding back — and how
    /// many of those are work assigned to the user, which is the number that
    /// makes the trade visible.
    private var strictnessBar: some View {
        let hidden = strictness.hidden(from: monitor.discussionItems)
        // "Work of mine" must mean work, not every record that happens to carry
        // my owner. Counting records here overstated the cost of a tighter
        // level by more than an order of magnitude (28 claimed vs 1 real).
        let hiddenMine = hidden.filter { $0.owner == .mine && !$0.kind.isRecord }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("保留")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("保留", selection: strictnessBinding) {
                    ForEach(DiscussionStrictness.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("保留哪些内容")
                Spacer(minLength: 8)
                if !hidden.isEmpty {
                    Button {
                        // Reveal by widening, not by a separate "show hidden"
                        // mode: one mechanism, and it cannot disagree with the
                        // picker.
                        monitor.setDiscussionStrictness(.everything)
                    } label: {
                        Text(receiptLabel(hidden: hidden.count, mine: hiddenMine))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .accessibilityHint("切到「全记」，这些内容会回到列表里")
                }
            }
            Text(strictness.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var strictnessBinding: Binding<DiscussionStrictness> {
        Binding(
            get: { strictness },
            set: { monitor.setDiscussionStrictness($0) }
        )
    }

    /// The scope filters — the shared pill, in the one workspace accent.
    private var scopePills: some View {
        // The HStack is part of the token, not the caller: dropping a bare
        // `ForEach` into a `VStack` (as the two-line fallback below does) stacks
        // the pills one per line instead of keeping them in a row.
        HStack(spacing: 8) {
            ForEach(DiscussionScope.allCases) { value in
                CompanionFilterPill(
                    title: value.rawValue,
                    selected: scope == value,
                    tint: SettingsView.Tab.tasks.accentColor
                ) { scope = value }
            }
        }
    }

    /// The row's trailing controls: batch clear, and the handled-history
    /// switch.
    private var scopeActions: some View {
        HStack(spacing: 8) {
            if !showHistory && !items.isEmpty {
                CompanionBatchClearButton(help: "将当前列表的所有待办全部标记为完成") {
                    showBatchClearConfirm = true
                }
            }
            Toggle("看已处理的", isOn: $showHistory)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                // SwiftUI drew the title as a sibling static text and left the
                // switch itself unnamed: the live AX tree reported an
                // `AXCheckBox` with an empty label next to the words 看已处理的.
                // VoiceOver announced a bare checkbox with no idea what it
                // toggles.
                .accessibilityLabel("看已处理的")
        }
    }

    /// "已收起 N 条（其中 M 条是我要做的） · 展开".
    ///
    /// Built as one string so the view body stays cheap to type-check, and so
    /// a test can pin the exact wording the user is asked to trust.
    static func receiptLabel(hidden: Int, mine: Int) -> String {
        let minePart = mine > 0 ? "（其中 \(mine) 条是我要做的）" : ""
        return "已收起 \(hidden) 条\(minePart) · 展开"
    }

    private func receiptLabel(hidden: Int, mine: Int) -> String {
        Self.receiptLabel(hidden: hidden, mine: mine)
    }

    var body: some View {
        // Resolve the list and the selection exactly once, then hand the values
        // down. Reading these from deeper views re-runs the whole filter+sort.
        let items = self.items
        let selected = selection(in: items)

        VStack(spacing: 0) {
            filters
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                HSplitView {
                    listPane(items: items, selectedID: selected?.id)
                        .frame(minWidth: 240, idealWidth: 420)
                    detailPane(selected: selected)
                        .frame(minWidth: 240, idealWidth: 380)
                }
            }
            if let receipt {
                receiptBar(receipt)
            }
        }
        .workspacePage(WorkspacePage.wideWidth)
        .background(CompanionPalette.canvas)
        .onAppear {
            applyPendingScope()
            reconcileSelection(in: items)
        }
        .onChange(of: monitor.discussionItems) { _, _ in
            reconcileSelection(in: self.items)
        }
        .onChange(of: showHistory) { _, on in
            if on { refreshHistory() }
            if !on { expandArchived = false }
            reconcileSelection(in: self.items)
        }
        .onChange(of: scope) { _, _ in reconcileSelection(in: self.items) }
        .onChange(of: query) { _, _ in reconcileSelection(in: self.items) }
        .onReceive(panelState.$pendingDiscussionScope) { value in
            if let value { scope = value; showHistory = false; panelState.pendingDiscussionScope = nil }
        }
        .onReceive(panelState.$pendingDiscussionChatUsername) { _ in
            applyPendingScope()
        }
        .companionDialogBackdrop(correcting != nil || showBatchClearConfirm) {
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
            } else if showBatchClearConfirm {
                CompanionDialog(title: "一键清空当前待办？", onClose: { showBatchClearConfirm = false }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("将当前列表中的 \(items.count) 件待办全部标记为完成。可在「看已处理的」中随时查看或恢复。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("取消") { showBatchClearConfirm = false }
                            Button("全部完成") {
                                showBatchClearConfirm = false
                                batchClear(items: items)
                            }
                            .tint(SettingsView.Tab.tasks.accentColor)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            strictnessBar
            // One row while the row has room, two when it does not.
            //
            // Measured: at the workspace's own 900pt minimum the pill row ran
            // out of width. The first symptom was SwiftUI wrapping 「我要做」
            // *inside* its capsule; adding `lineLimit(1)` only traded that for
            // truncated pills (「我…」「共同…」), which is barely better — the
            // filter is unreadable either way. `ViewThatFits` picks the
            // arrangement instead: filters on the first line and the two
            // trailing controls right-aligned on a second, so every label stays
            // whole. The trailing group moves, not the words.
            //
            // It also removes the crash the first attempt produced: with the
            // row forced onto a single line and the pill label marked
            // `fixedSize`, the constraint conflict threw inside AppKit's layout
            // pass and killed the page at launch (see
            // WorkspacePageLaunchSurvivalTests).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    scopePills
                    Spacer(minLength: 8)
                    scopeActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    scopePills
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        scopeActions
                    }
                }
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
                        .foregroundStyle(CompanionPalette.jadeInk)
                }
            }
            .padding(10)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).companionHairline())
            Text(showHistory
                 ? "完成或忽略的只留近 \(DiscussionLiveWindow.historyDays) 天。「较早收起」是很久没处理的，不是你标完成的。"
                 : "当前只显示还没做完的。很久没处理的会收起，不占这个列表。")
                .font(.system(size: 11))
                // `.secondary`, not `.tertiary`.
                //
                // This is a sentence the user has to read to understand what the
                // list is showing, not decoration. Measured on the shipped build:
                // tertiary is #565656 on #1E1E1E = **2.27:1**, against the 4.5:1
                // AA floor, while the same page's secondary measures 5.9–12.3:1.
                // `.tertiary` stays correct for the chevrons and the ⌘F hint,
                // which are affordances rather than prose.
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        // An empty list has three different meanings and they must not look
        // alike: nothing to do, nothing matched the search, or the current
        // level is holding material back. The third case is the dangerous one
        // — it looks identical to "nothing to do" unless we say otherwise.
        let hiddenHere = strictness.hidden(from: monitor.discussionItems)
        // The memo tab bypasses the level (see sourceItems), so the level can
        // never be the reason it looks empty.
        let heldBackByLevel = !showHistory && query.isEmpty && scope != .notes && !hiddenHere.isEmpty
        return ContentUnavailableView(
            query.isEmpty ? "还没有待办" : "没有匹配的待办",
            systemImage: query.isEmpty ? "checklist" : "magnifyingglass",
            description: Text(query.isEmpty
                ? (showHistory
                    ? "近 \(DiscussionLiveWindow.historyDays) 天你完成或忽略的事会留在这里。很久没处理、自动收起的在「较早收起」里。"
                    : (heldBackByLevel
                        ? "当前是「\(strictness.label)」，收起了 \(hiddenHere.count) 条。切到「全记」能看到它们。"
                        : "连上微信并选好对话后，还没做完的事会出现在这里。"))
                : "当前搜索：\(query)")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !query.isEmpty {
                Button("清除搜索") { query = "" }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
            }
        }
    }

    private func listPane(items: [DiscussionItem], selectedID: Int64?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(DiscussionPresentation.groups(items, now: Date(), history: showHistory), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if group.title == DiscussionPresentation.archivedGroupTitle, !expandArchived {
                            Button {
                                expandArchived = true
                            } label: {
                                Text("\(group.items.count) 件很久没处理，点开查看")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(CompanionPalette.jadeInk)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("展开较早收起的 \(group.items.count) 件待办")
                        } else {
                            ForEach(group.items) { item in
                                DiscussionRow(
                                    item: item,
                                    isSelected: selectedID == item.id,
                                    now: groupingAnchor
                                ) {
                                    withMotion(CompanionMotion.rowExpand()) {
                                        self.selectedID = item.id
                                        self.showingSource = false
                                    }
                                }
                                .equatable()
                            }
                            if group.title == DiscussionPresentation.archivedGroupTitle {
                                Button("收起") { expandArchived = false }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.trailing, 12)
        }
    }

    private func detailPane(selected: DiscussionItem?) -> some View {
        Group {
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
    }

    private func taskDetail(_ item: DiscussionItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.content)
                    .workspaceTitle()
                    .textSelection(.enabled)
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
                // One action row. These were two blocks split by a Spacer, and
                // a Spacer inside a ScrollView expands to the viewport — the
                // finish button ended up ~200pt below the note it acts on.
                HStack(alignment: .center, spacing: 18) {
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
                    .foregroundStyle(SettingsView.Tab.tasks.accentColor)
                    .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 12)
                    if item.status == .pending {
                        Button {
                            update(id: item.id, to: .done, previous: item.status, title: item.content)
                        } label: {
                            // Sized to its title, not to the pane.
                            //
                            // This was `Text("标记完成").frame(maxWidth: .infinity)`,
                            // which rendered a 436pt-wide filled bar for a 4-character
                            // label — width driven by the pane, not the word. A
                            // full-bleed filled button is the iOS primary-action
                            // pattern; on macOS a push button is sized to its title
                            // and sits at the trailing edge of the row it belongs to.
                            Text("标记完成")
                        }
                        .tint(SettingsView.Tab.tasks.accentColor)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button("恢复为未完成") { update(id: item.id, to: .pending, previous: item.status, title: item.content) }
                            .buttonStyle(.bordered)
                    }
                }
                Text("这是助手从聊天里整理的，只改这里不会改微信原文。")
                    .font(.system(size: 11))
                    // An assurance the user has to be able to read: it is what
                    // tells them editing here will not touch WeChat. It measured
                    // 2.27:1 in `.tertiary` (see the note on the hint above).
                    .foregroundStyle(.secondary)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.jadeInk)
            Text(text).font(.system(size: 13, weight: .medium))
            Spacer()
            if let undo {
                Button("撤销") { update(id: undo.id, to: undo.status, previous: nil, title: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .font(.system(size: 13, weight: .semibold))
            } else if let previous = batchUndo {
                Button("撤销") {
                    for item in previous {
                        try? monitor.setDiscussionItemStatus(id: item.id, status: item.status)
                    }
                    batchUndo = nil
                    receipt = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(CompanionPalette.jadeInk)
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

    private func reconcileSelection(in items: [DiscussionItem]) {
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
            let ranked = DiscussionPresentation.items(
                monitor.discussionItems.filter { $0.chatUsername == chat },
                scope: .all, query: "", history: false
            )
            selectedID = ranked.first(where: { !$0.kind.isRecord })?.id ?? ranked.first?.id
            panelState.pendingDiscussionChatUsername = nil
        }
    }

    private func update(id: Int64, to status: DiscussionItemStatus, previous: DiscussionItemStatus?, title: String?) {
        do {
            try monitor.setDiscussionItemStatus(id: id, status: status)
            if showHistory { refreshHistory() }
            error = nil
            undo = previous.map { (id, $0) }
            batchUndo = nil
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

    private func batchClear(items: [DiscussionItem]) {
        guard !items.isEmpty else { return }
        let previous = items.map { ($0.id, $0.status) }
        batchUndo = previous
        undo = nil
        do {
            try monitor.batchUpdateDiscussionItemsStatus(ids: items.map(\.id), status: .done)
            if showHistory { refreshHistory() }
            receipt = "已清空 \(items.count) 件待办"
            error = nil
        } catch {
            self.error = "清空失败，请重试。"
        }
    }
}

/// One row of the 待办 list.
///
/// Extracted from the workspace so SwiftUI can diff rows independently: as a
/// method on the parent it was rebuilt whenever the parent's body re-ran, which
/// is what made a long list expensive to scroll. `Equatable` lets the list skip
/// rows whose inputs did not change.
private struct DiscussionRow: View, Equatable {
    let item: DiscussionItem
    let isSelected: Bool
    let now: Date
    let onTap: () -> Void

    static func == (lhs: DiscussionRow, rhs: DiscussionRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.now == rhs.now
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .companionFont(size: WorkspaceType.title, weight: .medium)
                    .foregroundStyle(item.status == .done ? CompanionPalette.jadeInk : .secondary)
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
                Text(DiscussionPresentation.dueLabel(item.dueAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
           .background(
               isSelected ? CompanionPalette.selectedFill : CompanionPalette.surface,
               in: RoundedRectangle(cornerRadius: 12, style: .continuous)
           )
           .overlay(
               RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? SettingsView.Tab.tasks.accentColor.opacity(0.35) : CompanionPalette.border, lineWidth: CompanionAccessibility.cardEdgeWidth)
           )
       }
        .buttonStyle(CompanionPressStyle())
        .accessibilityLabel(item.content)
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
                .tint(CompanionPalette.jade)
                .buttonStyle(.borderedProminent)
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

/// Memoizes one `DiscussionPresentation.items` pass.
///
/// The live pending corpus is unbounded (it grows past a few thousand rows), so
/// a single filter+sort is far too expensive to repeat. SwiftUI re-evaluates a
/// body many times per interaction — and a row that reads the resolved list
/// itself multiplies that by the row count — so the result is cached against the
/// exact inputs and only recomputed when one of them actually changes.
///
/// The input comparison is a plain array equality: cheap pointer-level compares,
/// versus a full sort that copies every `DiscussionItem`.
final class DiscussionItemsCache {
    private var source: [DiscussionItem] = []
    private var scope: DiscussionScope = .all
    private var query = ""
    private var history = false
    private var result: [DiscussionItem] = []
    private var primed = false
    private var dayStart: Date = .distantPast
    private var rankMinute: Int = 0

    func items(
        _ source: [DiscussionItem],
        scope: DiscussionScope,
        query: String,
        history: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DiscussionItem] {
        let day = calendar.startOfDay(for: now)
        let minute = Int(now.timeIntervalSince1970 / 60)
        if primed, self.scope == scope, self.query == query, self.history == history,
           self.source == source, dayStart == day, rankMinute == minute {
            return result
        }
        let next = DiscussionPresentation.items(source, scope: scope, query: query, history: history, now: now, calendar: calendar)
        primed = true
        self.source = source
        self.scope = scope
        self.query = query
        self.history = history
        dayStart = day
        rankMinute = minute
        result = next
        return next
    }
}

enum DiscussionPresentation {
    struct Group {
        let title: String
        let items: [DiscussionItem]
    }

    static func items(_ items: [DiscussionItem], scope: DiscussionScope, query: String, history: Bool) -> [DiscussionItem] {
        Self.items(items, scope: scope, query: query, history: history, now: Date(), calendar: .current)
    }

    static func items(
        _ items: [DiscussionItem],
        scope: DiscussionScope,
        query: String,
        history: Bool,
        now: Date,
        calendar: Calendar
    ) -> [DiscussionItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard history ? item.status != .pending : item.status == .pending else { return false }
            let matches: Bool
            switch scope {
            case .all: matches = true
            // "Records" is two kinds, not one. `timePlace` is the same
            // category as `info` — the extractor's prompt lists both as the
            // pure-record kinds ("纯记录型内容（info/timePlace 常用）") — and
            // the strictness levels hold both back from the task list. When
            // this tab filtered to `info` alone, a held-back 时间地点 item had
            // no tab that could ever show it, so it was invisible at every
            // level while still counting as "已收起".
            case .notes: matches = item.kind == .info || item.kind == .timePlace
            // Record kinds belong to 信息备忘 alone. Leaving `timePlace` in
            // these three would list the same 时间地点 twice — once as work
            // and once as a memo — which is exactly the confusion the levels
            // exist to remove.
            case .mine: matches = item.owner == .mine && !item.kind.isRecord
            case .theirs: matches = item.owner == .theirs && !item.kind.isRecord
            case .shared: matches = item.owner == .shared && !item.kind.isRecord
            }
            return matches && (query.isEmpty || [item.content, item.detail ?? "", item.chatName].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            if history { return $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id > $1.id }
            let left = liveRank($0, now: now)
            let right = liveRank($1, now: now)
            if left.bucket != right.bucket { return left.bucket < right.bucket }
            if left.time != right.time {
                return left.ascending ? left.time < right.time : left.time > right.time
            }
            if $0.sourceTimestamp != $1.sourceTimestamp { return $0.sourceTimestamp > $1.sourceTimestamp }
            return $0.id > $1.id
        }
    }

    /// Live ranking: still-open due dates (soonest first) → already-past due
    /// (newest source) → undated (newest source). A due time that has already
    /// passed today ranks with overdue, not with tonight's remaining work.
    private struct LiveRank {
        let bucket: Int
        let time: TimeInterval
        let ascending: Bool
    }

    private static func liveRank(_ item: DiscussionItem, now: Date) -> LiveRank {
        guard let due = item.dueAt else {
            return LiveRank(bucket: 2, time: TimeInterval(item.sourceTimestamp), ascending: false)
        }
        if due < now {
            return LiveRank(bucket: 1, time: TimeInterval(item.sourceTimestamp), ascending: false)
        }
        return LiveRank(bucket: 0, time: due.timeIntervalSince1970, ascending: true)
    }

    static let archivedGroupTitle = "较早收起"

    static func groups(_ items: [DiscussionItem], now: Date = Date(), calendar: Calendar = .current, history: Bool = false) -> [Group] {
        if history {
            let order = ["已完成", "已忽略", archivedGroupTitle]
            let mapped = Dictionary(grouping: items) { historyTitle(for: $0.status) }
            return order.compactMap { title in
                mapped[title].map { Group(title: title, items: $0) }
            }
        }
        let order = ["今天", "明天", "本周", "之后", "已到期", "无期限"]
        let mapped = Dictionary(grouping: items) { groupTitle(for: $0.dueAt, now: now, calendar: calendar) }
        return order.compactMap { title in
            mapped[title].map { Group(title: title, items: $0) }
        }
    }

    private static func historyTitle(for status: DiscussionItemStatus) -> String {
        switch status {
        case .done: return "已完成"
        case .dismissed: return "已忽略"
        case .archived: return archivedGroupTitle
        case .pending: return "未完成"
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
        if date < now && !calendar.isDate(date, inSameDayAs: now) { return "已到期" }
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

    /// Live todos are not filtered by the review date. The heading must
    /// say so when the user is looking at another day.
    static func heading(selectedDate: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(selectedDate, inSameDayAs: now) {
            return "当前待办"
        }
        return "现在的待办（与所选日期无关）"
    }

    static func items(chatUsername: String, discussion: [DiscussionItem]) -> [Item] {
        let ranked = DiscussionPresentation.items(
            discussion.filter { $0.chatUsername == chatUsername },
            scope: .all,
            query: "",
            history: false
        ).filter { !$0.kind.isRecord }
        return ranked.prefix(3)
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
