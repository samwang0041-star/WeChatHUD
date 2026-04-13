import SwiftUI

struct ContactsSettingsView: View {
    enum SubTab: String, CaseIterable {
        case contacts = "通讯录"
        case aiScan = "AI 扫描"
        case blockRules = "屏蔽规则"
    }

    @State private var selectedSubTab: SubTab = .contacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            switch selectedSubTab {
            case .contacts: ContactsListSubView()
            case .aiScan: WhitelistScanView()
            case .blockRules: BlockRulesSubView()
            }
        }
    }
}

// MARK: - Contacts List

private struct ContactsListSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var editingContact: ContactEntry?
    @State private var showAddSheet = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary).font(.system(size: 12))
                    TextField("搜索联系人", text: $searchText)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                }
                Button { showAddSheet = true } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }

            if !contacts.isEmpty { statsBar }

            List {
                contactSection(level: .vip, title: "VIP", color: .yellow)
                contactSection(level: .whitelist, title: "白名单", color: .blue)
                contactSection(level: .greylist, title: "灰名单", color: .gray)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(contact: contact, store: store, onSave: { reload() })
        }
        .sheet(isPresented: $showAddSheet) {
            Text("添加联系人（待实现）").padding(32)
        }
    }

    private var statsBar: some View {
        let vipCount   = contacts.filter { $0.attentionLevel == .vip }.count
        let whiteCount = contacts.filter { $0.attentionLevel == .whitelist }.count
        let greyCount  = contacts.filter { $0.attentionLevel == .greylist }.count
        return HStack(spacing: 12) {
            statPill("VIP", count: vipCount, color: .yellow)
            statPill("白名单", count: whiteCount, color: .blue)
            statPill("灰名单", count: greyCount, color: .gray)
            Spacer()
            Text("共 \(contacts.count) 人").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func statPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func contactSection(level: AttentionLevel, title: String, color: Color) -> some View {
        let filtered = contacts
            .filter { $0.attentionLevel == level }
            .filter {
                searchText.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.role.label.localizedCaseInsensitiveContains(searchText)
            }
        if !filtered.isEmpty {
            Section {
                ForEach(filtered) { contact in contactRow(contact, levelColor: color) }
            } header: {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.primary)
                    Text("(\(filtered.count))").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func contactRow(_ contact: ContactEntry, levelColor: Color) -> some View {
        Button(action: { editingContact = contact }) {
            HStack(spacing: 8) {
                Text(contact.role.icon).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName).font(.system(size: 12)).foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote).font(.system(size: 10))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(contact.role.label)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(levelColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(levelColor.opacity(0.12)).cornerRadius(3)
                if contact.replyWindowMinutes > 0 {
                    Text("\(contact.replyWindowMinutes)m").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("变更级别") {
                ForEach([AttentionLevel.vip, .whitelist, .greylist], id: \.self) { level in
                    if level != contact.attentionLevel {
                        Button(level.label) {
                            try? store.updateContactLevel(username: contact.username, level: level, role: contact.role)
                            reload()
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                try? store.deleteContact(username: contact.username)
                reload()
            }
        }
    }

    private func reload() { contacts = store.loadContacts(level: nil) }
}

// MARK: - Block Rules

private struct BlockRulesSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var ignoredSenders: [IgnoredSenderRule] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通过消息右键菜单添加的忽略规则。被忽略的人不会进入未读统计。")
                .font(.system(size: 11)).foregroundColor(.secondary)

            if ignoredSenders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 28)).foregroundColor(.secondary.opacity(0.4))
                    Text("没有忽略的发送人")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(ignoredSenders) { rule in ignoredSenderRow(rule) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { if !didLoad { reload(); didLoad = true } }
    }

    private func ignoredSenderRow(_ rule: IgnoredSenderRule) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.senderName).font(.system(size: 12, weight: .semibold))
                    Text(rule.chatName).font(.system(size: 11))
                        .foregroundColor(.secondary).lineLimit(1)
                }
                if !rule.senderUsername.isEmpty {
                    Text(rule.senderUsername).font(.system(size: 10))
                        .foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("取消忽略") {
                monitor.unignoreSender(chatUsername: rule.chatUsername,
                                       senderUsername: rule.senderUsername,
                                       senderName: rule.senderName)
                reload()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func reload() { ignoredSenders = store.loadIgnoredSenders() }
}

// MARK: - Edit Sheet

struct ContactEditSheet: View {
    let contact: ContactEntry
    let store: HUDStore
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

    init(contact: ContactEntry, store: HUDStore, onSave: @escaping () -> Void) {
        self.contact = contact
        self.store = store
        self.onSave = onSave
        _selectedLevel = State(initialValue: contact.attentionLevel)
        _selectedRole  = State(initialValue: contact.role)
        _roleNote      = State(initialValue: contact.roleNote)
        _replyWindow   = State(initialValue: contact.replyWindowMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑联系人").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
                Button("保存") { save() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding()
            Divider()
            Form {
                Section("基本信息") {
                    LabeledContent("名称") {
                        HStack(spacing: 6) { Text(contact.role.icon); Text(contact.displayName) }
                    }
                    LabeledContent("用户名") {
                        Text(contact.username).foregroundColor(.secondary)
                    }
                }
                Section("关注设置") {
                    Picker("关注级别", selection: $selectedLevel) {
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
                    Picker("身份角色", selection: $selectedRole) {
                        ForEach(rolesForLevel(selectedLevel), id: \.self) { role in
                            Text("\(role.icon) \(role.label)").tag(role)
                        }
                    }
                    .onChange(of: selectedRole) { replyWindow = selectedRole.defaultReplyWindowMinutes }
                    TextField("备注", text: $roleNote).textFieldStyle(.roundedBorder)
                }
                Section("回复追踪") {
                    HStack(spacing: 8) {
                        TextField("回复窗口（分钟）", value: $replyWindow, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                        Text("默认 \(selectedRole.defaultReplyWindowMinutes) 分钟，0 = 不追踪")
                            .foregroundColor(.secondary).font(.caption)
                    }
                }
                Section("AI 关系画像") {
                    if let profile = relProfile {
                        LabeledContent("关系") {
                            TextField("", text: $relRelationship)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                        Picker("层级", selection: $relHierarchy) {
                            ForEach(RelationshipProfile.Hierarchy.allCases, id: \.self) { h in
                                Text(h.label).tag(h)
                            }
                        }
                        Picker("沟通风格", selection: $relTone) {
                            ForEach(RelationshipProfile.TonePreference.allCases, id: \.self) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        LabeledContent("备注") {
                            TextField("", text: $relNote)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                        HStack(spacing: 8) {
                            Text("置信度: \(Int(profile.confidence * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("重新推断") { }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("尚未推断").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("开始推断") { }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }
                Section { Text(selectedRole.roleDescription).font(.caption).foregroundColor(.secondary) }
                    header: { Text("角色说明") }
            }
            .formStyle(.grouped)
            .onAppear {
                relProfile = store.getRelationshipProfile(username: contact.username)
                if let p = relProfile {
                    relRelationship = p.relationship
                    relHierarchy = p.hierarchy
                    relTone = p.tonePreference
                    relNote = p.userNote ?? ""
                }
            }
        }
        .frame(width: 420, height: 580)
    }

    private func save() {
        try? store.upsertContact(username: contact.username, displayName: contact.displayName,
                                  attentionLevel: selectedLevel, role: selectedRole,
                                  roleNote: roleNote, replyWindowMinutes: replyWindow)
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

    private func rolesForLevel(_ level: AttentionLevel) -> [ContactRole] {
        switch level {
        case .vip:       return [.boss, .keyClient, .family, .partner]
        case .whitelist: return [.colleague, .client, .friend, .supplier]
        case .greylist:  return [.acquaintance, .groupOnly, .service]
        case .stranger:  return []
        }
    }
}
