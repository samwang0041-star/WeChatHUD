import SwiftUI

private func attentionLevelTitle(_ level: AttentionLevel) -> String {
    switch level {
    case .vip: return "重点关注"
    case .whitelist: return "关注"
    case .greylist: return "仅保留资料"
    case .stranger: return "未关注"
    }
}

struct ContactsSettingsView: View {
    enum SubTab: String, CaseIterable {
        case rules = "什么会提醒我"
        case contacts = "关注的人"
        case aiScan = "推荐关注"
        case blockRules = "不看谁"
        case silenced = "静音"
    }

    @State private var selectedSubTab: SubTab = .contacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedSubTab {
            case .rules:
                organizeBack
                AdmissionSettingsView()
            case .contacts:
                ContactsListSubView(organizeTab: $selectedSubTab)
            case .aiScan:
                organizeBack
                WhitelistScanView()
            case .blockRules:
                organizeBack
                BlockRulesSubView(organizeTab: $selectedSubTab)
            case .silenced:
                organizeBack
                SilencedChatsSubView()
            }
        }
    }

    private var organizeBack: some View {
        Button("返回关注列表") { withMotion(CompanionMotion.pageChange()) { selectedSubTab = .contacts } }
            .buttonStyle(CompanionPressStyle())
            .foregroundStyle(CompanionPalette.jadeInk)
            .companionFont(size: 13, weight: .medium)
    }
}

// MARK: - Contacts List

private enum AddKindFilter: String, CaseIterable {
    case all = "全部"
    case people = "联系人"
    case groups = "群聊"
}

private enum ContactLevelFilter: String, CaseIterable {
    case all = "全部"
    case vip = "重点关注"
    case groups = "群聊"

    var level: AttentionLevel? {
        switch self {
        case .all, .groups: return nil
        case .vip: return .vip
        }
    }
}

private struct ContactsListSubView: View {
    @Binding var organizeTab: ContactsSettingsView.SubTab
   @EnvironmentObject private var store: HUDStore
   @EnvironmentObject private var monitor: ChatMonitor
   @EnvironmentObject private var reader: WeChatReader

    @EnvironmentObject private var panelState: PanelState

    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var selectedFilter: ContactLevelFilter = .all
    @State private var selectedContactID: String?
    @State private var editingContact: ContactEntry?
    @State private var showAddPopover = false
    @State private var addSearchText = ""
    @State private var selectedAddUsernames: Set<String> = []
    @State private var addKind: AddKindFilter = .all
    @State private var operationError: String?
    @State private var pendingDeleteContact: ContactEntry?
    @State private var candidateReloadToken = 0
    @State private var cachedAddWechatContacts: [String: String] = [:]
    @State private var isLoadingCandidates = false
    @State private var candidateLoadError: String?
    @State private var didLoad = false
    @State private var isAddingContacts = false
    @State private var isDeletingContact = false

    private var filtered: [ContactEntry] {
        contacts.filter { contact in
            let matchesGroup = selectedFilter != .groups || isGroupContact(contact)
            let matchesLevel = selectedFilter.level.map { contact.attentionLevel == $0 } ?? true
            guard matchesGroup else { return false }
            let matchesSearch = searchText.isEmpty
                || contact.displayName.localizedCaseInsensitiveContains(searchText)
                || contact.username.localizedCaseInsensitiveContains(searchText)
                || contact.role.label.localizedCaseInsensitiveContains(searchText)
                || contact.roleNote.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }

    private func isGroupContact(_ contact: ContactEntry) -> Bool {
        ContactWhitelistTracking.isGroup(store: store, username: contact.username)
    }

    private var selectedContact: ContactEntry? {
        if let selectedContactID, let contact = contacts.first(where: { $0.username == selectedContactID }) {
            return contact
        }
        return filtered.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toolbar
            HStack(spacing: 8) {
                TextField("搜索联系人或群聊", text: $searchText)
                    .accessibilityLabel("搜索联系人")
                    .textFieldStyle(.roundedBorder)
                    .companionFont(size: 12)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)

                Spacer()

                if let status = monitor.contactInferenceStatus {
                    aiJobChip(status)
                }

                Menu("更多") {
                    Button("什么会提醒我") { withMotion(CompanionMotion.pageChange()) { organizeTab = .rules } }
                    Divider()
                    Button("批量整理关系") { monitor.startContactInference(contacts: contacts) }
                    Button("推荐关注") { withMotion(CompanionMotion.pageChange()) { organizeTab = .aiScan } }
                    Button("不看谁") { withMotion(CompanionMotion.pageChange()) { organizeTab = .blockRules } }
                    Button("静音") { withMotion(CompanionMotion.pageChange()) { organizeTab = .silenced } }
                    if monitor.contactInferenceStatus?.isRunning == true {
                        Button("停止整理") { monitor.cancelContactInference() }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("整理范围")

            }
            .companionSurface(padding: 10)

            if let error = operationError, pendingDeleteContact == nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(error)
                        .companionFont(size: 12)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("知道了") { self.operationError = nil }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                }
                .padding(.horizontal, 4)
                .transition(.companionStatusReveal)
            }

                HStack(spacing: 8) {
                    CompanionFilterPill(title: "全部 \(contacts.count)", selected: selectedFilter == .all, tint: SettingsView.Tab.contacts.accentColor) { selectedFilter = .all }
                    CompanionFilterPill(title: "重点关注 \(contacts.filter { $0.attentionLevel == .vip }.count)", selected: selectedFilter == .vip, tint: SettingsView.Tab.contacts.accentColor) { selectedFilter = .vip }
                    CompanionFilterPill(title: "群聊 \(contacts.filter { isGroupContact($0) }.count)", selected: selectedFilter == .groups, tint: SettingsView.Tab.contacts.accentColor) { selectedFilter = .groups }
                }
                .onChange(of: selectedFilter) {
                    if let selectedContactID,
                       !filtered.contains(where: { $0.username == selectedContactID }) {
                        self.selectedContactID = filtered.first?.username
                    }
                }


            HSplitView {
                List {
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            if contacts.isEmpty {
                                emptyState(icon: "person.crop.circle.badge.plus", text: "还没有关注的人", hint: "添加之后，助手才知道该看谁。")
                               Button(CompanionProductCopy.addFollow) { openAddFollow() }
                                    .tint(CompanionPalette.jade)
                                    .buttonStyle(.borderedProminent)
                                   .controlSize(.small)
                            } else {
                                emptyState(icon: "person.crop.circle.badge.questionmark", text: "没有匹配联系人", hint: "换个关键词或级别筛选")
                                if !searchText.isEmpty {
                                    Button("清除搜索") { searchText = "" }
                                        .buttonStyle(.bordered)
                                } else if selectedFilter != .all {
                                    Button("看全部") {
                                        withMotion(CompanionMotion.pageChange()) { selectedFilter = .all }
                                    }
                                    .buttonStyle(CompanionPressStyle())
                                    .foregroundStyle(CompanionPalette.jadeInk)
                                    .accessibilityLabel("看全部联系人")
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                    } else {
                        contactGroup(level: .vip, title: "重点关注", color: .orange)
                        contactGroup(level: .whitelist, title: "关注", color: CompanionPalette.accent)
                        contactGroup(level: .greylist, title: "仅保留资料", color: .gray)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(CompanionPalette.canvas)
                // Fit the smallest supported window. The previous minima
                // (230 + 260) exceeded the content column left after the
                // 236pt sidebar and 28pt of padding each side, so the
                // inspector pane was laid out past the right edge and its
                // controls were clipped out of reach.
                .frame(minWidth: 200, idealWidth: 360, maxWidth: 500, maxHeight: .infinity)
                .accessibilityLabel("已关注的人")

                ContactInspectorView(
                    contact: selectedContact,
                    hasContacts: !contacts.isEmpty,
                    onAddFollow: openAddFollow,
                    typeLabel: selectedContact.map { ContactWhitelistTracking.typeLabel(store: store, username: $0.username) } ?? "",
                    profile: selectedContact.flatMap { store.getRelationshipProfile(username: $0.username) },
                    inferenceStatus: monitor.contactInferenceStatus,
                    onEdit: { editingContact = $0 },
                    onInfer: { monitor.startContactInference(contacts: [$0]) },
                    onChangeLevel: { contact, level in
                        if saveContact(contact, level: level) { reload() }
                    },
                    onDelete: { contact in
                        pendingDeleteContact = contact
                    }
                )
                .frame(minWidth: 230, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .background(CompanionPalette.canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudAddContact)) { _ in
            openAddFollow()
        }
        .companionDialogBackdrop(showAddPopover || pendingDeleteContact != nil) {
            if showAddPopover {
                CompanionDialog(title: CompanionProductCopy.addFollow, onClose: { if !isAddingContacts { showAddPopover = false } }) {
                    addContactDialog
                }
            }
            else if let contact = pendingDeleteContact {
                CompanionDialog(title: "确认删除联系人？", onClose: { if !isDeletingContact { pendingDeleteContact = nil } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("会忘掉助手对这个人的关注和整理结果。微信里的聊天记录不会被删。")
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let operationError {
                            Text(operationError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { pendingDeleteContact = nil }
                                .companionBusyHold(isDeletingContact, "正在删除这个联系人")
                            Button(role: .destructive) {
                                guard !isDeletingContact else { return }
                                isDeletingContact = true
                                Task { @MainActor in
                                    let ok = deleteContact(contact)
                                    isDeletingContact = false
                                    if ok {
                                        panelState.showToast(
                                            CompanionInteractionCopy.contactRemoved(name: contact.displayName))
                                        if selectedContactID == contact.username { selectedContactID = nil }
                                        pendingDeleteContact = nil
                                        reload()
                                    }
                                }
                            } label: {
                                Text(isDeletingContact ? "正在删除联系人…" : "删除联系人")
                            }
                            .disabled(isDeletingContact)
                            .help(isDeletingContact ? "正在删除这个联系人" : "")
                            .accessibilityHint(isDeletingContact ? "正在删除这个联系人" : "")
                        }
                    }
                }
            }
        }
        .task(id: candidateReloadToken) {
            guard showAddPopover, !PreviewRuntime.isEnabled else { return }
            await loadContactCandidatesAsync()
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
        .companionAnimation(CompanionMotion.ease(), value: operationError)
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(
                contact: contact,
                store: store,
                monitor: monitor,
                onSave: { reload() },
                onError: { operationError = $0 }
            )
        }
    }

    private func aiJobChip(_ status: ContactInferenceStatus) -> some View {
        HStack(spacing: 4) {
            if status.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            Text(status.label)
                .monospacedDigit()
        }
        .companionFont(size: 10, weight: .medium)
        .foregroundColor(status.isRunning ? .blue : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(5)
        .help(status.isRunning ? "正在后台整理这些人是谁，你可以继续做别的" : "上次整理的结果")
    }

    // MARK: - Add contact dialog

    private var addContactDialog: some View {
        let available = addCandidates()
        return VStack(alignment: .leading, spacing: 12) {
            Text("只开始整理选中的对话")
                .companionFont(size: 12)
                .foregroundStyle(.secondary)
            TextField("搜索联系人或群聊", text: $addSearchText)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(AddKindFilter.allCases, id: \.self) { kind in
                    CompanionFilterPill(title: kind.rawValue, selected: addKind == kind) { addKind = kind }
                }
            }
            if isLoadingCandidates && available.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取微信联系人…")
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else if available.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(addSearchText.isEmpty ? "没有可添加的对话。已关注的不会出现在这里。" : "没有匹配的对话。换个名字试试。")
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                    if let candidateLoadError, addSearchText.isEmpty {
                        Text(candidateLoadError)
                            .companionFont(size: 11)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.companionStatusReveal)
                    }
                    if !addSearchText.isEmpty {
                        Button("清除搜索") { addSearchText = "" }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("清除搜索")
                    } else if addKind != .all {
                        Button("看全部") {
                            withMotion(CompanionMotion.pageChange()) { addKind = .all }
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .accessibilityLabel("看全部可添加的对话")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(available.prefix(8), id: \.username) { contact in
                        Button {
                            if selectedAddUsernames.contains(contact.username) {
                                selectedAddUsernames.remove(contact.username)
                            } else {
                                selectedAddUsernames.insert(contact.username)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                CompanionAvatar(name: contact.displayName, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.displayName).companionFont(size: 13, weight: .medium)
                                    Text(contact.isGroup ? "群聊" : "私聊")
                                        .companionFont(size: 11)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selectedAddUsernames.contains(contact.username) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(CompanionPalette.jadeInk)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CompanionRowPressStyle())
                        .accessibilityLabel(selectedAddUsernames.contains(contact.username) ? "取消选择 \(contact.displayName)" : "选择 \(contact.displayName)")
                    }
                }
            }
            HStack {
                Text("已选 \(selectedAddUsernames.count) 个")
                    .companionFont(size: 12)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { showAddPopover = false }
                    .companionBusyHold(isAddingContacts, "正在添加关注")
                Button {
                    guard !isAddingContacts else { return }
                    isAddingContacts = true
                    Task { @MainActor in
                        addSelectedContacts()
                        isAddingContacts = false
                    }
                } label: {
                    Text(isAddingContacts ? "正在添加关注…" : CompanionProductCopy.addFollow)
                }
                    .tint(CompanionPalette.jade)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAddUsernames.isEmpty || isAddingContacts)
                    .help(isAddingContacts ? "正在添加关注" : (selectedAddUsernames.isEmpty ? "先选要关注的对话" : ""))
                    .accessibilityHint(isAddingContacts ? "正在添加关注" : (selectedAddUsernames.isEmpty ? "先选要关注的对话" : ""))
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: candidateLoadError)
    }

    private func addCandidates() -> [(username: String, displayName: String, isGroup: Bool)] {
        let existingSet = Set(contacts.map(\.username))
        let preview: [(username: String, displayName: String, isGroup: Bool)] = PreviewRuntime.isEnabled
            ? [
                ("preview-zhou", "周予", false),
                ("preview-an", "安然", false),
                ("preview-dev-group", "研发讨论群", true),
                ("preview-client-group", "客户沟通群", true)
            ]
            : []
        // Live candidates come from async-loaded cache (WeChatReaderActor), never
        // sync reader work in the view body.
        let live: [(username: String, displayName: String, isGroup: Bool)] = {
            guard !PreviewRuntime.isEnabled else { return [] }
            return cachedAddWechatContacts
                .filter { !existingSet.contains($0.key) && !$0.key.hasPrefix("gh_") && $0.key != "filehelper" }
                .map { (username: $0.key, displayName: $0.value, isGroup: MessageHelpers.isGroupChat($0.key)) }
        }()
        return (preview + live)
            .filter { !existingSet.contains($0.username) }
            .filter {
                switch addKind {
                case .all: return true
                case .people: return !$0.isGroup
                case .groups: return $0.isGroup
                }
            }
            .filter {
                addSearchText.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(addSearchText)
                    || $0.username.localizedCaseInsensitiveContains(addSearchText)
            }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    private func openAddFollow() {
        addSearchText = ""
        selectedAddUsernames = []
        addKind = .all
        candidateReloadToken += 1
        showAddPopover = true
    }

    private func addSelectedContacts() {
        let chosen = addCandidates().filter { selectedAddUsernames.contains($0.username) }
        do {
            for contact in chosen {
                try store.saveContactTracking(
                    username: contact.username,
                    displayName: contact.displayName,
                    isGroup: contact.isGroup,
                    category: .work,
                    attentionLevel: .whitelist,
                    role: .colleague,
                    roleNote: "",
                    replyWindowMinutes: ContactRole.colleague.defaultReplyWindowMinutes
                )
            }
           reload()
           showAddPopover = false
           selectedAddUsernames = []
           for contact in chosen {
                panelState.returnToInsightIfResuming(
                    contact.username,
                    receipt: "已添加关注：\(contact.displayName)")
           }
       } catch {
            operationError = "添加联系人失败，原设置未改变。请重试。"
        }
    }

    /// Refresh contact-index + sessions via `WeChatReaderActor` (off body sync).
    private func loadContactCandidatesAsync() async {
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        let readerActor = WeChatReaderActor(reader)
        var errors: [String] = []
        do {
            _ = try await readerActor.refreshContactsIfChanged()
       } catch {
           errors.append(CompanionInteractionCopy.contactsIndexFailed)
       }
       let indexed = await readerActor.allContacts()
       do {
           _ = try await readerActor.sessions()
       } catch {
           errors.append(CompanionInteractionCopy.contactsSessionsFailed)
       }
        cachedAddWechatContacts = indexed
        candidateLoadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    // MARK: - Contact sections

    @ViewBuilder
    private func contactGroup(level: AttentionLevel, title: String, color: Color) -> some View {
        let items = filtered.filter { $0.attentionLevel == level }
        if !items.isEmpty {
            Section {
                ForEach(items) { contact in contactRow(contact, color: color) }
            } header: {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).companionFont(size: 11, weight: .semibold)
                    Text("(\(items.count))").companionFont(size: 10).foregroundColor(.secondary)
                }
            }
        }
    }

    private func contactRow(_ contact: ContactEntry, color: Color) -> some View {
        let isSelected = selectedContactID == contact.username
        return Button { selectedContactID = contact.username } label: {
            HStack(spacing: 8) {
                Image(systemName: contactRoleSymbol(contact.role))
                    .companionFont(size: 13, weight: .medium)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName).companionFont(size: 13).foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote).companionFont(size: 11).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(contact.role.label)
                    .companionFont(size: 11, weight: .medium).foregroundColor(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.12)).cornerRadius(3)
                if contact.replyWindowMinutes > 0 {
                    // Was "120m", then a bare "120 分钟" whose only explanation
                    // lived in hover/AX — a scanning reader still takes it for
                    // time already waited. The threshold words ride along.
                    Text("\(contact.replyWindowMinutes) 分钟算超时")
                        .companionFont(size: 11, design: .monospaced).foregroundColor(.secondary)
                        .help("超过 \(contact.replyWindowMinutes) 分钟没回，这条就标成超时")
                        .accessibilityLabel("\(contact.replyWindowMinutes) 分钟没回算超时")
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .companionFont(size: 11, weight: .semibold)
                        .foregroundStyle(CompanionPalette.accent)
                }
                Image(systemName: "chevron.right")
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? CompanionPalette.accent.opacity(0.14) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompanionRowPressStyle())
        .accessibilityLabel(contact.displayName)
        .contextMenu {
            Button("编辑") {
                editingContact = contact
            }
            Divider()
            Menu("变更级别") {
                ForEach([AttentionLevel.vip, .whitelist, .greylist], id: \.self) { level in
                    if level != contact.attentionLevel {
                        Button(attentionLevelTitle(level)) {
                            if saveContact(contact, level: level, announce: true) { reload() }
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                pendingDeleteContact = contact
            }
        }
    }

    @discardableResult
    private func saveContact(_ contact: ContactEntry, level: AttentionLevel, announce: Bool = false) -> Bool {
        switch ContactWhitelistTracking.fields(store: store, username: contact.username, role: contact.role) {
        case .unreadable(let message):
            operationError = message
            if announce { panelState.showToast(message) }
            return false
        case .fields(let fields):
            do {
                try store.saveContactTracking(
                    username: contact.username,
                    displayName: contact.displayName,
                    isGroup: fields.isGroup,
                    category: fields.category,
                    attentionLevel: level,
                    role: contact.role,
                    roleNote: contact.roleNote,
                   replyWindowMinutes: contact.replyWindowMinutes
               )
                let receipt = CompanionInteractionCopy.followLevelChanged(
                    levelTitle: attentionLevelTitle(level),
                    name: contact.displayName)
                panelState.returnToInsightIfResuming(contact.username, receipt: receipt)
                if announce { panelState.showToast(receipt) }
                return true
            } catch {
                let message = "联系人级别未保存，原设置仍保留。请重试。"
                operationError = message
                if announce { panelState.showToast(message) }
                return false
            }
        }
    }

    @discardableResult
    private func deleteContact(_ contact: ContactEntry) -> Bool {
        do {
            try store.deleteContactAndTracking(username: contact.username)
            return true
        } catch {
            operationError = "联系人删除失败，原资料仍保留。请重试。"
            return false
        }
    }

    private func reload() {
        contacts = store.loadContacts(level: nil)
        if selectedContactID == nil {
            selectedContactID = filtered.first?.username
        } else if let selectedContactID, !contacts.contains(where: { $0.username == selectedContactID }) {
            self.selectedContactID = filtered.first?.username
        }
    }
}

private struct ContactInspectorView: View {
    let contact: ContactEntry?
    let hasContacts: Bool
    let onAddFollow: () -> Void
    let typeLabel: String
    let profile: RelationshipProfile?
    let inferenceStatus: ContactInferenceStatus?
    let onEdit: (ContactEntry) -> Void
    let onInfer: (ContactEntry) -> Void
    let onChangeLevel: (ContactEntry, AttentionLevel) -> Void
    let onDelete: (ContactEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let contact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(contact)
                        Divider()
                        trackingSection(contact)
                        Divider()
                        aiProfileSection(contact)
                        Divider()
                        operationsSection(contact)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if hasContacts {
                emptyState(icon: "person.text.rectangle", text: "选择一个人或一个群", hint: "看看助手会不会提醒你、以及怎么看待这段关系")
            } else {
                VStack(spacing: 10) {
                    emptyState(icon: "person.crop.circle.badge.plus", text: "还没有关注的人", hint: "添加之后，助手才知道该看谁。")
                   Button(CompanionProductCopy.addFollow) { onAddFollow() }
                        .tint(CompanionPalette.jade)
                        .buttonStyle(.borderedProminent)
                       .controlSize(.small)
                }
            }
        }
        .background(CompanionPalette.canvas)
    }

    private func header(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: contactRoleSymbol(contact.role))
                    .companionFont(size: WorkspaceType.title)
                    .foregroundStyle(contactLevelColor(contact.attentionLevel))
                    .frame(width: 36, height: 36)
                    .background(contactLevelColor(contact.attentionLevel).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .workspaceTitle()
                        .lineLimit(1)
                }
                Spacer()
                levelBadge(contact.attentionLevel)
            }

            if !contact.roleNote.isEmpty {
                Text(contact.roleNote)
                    .companionFont(size: 13)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            DisclosureGroup {
                // 类型 lives in 这个对话 below; stating it here too put the
                // same fact twice in one panel.
                infoRow("微信 ID", value: contact.username)
            } label: {
                // The stock label is its glyph height (15pt) — under the 24pt
                // hit floor measured by the HIG audit.
                Text("账号信息")
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .companionFont(size: 12, weight: .medium)
        }
    }

    private func trackingSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Was 「整理范围 / 只整理已关注的对话」: that sentence restates the
            // global 提醒范围 mode, which the user can change to 全部未读都提醒
            // on this very page — so it went stale on its own, and 整理范围
            // never described the two rows under it anyway.
            sectionTitle("这个对话", systemImage: "info.circle")
            // One vocabulary for one fact: this row said 私聊 while the
            // 账号信息 block above called the same thing 联系人.
            infoRow("类型", value: typeLabel)
            if contact.replyWindowMinutes > 0 {
                infoRow("多久算超时", value: "\(contact.replyWindowMinutes) 分钟没回算超时")
            }
        }
    }

    private func aiProfileSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("TA 是谁", systemImage: "sparkles")
                Spacer()
                Button {
                    onInfer(contact)
                } label: {
                    if inferenceStatus?.isRunning == true {
                        Label("正在整理…", systemImage: "arrow.clockwise")
                    } else {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("重新整理这个人")
                .disabled(inferenceStatus?.isRunning == true)
                .help(inferenceStatus?.isRunning == true ? "正在推断关系" : "后台重新推断这个联系人")
                .accessibilityHint(inferenceStatus?.isRunning == true ? "正在推断关系" : "")
            }

            if let profile {
                infoRow("关系", value: profile.relationship)
                infoRow("层级", value: profile.hierarchy.label)
                infoRow("口吻", value: profile.tonePreference.label)
                if let context = profile.context, !context.isEmpty {
                    Text(context)
                        .companionFont(size: 11)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ProgressView(value: profile.confidence)
                        .frame(width: 90)
                    Text("\(Int(profile.confidence * 100))%")
                        .companionFont(size: 11, design: .monospaced)
                        .foregroundColor(.secondary)
                    if profile.userEdited {
                        Text("已人工校准")
                            .companionFont(size: 10, weight: .medium)
                            .foregroundColor(.green)
                    }
                }
            } else {
                Text("还不知道这个人是谁。点右边的「重新整理」，会在后台进行，不影响你继续用。")
                    .companionFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func operationsSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("操作", systemImage: "slider.horizontal.3")
            Picker("关注级别", selection: Binding(
                get: { contact.attentionLevel },
                set: { onChangeLevel(contact, $0) }
            )) {
                Text("重点关注").tag(AttentionLevel.vip)
                Text("关注").tag(AttentionLevel.whitelist)
                Text("仅保留资料").tag(AttentionLevel.greylist)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button("编辑详情") { onEdit(contact) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                Spacer(minLength: 16)
                Button("移除关注", role: .destructive) { onDelete(contact) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                    .accessibilityLabel("移除关注")
            }
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .companionFont(size: 12, weight: .semibold)
            .foregroundColor(.primary)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .companionFont(size: 11)
                .foregroundColor(.secondary)
                .companionScaledWidth(58, alignment: .leading)
            Text(value)
                .companionFont(size: 12, weight: .medium)
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func levelBadge(_ level: AttentionLevel) -> some View {
        Text(attentionLevelTitle(level))
            .companionFont(size: 10, weight: .semibold)
            .foregroundColor(contactLevelColor(level))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(contactLevelColor(level).opacity(0.12))
            .cornerRadius(5)
    }

    private func trackingReason(_ contact: ContactEntry) -> String {
        switch contact.attentionLevel {
        case .vip:
            return "优先提醒该回的消息。"
        case .whitelist:
            return "会整理这个人的聊天。"
        case .greylist:
            return "不日常提醒。"
        case .stranger:
            return "未关注。"
        }
    }

}

// MARK: - Block Rules

private struct BlockRulesSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor
    @Binding var organizeTab: ContactsSettingsView.SubTab

    @State private var ignoredSenders: [IgnoredSenderRule] = []
    /// A failed read is not an empty list — see AdmissionSettingsView.
    @State private var unreadable = false
    @State private var didLoad = false
    @State private var busyRestoreKey: String?
    @State private var restoreError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if unreadable {
                VStack(spacing: 10) {
                    emptyState(icon: "exclamationmark.triangle", text: "没能读到忽略名单——不代表它是空的。", hint: "名单还在磁盘上，只是这次没读出来。")
                    Button("重新读取") { reload() }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .accessibilityLabel("重新读取忽略名单")
                }
            } else if ignoredSenders.isEmpty {
                VStack(spacing: 10) {
                    emptyState(icon: "person.slash", text: "没有忽略的发送人", hint: "按人全局设置在「什么会提醒我」，按对话则在消息上右键。")
                    Button("什么会提醒我") {
                        withMotion(CompanionMotion.pageChange()) { organizeTab = .rules }
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .accessibilityLabel("去什么会提醒我添加忽略规则")
                }
            } else {
                Text("被忽略的发送人不计入未读统计。要按人全局设置，用「什么会提醒我」。")
                    .companionFont(size: 11).foregroundColor(.secondary)
                if let restoreError {
                    Label(restoreError, systemImage: "exclamationmark.triangle")
                        .companionFont(size: 12)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.companionStatusReveal)
                }

                SettingsSection {
                    ForEach(Array(ignoredSenders.enumerated()), id: \.element.id) { idx, rule in
                        if idx > 0 { SettingsRowDivider() }
                        SettingsRow(
                            rule.senderName,
                            // A global rule has no single conversation to name,
                            // so saying "所有对话" is the honest subtitle.
                            subtitle: rule.scope == .global ? "所有对话都不提醒" : rule.chatName
                        ) {
                            Button {
                                let key = "\(rule.chatUsername)|\(rule.senderUsername)"
                                guard busyRestoreKey == nil else { return }
                                busyRestoreKey = key
                                restoreError = nil
                                let ok = monitor.unignoreSender(
                                    chatUsername: rule.chatUsername,
                                    senderUsername: rule.senderUsername,
                                    senderName: rule.senderName
                                )
                                busyRestoreKey = nil
                                if ok {
                                    reload()
                                } else {
                                    restoreError = monitor.inboxActionError
                                        ?? "屏蔽规则未能恢复，原规则仍保留。请重试。"
                                }
                            } label: {
                                Text(busyRestoreKey == "\(rule.chatUsername)|\(rule.senderUsername)" ? "正在恢复…" : "恢复")
                            }
                            .controlSize(.small)
                            .buttonStyle(CompanionPressStyle())
                            .disabled(busyRestoreKey != nil)
                            .help(busyRestoreKey != nil ? "正在恢复提醒" : "")
                            .accessibilityHint(busyRestoreKey != nil ? "正在恢复提醒" : "")
                        }
                    }
                }
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: restoreError)
        .onAppear { if !didLoad { reload(); didLoad = true } }
    }

    private func reload() {
        if let rules = store.ignoredSendersRead() {
            ignoredSenders = rules
            unreadable = false
        } else {
            unreadable = true
        }
    }
}

// MARK: - Silenced Chats

private struct SilencedChatsSubView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @State private var busyUnmute: String?
    @State private var unmuteError: String?

    var body: some View {
        let silenced = monitor.silencedConversationsRead
        VStack(alignment: .leading, spacing: 8) {
            if let silenced {
                if silenced.isEmpty {
                    // Readable and empty really is 「没人被静音」.
                    VStack(spacing: 10) {
                        emptyState(icon: "speaker.slash", text: "没有静音的对话", hint: "在今天或收件箱的消息上右键，选择“静音此对话”。")
                        Button("打开今天") { panelState.pendingSettingsTab = "today" }
                            .buttonStyle(CompanionPressStyle())
                            .foregroundStyle(CompanionPalette.jadeInk)
                            .accessibilityLabel("打开今天，从一条消息静音对话")
                    }
                } else {
                    // The old sentence only claimed the inbox half. A mute also
                    // suppresses the banner and — since this round — stops the
                    // conversation reaching the assistant and withdraws a draft that
                    // was already queued, which is the part worth saying out loud.
                    Text("已静音的对话不会出现在收件箱、不会弹提醒，助手也不会替你回复它。")
                        .companionFont(size: 11).foregroundColor(.secondary)
                    if let unmuteError {
                        Label(unmuteError, systemImage: "exclamationmark.triangle")
                            .companionFont(size: 12)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.companionStatusReveal)
                    }

                    SettingsSection {
                        ForEach(Array(silenced.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 { SettingsRowDivider() }
                            SettingsRow(
                                item.displayName,
                                subtitle: "静音中 · 助手不会回复这条对话",
                                icon: "speaker.slash.fill",
                                iconColor: .red.opacity(0.5)
                            ) {
                                Button {
                                    guard busyUnmute == nil else { return }
                                    busyUnmute = item.username
                                    unmuteError = nil
                                    let ok = monitor.unsilenceConversation(username: item.username)
                                    busyUnmute = nil
                                    if !ok {
                                        unmuteError = monitor.inboxActionError
                                            ?? "未能取消静音，这条对话仍然保持静音。请重试。"
                                    }
                                } label: {
                                    Text(busyUnmute == item.username ? "正在取消静音…" : "取消静音")
                                }
                                .controlSize(.small)
                                .buttonStyle(CompanionPressStyle())
                                .disabled(busyUnmute != nil)
                                .help(busyUnmute != nil ? "正在取消静音" : "")
                                .accessibilityHint(busyUnmute != nil ? "正在取消静音" : "")
                            }
                        }
                    }
                }
            } else {
                // 「读不到」 printed as 「没有静音的对话」 used to send the user the
                // other way: 确认发送 refuses a muted chat and points at this page,
                // and this page claimed there was nothing muted — the one escape
                // hatch that refusal names was taken away by the same failed read.
                Label("暂时读不到静音名单：这里既不能说没人被静音，也拿不出「取消静音」。稍后再打开这一页看一次。",
                      systemImage: "exclamationmark.triangle")
                    .companionFont(size: 11)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新读取") { monitor.refreshNow() }
                    .controlSize(.small)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: unmuteError)
    }
}

// MARK: - Empty state helper

private func emptyState(icon: String, text: String, hint: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: icon)
            .companionFont(size: WorkspaceType.title)
            .foregroundColor(.secondary.opacity(0.3))
        Text(text)
            .workspaceBody()
            .foregroundColor(.secondary)
        Text(hint)
            .workspaceMicro()
            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
    }
    .frame(maxWidth: .infinity, minHeight: 120)
}

// MARK: - Edit Sheet

struct ContactEditSheet: View {
    let contact: ContactEntry
    let store: HUDStore
    let monitor: ChatMonitor
    let onSave: () -> Void
    let onError: (String) -> Void

   @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var panelState: PanelState
   @State private var selectedLevel: AttentionLevel
    @State private var selectedRole: ContactRole
    @State private var roleNote: String
    @State private var replyWindow: Int
    @State private var relProfile: RelationshipProfile? = nil
    @State private var relRelationship: String = ""
    @State private var relHierarchy: RelationshipProfile.Hierarchy = .peer
    @State private var relTone: RelationshipProfile.TonePreference = .formal
    @State private var relNote: String = ""
    @State private var isInferring = false
    @State private var inferenceError: String?
    @State private var customName: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        contact: ContactEntry,
        store: HUDStore,
        monitor: ChatMonitor,
        onSave: @escaping () -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.contact = contact
        self.store = store
        self.monitor = monitor
        self.onSave = onSave
        self.onError = onError
        _selectedLevel = State(initialValue: contact.attentionLevel)
        _selectedRole  = State(initialValue: contact.role)
        _roleNote      = State(initialValue: contact.roleNote)
        _replyWindow   = State(initialValue: contact.replyWindowMinutes)
        _customName    = State(initialValue: store.chatAlias(for: contact.username) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: contactRoleSymbol(contact.role))
                        .companionFont(size: WorkspaceType.title, weight: .medium)
                        .foregroundStyle(contactLevelColor(contact.attentionLevel))
                        .frame(width: 28, height: 28)
                        .background(contactLevelColor(contact.attentionLevel).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.displayName).companionFont(size: 14, weight: .semibold)
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .companionBusyHold(isSaving, "正在保存联系人设置")
                Button {
                    guard !isSaving else { return }
                    isSaving = true
                    Task { @MainActor in
                        save()
                        isSaving = false
                    }
                } label: {
                    Text(isSaving ? "正在保存…" : "保存")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .help(isSaving ? "正在保存联系人设置" : "")
                .accessibilityHint(isSaving ? "正在保存联系人设置" : "")
            }
            .padding()

            Divider()

            if let saveError {
                Text(saveError)
                    .companionFont(size: 12)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.companionStatusReveal)
            }

            Form {
                Section("显示名称") {
                    TextField("给这个对话起个名字", text: $customName)
                    Text(customNameHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup {
                        LabeledContent("微信 ID", value: contact.username)
                        LabeledContent("类型", value: ContactWhitelistTracking.typeLabel(store: store, username: contact.username))
                    } label: {
                        Text("账号信息")
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }

                Section("关注设置") {
                    Picker("级别", selection: $selectedLevel) {
                        Text("重点关注").tag(AttentionLevel.vip)
                        Text("关注").tag(AttentionLevel.whitelist)
                        Text("仅保留资料").tag(AttentionLevel.greylist)
                    }

                    Picker("角色", selection: $selectedRole) {
                        ForEach(ContactRole.allCases, id: \.self) { role in
                            Label(role.label, systemImage: contactRoleSymbol(role)).tag(role)
                        }
                    }
                    .onChange(of: selectedRole) { replyWindow = selectedRole.defaultReplyWindowMinutes }

                    TextField("备注", text: $roleNote)

                    Text(selectedRole.roleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("回复追踪") {
                    HStack {
                    // 「设为 0 不追踪」 was never true, and after this round's fix
                    // 0 means "use the default tier". The number never schedules a
                    // reminder either — it is the age at which a message starts
                    // counting as 超时, which is what raises its priority.
                    Stepper("多久算超时", value: $replyWindow, in: 0...480, step: 15)
                    Text("\(replyWindow) 分钟")
                        .companionFont(size: 12, design: .monospaced)
                        .foregroundColor(.secondary)
                        .companionScaledWidth(60, alignment: .trailing)
                }
                Text("超过这个时长还没回，这条就标成超时、排得更靠前。0 = 用默认时长。")
                    .font(.caption).foregroundColor(.secondary)
                }

                Section("TA 是谁") {
                    if let profile = relProfile {
                        Picker("关系", selection: $relRelationship) {
                            ForEach(Self.relationshipOptions, id: \.self) { Text($0).tag($0) }
                            if !Self.relationshipOptions.contains(relRelationship) && !relRelationship.isEmpty {
                                Text(relRelationship).tag(relRelationship)
                            }
                        }
                        Picker("层级", selection: $relHierarchy) {
                            ForEach(RelationshipProfile.Hierarchy.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        Picker("沟通风格", selection: $relTone) {
                            ForEach(RelationshipProfile.TonePreference.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        TextField("备注", text: $relNote)
                        if let ctx = profile.context, !ctx.isEmpty {
                            Text(ctx)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            ProgressView(value: profile.confidence)
                                .frame(maxWidth: 80)
                            Text("\(Int(profile.confidence * 100))%")
                                .companionFont(size: 11, design: .monospaced)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(isInferring ? "正在推断…" : "重新推断") { runInference() }
                                .controlSize(.small)
                                .disabled(isInferring)
                                .help(isInferring ? "正在推断关系" : "")
                                .accessibilityHint(isInferring ? "正在推断关系" : "")
                        }
                    } else {
                        HStack {
                            Text("还不知道这个人是谁")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button(isInferring ? "正在推断…" : "开始推断") { runInference() }
                                .controlSize(.small)
                            .disabled(isInferring)
                            .help(isInferring ? "正在推断关系" : "")
                            .accessibilityHint(isInferring ? "正在推断关系" : "")
                        }
                    }
                    if let inferenceError {
                        Text(inferenceError)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.companionStatusReveal)
                    }
                }
            }
            .formStyle(.grouped)
            .companionAnimation(CompanionMotion.ease(), value: inferenceError)
            .companionAnimation(CompanionMotion.ease(), value: saveError)
            .onAppear { loadRelProfile() }
        }
        .frame(width: 420, height: 520)
    }

    private func loadRelProfile() {
        relProfile = store.getRelationshipProfile(username: contact.username)
        if let p = relProfile {
            relRelationship = p.relationship
            relHierarchy = p.hierarchy
            relTone = p.tonePreference
            relNote = p.userNote ?? ""
        }
    }

    private var customNameHint: String {
        if MessageHelpers.isGroupChat(contact.username), monitor.hasOnlyFallbackName(chatUsername: contact.username) {
            return "微信里这个群没有名字，助手只能显示群成员。起个名字后，收件箱和「我答应的事」都会用它。"
        }
        return "留空则使用微信里的名字。"
    }

    private func runInference() {
        isInferring = true
        inferenceError = nil
        Task {
            let result = await monitor.inferRelationship(
                contactUsername: contact.username,
                contactName: contact.displayName
            )
            isInferring = false
            if result != nil { loadRelProfile() }
            else { inferenceError = "没整理成功，原来的内容还在。请先确认 AI 能用，再试一次。" }
        }
    }

    private func save() {
        saveError = nil
        let tracking: (isGroup: Bool, category: WhitelistCategory)
        switch ContactWhitelistTracking.fields(store: store, username: contact.username, role: selectedRole) {
        case .unreadable(let message):
            saveError = message
            onError(message)
            return
        case .fields(let fields):
            tracking = fields
        }
        // The name the user chose here wins over WeChat's own label, and it
        // has to be written to every table that cached the old one.
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clearing the field means "go back to the name WeChat/助手 reports",
        // so drop the alias first and re-resolve — `contact.displayName` still
        // holds the old alias.
        let displayName: String
        if trimmedName.isEmpty {
            do {
                try store.removeChatAlias(username: contact.username)
            } catch {
                let message = "联系人设置未完整保存，编辑窗口仍保持打开。请重试；微信聊天记录不受影响。"
                saveError = message
                onError(message)
                return
            }
            displayName = monitor.displayName(for: contact.username)
        } else {
            displayName = trimmedName
        }
        do {
            try store.withTransaction {
                try store.saveContactTracking(
                    username: contact.username,
                    displayName: displayName,
                    isGroup: tracking.isGroup,
                    category: tracking.category,
                    attentionLevel: selectedLevel,
                    role: selectedRole,
                    roleNote: roleNote,
                    replyWindowMinutes: replyWindow
                )
                if relProfile != nil {
                    try store.updateRelationshipProfileUserFields(
                        username: contact.username,
                        relationship: relRelationship,
                        hierarchy: relHierarchy,
                        tonePreference: relTone,
                        userNote: relNote.isEmpty ? nil : relNote
                    )
                }
                if trimmedName.isEmpty {
                    store.propagateChatName(username: contact.username, displayName: displayName,
                                            previousName: contact.displayName)
                } else {
                    try store.setChatAlias(username: contact.username, displayName: trimmedName,
                                           previousName: contact.displayName)
                }
            }
            // Reload published lists so the rename shows up in the inbox,
            // commitments and workspace without waiting for the next scan.
           monitor.reloadAIData()
           monitor.rebuildInbox()
            let receipt = CompanionInteractionCopy.contactSettingsSaved(name: displayName)
            panelState.returnToInsightIfResuming(contact.username, receipt: receipt)
            panelState.showToast(receipt)
           onSave()
           dismiss()
        } catch {
            let message = "联系人设置未完整保存，编辑窗口仍保持打开。请重试；微信聊天记录不受影响。"
            saveError = message
            onError(message)
        }
    }

    private static let relationshipOptions = [
        "直属领导", "上级领导", "同事", "下属", "客户", "供应商",
        "合作方", "家人", "朋友", "同学", "其他"
    ]


}

private enum ContactWhitelistTracking {
    enum Outcome {
        case fields((isGroup: Bool, category: WhitelistCategory))
        case unreadable(String)
    }

    enum Kind {
        case group, person, unreadable
    }

    static func kind(store: HUDStore, username: String) -> Kind {
        if MessageHelpers.isGroupChat(username) { return .group }
        switch store.whitelistEntryRead(username) {
        case .unreadable: return .unreadable
        case .absent: return .person
        case .value(let entry): return entry.isGroup ? .group : .person
        }
    }

    static func isGroup(store: HUDStore, username: String) -> Bool {
        kind(store: store, username: username) == .group
    }

    static func typeLabel(store: HUDStore, username: String) -> String {
        switch kind(store: store, username: username) {
        case .group: return "群聊"
        case .person: return "私聊"
        case .unreadable: return "暂时读不到"
        }
    }

    static func fields(
        store: HUDStore,
        username: String,
        role: ContactRole
    ) -> Outcome {
        switch store.whitelistEntryRead(username) {
        case .unreadable:
            return .unreadable(CompanionInteractionCopy.followLevelUnreadable)
        case .absent:
            return .fields((MessageHelpers.isGroupChat(username), whitelistCategory(for: role)))
        case .value(let entry):
            return .fields((entry.isGroup, entry.category))
        }
    }
}

private func whitelistCategory(for role: ContactRole) -> WhitelistCategory {
    switch role {
    case .family, .friend:
        return .life
    case .acquaintance, .groupOnly, .service:
        return .other
    case .boss, .keyClient, .partner, .colleague, .client, .supplier:
        return .work
    }
}

private func contactRoleSymbol(_ role: ContactRole) -> String {
    switch role {
    case .boss: return "person.crop.circle.badge.exclamationmark"
    case .keyClient: return "star.circle.fill"
    case .family: return "house.fill"
    case .partner: return "person.2.circle.fill"
    case .colleague: return "person.2.fill"
    case .client: return "person.crop.circle"
    case .friend: return "person.crop.circle.fill"
    case .supplier: return "shippingbox.fill"
    case .acquaintance: return "person.fill"
    case .groupOnly: return "person.3.fill"
    case .service: return "building.2.fill"
    }
}

private func contactLevelColor(_ level: AttentionLevel) -> Color {
    switch level {
    case .vip: return .orange
    case .whitelist: return CompanionPalette.accent
    case .greylist: return .gray
    case .stranger: return .secondary
    }
}
