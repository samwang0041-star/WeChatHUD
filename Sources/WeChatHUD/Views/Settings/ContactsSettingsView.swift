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
        case contacts = "关注的人"
        case aiScan = "推荐关注"
        case blockRules = "不看谁"
        case silenced = "静音"
    }

    @State private var selectedSubTab: SubTab = .contacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedSubTab {
            case .contacts:
                ContactsListSubView(organizeTab: $selectedSubTab)
            case .aiScan:
                organizeBack
                WhitelistScanView()
            case .blockRules:
                organizeBack
                BlockRulesSubView()
            case .silenced:
                organizeBack
                SilencedChatsSubView()
            }
        }
    }

    private var organizeBack: some View {
        Button("返回关注列表") { selectedSubTab = .contacts }
            .buttonStyle(.plain)
            .foregroundStyle(CompanionPalette.jade)
            .font(.system(size: 13, weight: .medium))
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
    @State private var didLoad = false

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
        contact.username.contains("@chatroom") || store.getWhitelistEntry(username: contact.username)?.isGroup == true
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
                    .font(.system(size: 12))
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)

                Spacer()

                if let status = monitor.contactInferenceStatus {
                    aiJobChip(status)
                }

                Menu("更多") {
                    Button("批量整理关系") { monitor.startContactInference(contacts: contacts) }
                    Button("推荐关注") { organizeTab = .aiScan }
                    Button("不看谁") { organizeTab = .blockRules }
                    Button("静音") { organizeTab = .silenced }
                    if monitor.contactInferenceStatus?.isRunning == true {
                        Button("停止整理") { monitor.cancelContactInference() }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("整理范围")

            }
            .companionSurface(padding: 10)

                HStack(spacing: 8) {
                    CompanionFilterPill(title: "全部 \(contacts.count)", selected: selectedFilter == .all) { selectedFilter = .all }
                    CompanionFilterPill(title: "重点关注 \(contacts.filter { $0.attentionLevel == .vip }.count)", selected: selectedFilter == .vip) { selectedFilter = .vip }
                    CompanionFilterPill(title: "群聊 \(contacts.filter { isGroupContact($0) }.count)", selected: selectedFilter == .groups) { selectedFilter = .groups }
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
                        emptyState(icon: "person.crop.circle.badge.questionmark", text: "没有匹配联系人", hint: "换个关键词或级别筛选")
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
                .frame(minWidth: 230, idealWidth: 380, maxWidth: 500, maxHeight: .infinity)
                .accessibilityLabel("已关注的人")

                ContactInspectorView(
                    contact: selectedContact,
                    whitelistEntry: selectedContact.flatMap { store.getWhitelistEntry(username: $0.username) },
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
                .frame(minWidth: 260, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .background(CompanionPalette.canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudAddContact)) { _ in
            addSearchText = ""
            selectedAddUsernames = []
            addKind = .all
            showAddPopover = true
        }
        .companionDialogBackdrop(showAddPopover) {
            if showAddPopover {
                CompanionDialog(title: CompanionProductCopy.addFollow, onClose: { showAddPopover = false }) {
                    addContactDialog
                }
            }
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
        .alert("联系人操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了") { operationError = nil }
        } message: {
            Text(operationError ?? "请重试")
        }
        .alert("确认删除联系人？", isPresented: Binding(
            get: { pendingDeleteContact != nil },
            set: { if !$0 { pendingDeleteContact = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteContact = nil }
            Button("删除联系人", role: .destructive) {
                guard let contact = pendingDeleteContact else { return }
                pendingDeleteContact = nil
                if deleteContact(contact) {
                    if selectedContactID == contact.username { selectedContactID = nil }
                    reload()
                }
            }
        } message: {
            Text("会忘掉助手对这个人的关注和整理结果。微信里的聊天记录不会被删。")
        }
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
        .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索联系人或群聊", text: $addSearchText)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(AddKindFilter.allCases, id: \.self) { kind in
                    CompanionFilterPill(title: kind.rawValue, selected: addKind == kind) { addKind = kind }
                }
            }
            if available.isEmpty {
                Text(addSearchText.isEmpty ? "没有可添加的对话。已关注的不会出现在这里。" : "没有匹配的对话。换个名字试试。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
                                    Text(contact.displayName).font(.system(size: 13, weight: .medium))
                                    Text(contact.isGroup ? "群聊" : "私聊")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selectedAddUsernames.contains(contact.username) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(CompanionPalette.jade)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selectedAddUsernames.contains(contact.username) ? "取消选择 \(contact.displayName)" : "选择 \(contact.displayName)")
                    }
                }
            }
            HStack {
                Text("已选 \(selectedAddUsernames.count) 个")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { showAddPopover = false }
                Button(CompanionProductCopy.addFollow) { addSelectedContacts() }
                    .buttonStyle(.borderedProminent)
                    .tint(CompanionPalette.jade)
                    .disabled(selectedAddUsernames.isEmpty)
            }
        }
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
        let live: [(username: String, displayName: String, isGroup: Bool)] = {
            guard !PreviewRuntime.isEnabled else { return [] }
            let source = loadContactCandidates()
            return source.wechatContacts
                .filter { !existingSet.contains($0.key) && !$0.key.hasPrefix("gh_") && $0.key != "filehelper" }
                .map { (username: $0.key, displayName: $0.value, isGroup: $0.key.contains("@chatroom")) }
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
        } catch {
            operationError = "添加联系人失败，原设置未改变。请重试。"
        }
    }

    private func loadContactCandidates() -> (
        wechatContacts: [String: String],
        sessions: [SessionInfo],
        error: String?
    ) {
        _ = candidateReloadToken
        var errors: [String] = []
        do {
            _ = try reader.refreshContactsIfChanged()
        } catch {
            errors.append("联系人索引读取失败，请检查微信数据目录和密钥后重试。")
            print("[WCHUD] contacts settings: refresh contact index failed: \(error)")
        }
        let indexed = reader.allContacts()
        var sessions: [SessionInfo] = []
        do {
            sessions = try reader.getSessions()
        } catch {
            errors.append("最近会话读取失败；可先使用已读取的联系人索引，或重试。")
            print("[WCHUD] contacts settings: load sessions failed: \(error)")
        }
        return (indexed, sessions, errors.isEmpty ? nil : errors.joined(separator: "\n"))
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
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text("(\(items.count))").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func contactRow(_ contact: ContactEntry, color: Color) -> some View {
        let isSelected = selectedContactID == contact.username
        return Button { selectedContactID = contact.username } label: {
            HStack(spacing: 8) {
                Image(systemName: contactRoleSymbol(contact.role))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName).font(.system(size: 13)).foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(contact.role.label)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.12)).cornerRadius(3)
                if contact.replyWindowMinutes > 0 {
                    Text("\(contact.replyWindowMinutes)m")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionPalette.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? CompanionPalette.accent.opacity(0.14) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            if saveContact(contact, level: level) { reload() }
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
    private func saveContact(_ contact: ContactEntry, level: AttentionLevel) -> Bool {
        let whitelistEntry = store.getWhitelistEntry(username: contact.username)
        do {
            try store.saveContactTracking(
                username: contact.username,
                displayName: contact.displayName,
                isGroup: whitelistEntry?.isGroup ?? contact.username.contains("@chatroom"),
                category: whitelistEntry?.category ?? whitelistCategory(for: contact.role),
                attentionLevel: level,
                role: contact.role,
                roleNote: contact.roleNote,
                replyWindowMinutes: contact.replyWindowMinutes
            )
            return true
        } catch {
            operationError = "联系人级别未保存，原设置仍保留。请重试。"
            return false
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
    let whitelistEntry: WhitelistEntry?
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
            } else {
                emptyState(icon: "person.text.rectangle", text: "选择一个人或一个群", hint: "看看助手会不会提醒你、以及怎么看待这段关系")
            }
        }
        .background(CompanionPalette.canvas)
    }

    private func header(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: contactRoleSymbol(contact.role))
                    .font(.system(size: 28))
                    .foregroundStyle(contactLevelColor(contact.attentionLevel))
                    .frame(width: 36, height: 36)
                    .background(contactLevelColor(contact.attentionLevel).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
                levelBadge(contact.attentionLevel)
            }

            if !contact.roleNote.isEmpty {
                Text(contact.roleNote)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            DisclosureGroup("账号信息") {
                infoRow("微信 ID", value: contact.username)
                infoRow("类型", value: (contact.username.contains("@chatroom") || whitelistEntry?.isGroup == true) ? "群聊" : "联系人")
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private func trackingSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("整理范围", systemImage: "scope")
            Text("只整理已关注的对话")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            infoRow("关注级别", value: attentionLevelTitle(contact.attentionLevel))
            infoRow("类型", value: (contact.username.contains("@chatroom") || whitelistEntry?.isGroup == true) ? "群聊" : "私聊")
            if contact.replyWindowMinutes > 0 {
                infoRow("提醒时机", value: "\(contact.replyWindowMinutes) 分钟后提醒")
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
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("重新整理这个人")
                .disabled(inferenceStatus?.isRunning == true)
                .help("后台重新推断这个联系人")
            }

            if let profile {
                infoRow("关系", value: profile.relationship)
                infoRow("层级", value: profile.hierarchy.label)
                infoRow("口吻", value: profile.tonePreference.label)
                if let context = profile.context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ProgressView(value: profile.confidence)
                        .frame(width: 90)
                    Text("\(Int(profile.confidence * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if profile.userEdited {
                        Text("已人工校准")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                }
            } else {
                Text("还不知道这个人是谁。点右上角后会在后台整理，不影响你继续用。")
                    .font(.system(size: 11))
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
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.primary)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func levelBadge(_ level: AttentionLevel) -> some View {
        Text(attentionLevelTitle(level))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(contactLevelColor(level))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(contactLevelColor(level).opacity(0.12))
            .cornerRadius(5)
    }

    private func trackingReason(_ contact: ContactEntry) -> String {
        switch contact.attentionLevel {
        case .vip:
            return "会优先提醒你该回的消息。"
        case .whitelist:
            return "助手会整理这个人的聊天。"
        case .greylist:
            return "只记住是谁，不日常提醒。"
        case .stranger:
            return "还没让助手看这个人。"
        }
    }

}

// MARK: - Block Rules

private struct BlockRulesSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var ignoredSenders: [IgnoredSenderRule] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ignoredSenders.isEmpty {
                emptyState(icon: "person.slash", text: "没有忽略的发送人", hint: "通过消息右键菜单添加忽略规则")
            } else {
                Text("被忽略的发送人不计入未读统计")
                    .font(.system(size: 11)).foregroundColor(.secondary)

                SettingsSection {
                    ForEach(Array(ignoredSenders.enumerated()), id: \.element.id) { idx, rule in
                        if idx > 0 { SettingsRowDivider() }
                        SettingsRow(rule.senderName, subtitle: rule.chatName) {
                            Button("恢复") {
                                monitor.unignoreSender(
                                    chatUsername: rule.chatUsername,
                                    senderUsername: rule.senderUsername,
                                    senderName: rule.senderName
                                )
                                reload()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
    }

    private func reload() { ignoredSenders = store.loadIgnoredSenders() }
}

// MARK: - Silenced Chats

private struct SilencedChatsSubView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        let silenced = monitor.silencedItems
        VStack(alignment: .leading, spacing: 8) {
            if silenced.isEmpty {
                emptyState(icon: "speaker.slash", text: "没有静音的对话", hint: "在收件箱中右键点击消息，选择“静音此对话”")
            } else {
                Text("已静音的对话不会出现在收件箱中")
                    .font(.system(size: 11)).foregroundColor(.secondary)

                SettingsSection {
                    ForEach(Array(silenced.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { SettingsRowDivider() }
                        SettingsRow(
                            item.chatName,
                            subtitle: item.aiSummary ?? item.preview,
                            icon: "speaker.slash.fill",
                            iconColor: .red.opacity(0.5)
                        ) {
                            Button("取消静音") {
                                monitor.unsilenceInboxItem(item)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Empty state helper

private func emptyState(icon: String, text: String, hint: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: icon)
            .font(.system(size: 24))
            .foregroundColor(.secondary.opacity(0.3))
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        Text(hint)
            .font(.system(size: 10))
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
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(contactLevelColor(contact.attentionLevel))
                        .frame(width: 28, height: 28)
                        .background(contactLevelColor(contact.attentionLevel).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.displayName).font(.system(size: 14, weight: .semibold))
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("显示名称") {
                    TextField("给这个对话起个名字", text: $customName)
                    Text(customNameHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("账号信息") {
                        LabeledContent("微信 ID", value: contact.username)
                        LabeledContent("类型", value: contact.username.contains("@chatroom") || store.getWhitelistEntry(username: contact.username)?.isGroup == true ? "群聊" : "联系人")
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
                        Stepper("提醒时机", value: $replyWindow, in: 0...480, step: 15)
                        Text("\(replyWindow) 分钟")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text("默认 \(selectedRole.defaultReplyWindowMinutes) 分钟 · 设为 0 不追踪")
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
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("重新推断") { runInference() }
                                .controlSize(.small)
                                .disabled(isInferring)
                        }
                    } else {
                        HStack {
                            Text("还不知道这个人是谁")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button(isInferring ? "推断中…" : "开始推断") { runInference() }
                                .controlSize(.small)
                            .disabled(isInferring)
                        }
                    }
                    if let inferenceError {
                        Text(inferenceError)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
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
        if contact.username.contains("@chatroom"), monitor.hasOnlyFallbackName(chatUsername: contact.username) {
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
        let whitelistEntry = store.getWhitelistEntry(username: contact.username)
        // The name the user chose here wins over WeChat's own label, and it
        // has to be written to every table that cached the old one.
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clearing the field means "go back to the name WeChat/助手 reports",
        // so drop the alias first and re-resolve — `contact.displayName` still
        // holds the old alias.
        let displayName: String
        if trimmedName.isEmpty {
            try? store.removeChatAlias(username: contact.username)
            displayName = monitor.displayName(for: contact.username)
        } else {
            displayName = trimmedName
        }
        do {
            try store.withTransaction {
                try store.saveContactTracking(
                    username: contact.username,
                    displayName: displayName,
                    isGroup: whitelistEntry?.isGroup ?? contact.username.contains("@chatroom"),
                    category: whitelistEntry?.category ?? whitelistCategory(for: selectedRole),
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
            onSave()
            dismiss()
        } catch {
            onError("联系人设置未完整保存，编辑窗口仍保持打开。请重试；微信聊天记录不受影响。")
        }
    }

    private static let relationshipOptions = [
        "直属领导", "上级领导", "同事", "下属", "客户", "供应商",
        "合作方", "家人", "朋友", "同学", "其他"
    ]


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
