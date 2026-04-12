import SwiftUI

/// Whitelist management.
///
/// The previous version eagerly rendered every WeChat contact inside a
/// `LazyVStack` with a per-row `Menu`. With a few thousand contacts that
/// created a few thousand NSMenu instances at build time, which made the
/// settings panel pathologically slow. This redesign never renders the
/// full list:
///
/// 1. **智能导入** — one click ranks chats by `sqlite_sequence.seq` (cheap
///    AUTOINCREMENT row-count) and bulk-adds the top N most active ones.
/// 2. **Current whitelist** — only the entries the user has already added
///    (usually < 50 rows) are rendered.
/// 3. **Search to add** — typing in the search field runs an in-memory
///    filter on `reader.allContacts()` and renders at most 30 results. No
///    typing → no list → no work.
struct WhitelistSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var reader: WeChatReader

    @State private var whitelist: [WhitelistEntry] = []
    @State private var searchText: String = ""
    @State private var searchResults: [Contact] = []
    @State private var isAnalyzing: Bool = false
    @State private var importMessage: String?
    @State private var loadError: String?

    /// Candidates surfaced by the smart analyzer. Displayed as a preview
    /// list with per-row checkboxes; user confirms before anything is
    /// persisted to the whitelist. `nil` means "no analysis yet".
    @State private var candidates: [WeChatReader.ActiveContact]? = nil
    @State private var selectedCandidates: Set<String> = []

    /// Multi-select mode for the "已选联系人" section — when true each row
    /// grows a checkbox and a batch toolbar (全选 / 清空 / 批量删除) shows
    /// above the list so the user can prune dozens of entries without
    /// clicking each menu.
    @State private var isMultiSelecting: Bool = false
    @State private var selectedInWhitelist: Set<String> = []

    /// Contact-book cache built lazily on first search.
    @State private var allContactsSnapshot: [Contact] = []

    struct Contact: Identifiable, Hashable {
        let id: String           // username
        let displayName: String
        let isGroup: Bool
    }

    private let searchResultLimit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            definitionCard
            smartImportCard
            if let candidates = candidates {
                candidatesPreview(candidates)
            }
            whitelistSection
            searchSection
            if let err = loadError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .onAppear(perform: loadWhitelist)
    }

    private var vipCount: Int {
        whitelist.filter { $0.attentionLevel == .vip }.count
    }

    private var definitionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            definitionPill(
                title: "未读",
                color: .blue,
                lines: [
                    "只记录私聊",
                    "只记录群里 @你"
                ]
            )
            definitionPill(
                title: "白名单",
                color: .orange,
                lines: [
                    "持续跟踪的群和人",
                    "日报 / 周报 / AI 分析的来源"
                ]
            )
            definitionPill(
                title: "VIP",
                color: .yellow,
                lines: [
                    "白名单里的强提醒层",
                    "会进通知 Banner 和关注区顶部"
                ]
            )
        }
    }

    private func definitionPill(title: String, color: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Smart import card

    private var smartImportCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange)
                    .frame(width: 36, height: 36)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("智能分析")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(importMessage ?? "按最近 45 天的活跃度筛选最值得加入白名单的聊天，导入后默认不强提醒")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: runSmartAnalysis) {
                HStack(spacing: 4) {
                    if isAnalyzing {
                        ProgressView().scaleEffect(0.55)
                    }
                    Text(isAnalyzing ? "分析中…" : "开始分析")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(isAnalyzing ? 0.5 : 0.9))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isAnalyzing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Candidates preview

    @ViewBuilder
    private func candidatesPreview(_ list: [WeChatReader.ActiveContact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("分析结果")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("选中 \(selectedCandidates.count) / \(list.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if list.isEmpty {
                Text("没有足够活跃的聊天。可以试试手动搜索添加。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(list, id: \.username) { c in
                        CandidateRow(
                            candidate: c,
                            isSelected: selectedCandidates.contains(c.username),
                            alreadyAdded: whitelist.contains(where: { $0.id == c.username }),
                            onToggle: { toggleCandidate(c.username) }
                        )
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                HStack {
                    Button(action: { selectAllCandidates(list) }) {
                        Text("全选")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button(action: { selectedCandidates.removeAll() }) {
                        Text("清空")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: { candidates = nil; selectedCandidates.removeAll() }) {
                        Text("取消")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    Button(action: { commitSelected(list) }) {
                        Text("导入 \(selectedCandidates.count) 项")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(selectedCandidates.isEmpty
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.accentColor)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedCandidates.isEmpty)
                }
            }
        }
    }

    private func toggleCandidate(_ username: String) {
        if selectedCandidates.contains(username) {
            selectedCandidates.remove(username)
        } else {
            selectedCandidates.insert(username)
        }
    }

    private func selectAllCandidates(_ list: [WeChatReader.ActiveContact]) {
        selectedCandidates = Set(list.map { $0.username })
    }

    // MARK: - Current whitelist

    private var whitelistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("白名单与 VIP")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Text(isMultiSelecting
                     ? "选中 \(selectedInWhitelist.count) / \(whitelist.count)"
                     : "\(whitelist.count) 项 · VIP \(vipCount)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
                if !whitelist.isEmpty {
                    Button(action: toggleMultiSelect) {
                        Text(isMultiSelecting ? "完成" : "多选")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if whitelist.isEmpty {
                Text("暂未配置任何白名单来源，点击智能分析或使用下方搜索添加。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                if isMultiSelecting {
                    multiSelectToolbar
                }
                VStack(spacing: 2) {
                    ForEach(whitelist, id: \.id) { entry in
                        WhitelistRow(
                            entry: entry,
                            multiSelecting: isMultiSelecting,
                            isSelected: selectedInWhitelist.contains(entry.id),
                            onTapSelect: { toggleWhitelistSelection(entry.id) },
                            onChangeCategory: { newCategory in
                                if let cat = newCategory {
                                    updateCategory(entry: entry, to: cat)
                                } else {
                                    removeEntry(entry)
                                }
                            },
                            onChangeAttention: { level in
                                updateAttention(entry: entry, to: level)
                            }
                        )
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    @ViewBuilder
    private var multiSelectToolbar: some View {
        HStack(spacing: 8) {
            Button(action: selectAllWhitelist) {
                Text("全选")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: { selectedInWhitelist.removeAll() }) {
                Text("清空选择")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                ForEach(WhitelistCategory.allCases, id: \.self) { cat in
                    Button(cat.label) { batchUpdateCategory(cat) }
                }
            } label: {
                Text("批量分类")
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(selectedInWhitelist.isEmpty)
            Menu {
                Button("设为白名单") { batchUpdateAttention(.watch) }
                Button("设为 VIP") { batchUpdateAttention(.vip) }
            } label: {
                Text("批量层级")
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(selectedInWhitelist.isEmpty)
            Button(action: batchRemove) {
                Text("删除 \(selectedInWhitelist.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selectedInWhitelist.isEmpty
                                ? Color.red.opacity(0.35)
                                : Color.red.opacity(0.85))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(selectedInWhitelist.isEmpty)
        }
    }

    // MARK: - Search to add

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("添加联系人")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("搜索联系人或群聊名称 / wxid", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .onChange(of: searchText) { updateSearch() }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = []
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )

            if !searchText.isEmpty {
                if searchResults.isEmpty {
                    Text("无匹配结果")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(searchResults) { contact in
                            SearchResultRow(
                                contact: contact,
                                alreadyAdded: whitelist.contains(where: { $0.id == contact.id }),
                                onAdd: { addContact(contact) }
                            )
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }

    // MARK: - Data actions

    private func loadWhitelist() {
        whitelist = store.getWhitelist()
    }

    /// Rebuild the in-memory contact snapshot from `reader` — lazy, only
    /// the first time the user searches. A subsequent search reuses it.
    private func ensureContactSnapshot() {
        guard allContactsSnapshot.isEmpty else { return }
        do {
            try reader.loadKeys()
            try reader.refreshContactsIfChanged()
        } catch {
            loadError = "无法读取联系人: \(error.localizedDescription)"
            return
        }
        let raw = reader.allContacts()
        allContactsSnapshot = raw.map { (username, display) in
            Contact(
                id: username,
                displayName: display.isEmpty ? username : display,
                isGroup: username.contains("@chatroom")
            )
        }
    }

    private func updateSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        ensureContactSnapshot()
        searchResults = allContactsSnapshot
            .filter { c in
                c.displayName.lowercased().contains(q) || c.id.lowercased().contains(q)
            }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            .prefix(searchResultLimit)
            .map { $0 }
    }

    private func addContact(_ contact: Contact) {
        do {
            try store.addToWhitelist(
                username: contact.id,
                displayName: contact.displayName,
                isGroup: contact.isGroup,
                category: .other,
                attentionLevel: .watch
            )
            loadWhitelist()
        } catch {
            loadError = "无法添加: \(error.localizedDescription)"
        }
    }

    private func updateCategory(entry: WhitelistEntry, to category: WhitelistCategory) {
        do {
            try store.addToWhitelist(
                username: entry.id,
                displayName: entry.displayName,
                isGroup: entry.isGroup,
                category: category,
                attentionLevel: entry.attentionLevel
            )
            loadWhitelist()
        } catch {
            loadError = "无法更新: \(error.localizedDescription)"
        }
    }

    private func updateAttention(entry: WhitelistEntry, to attentionLevel: WhitelistAttentionLevel) {
        do {
            try store.addToWhitelist(
                username: entry.id,
                displayName: entry.displayName,
                isGroup: entry.isGroup,
                category: entry.category,
                attentionLevel: attentionLevel
            )
            loadWhitelist()
        } catch {
            loadError = "无法更新提醒层级: \(error.localizedDescription)"
        }
    }

    private func removeEntry(_ entry: WhitelistEntry) {
        do {
            try store.removeFromWhitelist(username: entry.id)
            loadWhitelist()
        } catch {
            loadError = "无法移除: \(error.localizedDescription)"
        }
    }

    // MARK: - Multi-select actions

    private func toggleMultiSelect() {
        isMultiSelecting.toggle()
        if !isMultiSelecting {
            selectedInWhitelist.removeAll()
        }
    }

    private func toggleWhitelistSelection(_ id: String) {
        if selectedInWhitelist.contains(id) {
            selectedInWhitelist.remove(id)
        } else {
            selectedInWhitelist.insert(id)
        }
    }

    private func selectAllWhitelist() {
        selectedInWhitelist = Set(whitelist.map { $0.id })
    }

    private func batchRemove() {
        guard !selectedInWhitelist.isEmpty else { return }
        var failed = 0
        for id in selectedInWhitelist {
            do {
                try store.removeFromWhitelist(username: id)
            } catch {
                failed += 1
            }
        }
        selectedInWhitelist.removeAll()
        isMultiSelecting = false
        loadWhitelist()
        if failed > 0 {
            loadError = "部分条目删除失败 (\(failed))"
        }
    }

    private func batchUpdateCategory(_ category: WhitelistCategory) {
        guard !selectedInWhitelist.isEmpty else { return }
        // `addToWhitelist` is INSERT OR REPLACE so updating is an upsert.
        for entry in whitelist where selectedInWhitelist.contains(entry.id) {
            try? store.addToWhitelist(
                username: entry.id,
                displayName: entry.displayName,
                isGroup: entry.isGroup,
                category: category,
                attentionLevel: entry.attentionLevel
            )
        }
        loadWhitelist()
    }

    private func batchUpdateAttention(_ attentionLevel: WhitelistAttentionLevel) {
        guard !selectedInWhitelist.isEmpty else { return }
        for entry in whitelist where selectedInWhitelist.contains(entry.id) {
            try? store.addToWhitelist(
                username: entry.id,
                displayName: entry.displayName,
                isGroup: entry.isGroup,
                category: entry.category,
                attentionLevel: attentionLevel
            )
        }
        loadWhitelist()
    }

    // MARK: - Smart analyze / commit

    private func runSmartAnalysis() {
        isAnalyzing = true
        importMessage = nil
        loadError = nil
        candidates = nil
        selectedCandidates.removeAll()

        // Defer a tick so SwiftUI paints the spinner before the sqlite
        // work blocks main. Two-pass scan is typically well under 1s.
        DispatchQueue.main.async {
            do {
                try reader.loadKeys()
                try reader.refreshContactsIfChanged()
                let top = try reader.topActiveContacts(limit: 20)
                // Preselect entries that aren't already in the whitelist —
                // re-adding an existing one is a no-op but would still
                // count against the user's "selected N" number.
                let alreadyIn = Set(whitelist.map { $0.id })
                selectedCandidates = Set(top.map { $0.username }.filter { !alreadyIn.contains($0) })
                candidates = top
                isAnalyzing = false
                if top.isEmpty {
                    importMessage = "没有找到满足条件的聊天"
                } else {
                    let ind = top.filter { !$0.isGroup }.count
                    let grp = top.filter { $0.isGroup }.count
                    importMessage = "共 \(top.count) 个候选 · 个人 \(ind) / 群聊 \(grp)"
                }
            } catch {
                isAnalyzing = false
                loadError = "智能分析失败: \(error.localizedDescription)"
            }
        }
    }

    private func commitSelected(_ list: [WeChatReader.ActiveContact]) {
        var added = 0
        for c in list where selectedCandidates.contains(c.username) {
            // Category heuristic:
            //   individual → .life
            //   group      → .work
            // Imported entries default to plain whitelist/watch. Users
            // explicitly promote a smaller subset to VIP below.
            let category: WhitelistCategory = c.isGroup ? .work : .life
            do {
                try store.addToWhitelist(
                    username: c.username,
                    displayName: c.displayName,
                    isGroup: c.isGroup,
                    category: category,
                    attentionLevel: .watch
                )
                added += 1
            } catch {
                continue
            }
        }
        loadWhitelist()
        candidates = nil
        selectedCandidates.removeAll()
        importMessage = "已导入 \(added) 项白名单，可在下方调整分类或提升为 VIP"
    }
}

// MARK: - Whitelist row (current members)

private struct WhitelistRow: View {
    let entry: WhitelistEntry
    let multiSelecting: Bool
    let isSelected: Bool
    let onTapSelect: () -> Void
    let onChangeCategory: (WhitelistCategory?) -> Void
    let onChangeAttention: (WhitelistAttentionLevel) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if multiSelecting {
                Button(action: onTapSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
            }

            Image(systemName: entry.isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(entry.displayName)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if !multiSelecting {
                HStack(spacing: 6) {
                    attentionMenu
                    categoryMenu
                }
            } else {
                // In multi-select mode show the current category as a
                // non-interactive badge so the list row stays informative
                // without opening a menu per item.
                HStack(spacing: 6) {
                    staticBadge(label: entry.attentionLevel.shortLabel, color: color(for: entry.attentionLevel))
                    staticBadge(label: entry.category.label, color: color(for: entry.category))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if multiSelecting { onTapSelect() }
        }
    }

    @ViewBuilder
    private var categoryMenu: some View {
        Menu {
            ForEach(WhitelistCategory.allCases, id: \.self) { cat in
                Button(action: { onChangeCategory(cat) }) {
                    if entry.category == cat {
                        Label(cat.label, systemImage: "checkmark")
                    } else {
                        Text(cat.label)
                    }
                }
            }
            Divider()
            Button(role: .destructive, action: { onChangeCategory(nil) }) {
                Text("移出白名单")
            }
        } label: {
            badgeLabel(entry.category.label, color: color(for: entry.category))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var attentionMenu: some View {
        Menu {
            ForEach(WhitelistAttentionLevel.allCases, id: \.self) { level in
                Button(action: { onChangeAttention(level) }) {
                    if entry.attentionLevel == level {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
            }
        } label: {
            badgeLabel(entry.attentionLevel.shortLabel, color: color(for: entry.attentionLevel))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func color(for cat: WhitelistCategory) -> Color {
        switch cat {
        case .work:  return .blue
        case .life:  return .green
        case .other: return .orange
        }
    }

    private func color(for level: WhitelistAttentionLevel) -> Color {
        switch level {
        case .watch: return .orange
        case .vip: return .yellow
        }
    }

    private func staticBadge(label: String, color: Color) -> some View {
        badgeLabel(label, color: color, interactive: false)
    }

    private func badgeLabel(_ label: String, color: Color, interactive: Bool = true) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
            if interactive {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(3)
    }
}

// MARK: - Candidate row (smart analysis results)

private struct CandidateRow: View {
    let candidate: WeChatReader.ActiveContact
    let isSelected: Bool
    let alreadyAdded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 16)

                Image(systemName: candidate.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(candidate.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if candidate.isGroup {
                            Text("群")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(2)
                        }
                        if alreadyAdded {
                            Text("已在白名单")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("近 45 天 \(candidate.recentCount) 条 · 总计 \(candidate.totalCount)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    let contact: WhitelistSettingsView.Contact
    let alreadyAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: contact.isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(contact.displayName)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if alreadyAdded {
                Text("已添加")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                Button(action: onAdd) {
                    Text("添加")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
