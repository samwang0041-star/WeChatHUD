import SwiftUI

struct ContactsSettingsView: View {
    enum SubTab: String, CaseIterable {
        case contacts = "通讯录"
        case aiScan = "AI 扫描"
        case blockRules = "屏蔽规则"
        case silenced = "静音管理"
    }

    @State private var selectedSubTab: SubTab = .contacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            switch selectedSubTab {
            case .contacts:   ContactsListSubView()
            case .aiScan:     WhitelistScanView()
            case .blockRules: BlockRulesSubView()
            case .silenced:   SilencedChatsSubView()
            }
        }
    }
}

// MARK: - Contacts List

private enum ContactLevelFilter: String, CaseIterable {
    case all = "全部"
    case vip = "VIP"
    case whitelist = "白名单"
    case greylist = "灰名单"

    var level: AttentionLevel? {
        switch self {
        case .all: return nil
        case .vip: return .vip
        case .whitelist: return .whitelist
        case .greylist: return .greylist
        }
    }
}

private struct ContactsListSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var selectedFilter: ContactLevelFilter = .all
    @State private var selectedContactID: String?
    @State private var editingContact: ContactEntry?
    @State private var showAddPopover = false
    @State private var addSearchText = ""
    @State private var didLoad = false

    private var filtered: [ContactEntry] {
        contacts.filter { contact in
            let matchesLevel = selectedFilter.level.map { contact.attentionLevel == $0 } ?? true
            let matchesSearch = searchText.isEmpty
                || contact.displayName.localizedCaseInsensitiveContains(searchText)
                || contact.username.localizedCaseInsensitiveContains(searchText)
                || contact.role.label.localizedCaseInsensitiveContains(searchText)
                || contact.roleNote.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
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
                // Native search field style
                TextField("搜索联系人…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 200)

                Picker("", selection: $selectedFilter) {
                    ForEach(ContactLevelFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: selectedFilter) {
                    if let selectedContactID,
                       !filtered.contains(where: { $0.username == selectedContactID }) {
                        self.selectedContactID = filtered.first?.username
                    }
                }

                Spacer()

                statsChips
                if let status = monitor.contactInferenceStatus {
                    aiJobChip(status)
                }

                Button {
                    monitor.startContactInference(contacts: contacts)
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(monitor.contactInferenceStatus?.isRunning == true)
                .help("后台批量推断关系画像")

                if monitor.contactInferenceStatus?.isRunning == true {
                    Button {
                        monitor.cancelContactInference()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("停止后台分析")
                }

                Button {
                    addSearchText = ""
                    showAddPopover = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
                    addContactPopover
                }
            }

            HSplitView {
                List {
                    if filtered.isEmpty {
                        emptyState(icon: "person.crop.circle.badge.questionmark", text: "没有匹配联系人", hint: "换个关键词或级别筛选")
                            .listRowSeparator(.hidden)
                    } else {
                        contactGroup(level: .vip, title: "VIP", color: .yellow)
                        contactGroup(level: .whitelist, title: "白名单", color: .blue)
                        contactGroup(level: .greylist, title: "灰名单", color: .gray)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minWidth: 360, idealWidth: 430, maxWidth: 560, maxHeight: .infinity)

                ContactInspectorView(
                    contact: selectedContact,
                    whitelistEntry: selectedContact.flatMap { store.getWhitelistEntry(username: $0.username) },
                    profile: selectedContact.flatMap { store.getRelationshipProfile(username: $0.username) },
                    inferenceStatus: monitor.contactInferenceStatus,
                    onEdit: { editingContact = $0 },
                    onInfer: { monitor.startContactInference(contacts: [$0]) },
                    onChangeLevel: { contact, level in
                        saveContact(contact, level: level)
                        reload()
                    },
                    onDelete: { contact in
                        try? store.deleteContactAndTracking(username: contact.username)
                        selectedContactID = nil
                        reload()
                    }
                )
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(contact: contact, store: store, monitor: monitor, onSave: { reload() })
        }
    }

    // MARK: - Stats chips

    private var statsChips: some View {
        let vip   = contacts.filter { $0.attentionLevel == .vip }.count
        let wl    = contacts.filter { $0.attentionLevel == .whitelist }.count
        let grey  = contacts.filter { $0.attentionLevel == .greylist }.count
        return HStack(spacing: 6) {
            chip("VIP", count: vip, color: .yellow)
            chip("白名单", count: wl, color: .blue)
            chip("灰名单", count: grey, color: .gray)
        }
    }

    private func chip(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .help("\(count) \(label)")
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
        .help(status.isRunning ? "AI 正在后台生成关系画像，可继续操作联系人" : "上次后台分析结果")
    }

    // MARK: - Add contact popover

    private var addContactPopover: some View {
        let wechatContacts = monitor.wechatContacts()
        let existingSet = Set(contacts.map(\.username))
        let available = wechatContacts
            .filter { !existingSet.contains($0.key) }
            .filter { !$0.key.hasPrefix("gh_") && $0.key != "filehelper" && !$0.key.contains("@chatroom") }
            .filter {
                addSearchText.isEmpty
                || $0.value.localizedCaseInsensitiveContains(addSearchText)
                || $0.key.localizedCaseInsensitiveContains(addSearchText)
            }
            .sorted { $0.value.localizedCompare($1.value) == .orderedAscending }

        return VStack(spacing: 0) {
            HStack {
                Text("添加联系人").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(available.count) 可添加").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            TextField("搜索微信联系人…", text: $addSearchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .padding(.horizontal, 12).padding(.bottom, 6)

            Divider()

            if available.isEmpty {
                Text(addSearchText.isEmpty ? "无可添加的联系人" : "无匹配结果")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(available.prefix(50)), id: \.key) { username, name in
                            Button {
                                try? store.saveContactTracking(
                                    username: username,
                                    displayName: name,
                                    isGroup: false,
                                    category: .work,
                                    attentionLevel: .whitelist,
                                    role: .colleague,
                                    roleNote: "",
                                    replyWindowMinutes: ContactRole.colleague.defaultReplyWindowMinutes
                                )
                                reload()
                                showAddPopover = false
                            } label: {
                                HStack(spacing: 8) {
                                    Text(name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(username.prefix(16))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 300)
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
                Text(contact.role.icon).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName).font(.system(size: 12)).foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(contact.role.label)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.12)).cornerRadius(3)
                if contact.replyWindowMinutes > 0 {
                    Text("\(contact.replyWindowMinutes)m")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑") {
                editingContact = contact
            }
            Divider()
            Menu("变更级别") {
                ForEach([AttentionLevel.vip, .whitelist, .greylist], id: \.self) { level in
                    if level != contact.attentionLevel {
                        Button(level.label) {
                            saveContact(contact, level: level)
                            reload()
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                try? store.deleteContactAndTracking(username: contact.username)
                reload()
            }
        }
    }

    private func saveContact(_ contact: ContactEntry, level: AttentionLevel) {
        let whitelistEntry = store.getWhitelistEntry(username: contact.username)
        try? store.saveContactTracking(
            username: contact.username,
            displayName: contact.displayName,
            isGroup: whitelistEntry?.isGroup ?? contact.username.contains("@chatroom"),
            category: whitelistEntry?.category ?? whitelistCategory(for: contact.role),
            attentionLevel: level,
            role: contact.role,
            roleNote: contact.roleNote,
            replyWindowMinutes: contact.replyWindowMinutes
        )
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
                emptyState(icon: "person.text.rectangle", text: "选择一个联系人", hint: "查看追踪状态、关系画像和回复策略")
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private func header(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(contact.role.icon)
                    .font(.system(size: 28))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(contact.username)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                levelBadge(contact.attentionLevel)
            }

            if !contact.roleNote.isEmpty {
                Text(contact.roleNote)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func trackingSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("追踪策略", systemImage: "scope")
            infoRow("状态", value: whitelistEntry == nil ? "不进入扫描队列" : "进入扫描队列")
            infoRow("分类", value: whitelistEntry?.category.label ?? whitelistCategory(for: contact.role).label)
            infoRow("回复窗口", value: contact.replyWindowMinutes > 0 ? "\(contact.replyWindowMinutes) 分钟" : "不追踪回复债务")
            infoRow("角色", value: contact.role.label)
            Text(trackingReason(contact))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aiProfileSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("AI 关系画像", systemImage: "sparkles")
                Spacer()
                Button {
                    onInfer(contact)
                } label: {
                    if inferenceStatus?.isRunning == true {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                Text("还没有画像。点击右上角按钮后会在后台分析，不影响继续操作。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func operationsSection(_ contact: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("操作", systemImage: "slider.horizontal.3")
            Picker("", selection: Binding(
                get: { contact.attentionLevel },
                set: { onChangeLevel(contact, $0) }
            )) {
                Text("VIP").tag(AttentionLevel.vip)
                Text("白名单").tag(AttentionLevel.whitelist)
                Text("灰名单").tag(AttentionLevel.greylist)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button("编辑详情") { onEdit(contact) }
                    .controlSize(.small)
                Button("删除", role: .destructive) { onDelete(contact) }
                    .controlSize(.small)
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
        Text(level.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(levelColor(level))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(levelColor(level).opacity(0.12))
            .cornerRadius(5)
    }

    private func levelColor(_ level: AttentionLevel) -> Color {
        switch level {
        case .vip: return .yellow
        case .whitelist: return .blue
        case .greylist: return .gray
        case .stranger: return .secondary
        }
    }

    private func trackingReason(_ contact: ContactEntry) -> String {
        switch contact.attentionLevel {
        case .vip:
            return "高优先级联系人，会参与未读提醒、回复债务、VIP 洞察和主动提醒。"
        case .whitelist:
            return "常规关注联系人，会参与未读整理、回复建议和上下文分析。"
        case .greylist:
            return "保留关系画像，但不进入扫描队列，适合低频或暂时不想被打扰的人。"
        case .stranger:
            return "未纳入托管策略。"
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
                emptyState(icon: "speaker.slash", text: "没有静音的对话", hint: "在收件箱中长按可静音对话")
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

    init(contact: ContactEntry, store: HUDStore, monitor: ChatMonitor, onSave: @escaping () -> Void) {
        self.contact = contact
        self.store = store
        self.monitor = monitor
        self.onSave = onSave
        _selectedLevel = State(initialValue: contact.attentionLevel)
        _selectedRole  = State(initialValue: contact.role)
        _roleNote      = State(initialValue: contact.roleNote)
        _replyWindow   = State(initialValue: contact.replyWindowMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Text(contact.role.icon).font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.displayName).font(.system(size: 14, weight: .semibold))
                        Text(contact.username)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("关注设置") {
                    Picker("级别", selection: $selectedLevel) {
                        Text("VIP").tag(AttentionLevel.vip)
                        Text("白名单").tag(AttentionLevel.whitelist)
                        Text("灰名单").tag(AttentionLevel.greylist)
                    }
                    .onChange(of: selectedLevel) {
                        let roles = rolesForLevel(selectedLevel)
                        if !roles.contains(selectedRole) {
                            selectedRole = roles.first ?? selectedRole
                            replyWindow = selectedRole.defaultReplyWindowMinutes
                        }
                    }

                    Picker("角色", selection: $selectedRole) {
                        ForEach(rolesForLevel(selectedLevel), id: \.self) { role in
                            Text("\(role.icon) \(role.label)").tag(role)
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
                        Stepper("回复窗口", value: $replyWindow, in: 0...480, step: 15)
                        Text("\(replyWindow) 分钟")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text("默认 \(selectedRole.defaultReplyWindowMinutes) 分钟 · 设为 0 不追踪")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("AI 关系画像") {
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
                            Text("尚未生成关系画像")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button(isInferring ? "推断中…" : "开始推断") { runInference() }
                                .controlSize(.small)
                                .disabled(isInferring)
                        }
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

    private func runInference() {
        isInferring = true
        Task {
            let result = await monitor.inferRelationship(
                contactUsername: contact.username,
                contactName: contact.displayName
            )
            isInferring = false
            if result != nil { loadRelProfile() }
        }
    }

    private func save() {
        let whitelistEntry = store.getWhitelistEntry(username: contact.username)
        try? store.saveContactTracking(
            username: contact.username,
            displayName: contact.displayName,
            isGroup: whitelistEntry?.isGroup ?? contact.username.contains("@chatroom"),
            category: whitelistEntry?.category ?? whitelistCategory(for: selectedRole),
            attentionLevel: selectedLevel,
            role: selectedRole,
            roleNote: roleNote,
            replyWindowMinutes: replyWindow
        )
        if relProfile != nil {
            try? store.updateRelationshipProfileUserFields(
                username: contact.username,
                relationship: relRelationship,
                hierarchy: relHierarchy,
                tonePreference: relTone,
                userNote: relNote.isEmpty ? nil : relNote
            )
        }
        onSave()
        dismiss()
    }

    private static let relationshipOptions = [
        "直属领导", "上级领导", "同事", "下属", "客户", "供应商",
        "合作方", "家人", "朋友", "同学", "其他"
    ]

    private func rolesForLevel(_ level: AttentionLevel) -> [ContactRole] {
        switch level {
        case .vip:       return [.boss, .keyClient, .family, .partner]
        case .whitelist: return [.colleague, .client, .friend, .supplier]
        case .greylist:  return [.acquaintance, .groupOnly, .service]
        case .stranger:  return []
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
