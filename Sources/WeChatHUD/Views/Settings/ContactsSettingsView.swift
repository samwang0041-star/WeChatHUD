import SwiftUI

/// Four-tier contact manager: VIP → 白名单 → 灰名单 → (陌生人折叠)
/// Replaces the old WhitelistSettingsView with role-aware contact management.
struct ContactsSettingsView: View {
    @EnvironmentObject private var store: HUDStore

    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var editingContact: ContactEntry?
    @State private var showAddSheet = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("搜索联系人...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )

            // Stats bar
            if !contacts.isEmpty {
                statsBar
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contactSection(level: .vip, title: "VIP", color: .yellow)
                    contactSection(level: .whitelist, title: "白名单", color: .blue)
                    contactSection(level: .greylist, title: "灰名单", color: .gray)

                    Divider()
                        .padding(.vertical, 4)

                    WhitelistScanView()
                }
            }
        }
        .onAppear {
            if !didLoad {
                reload()
                didLoad = true
            }
        }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(contact: contact, store: store, onSave: { reload() })
        }
    }

    // MARK: - Stats

    private var statsBar: some View {
        let vipCount = contacts.filter { $0.attentionLevel == .vip }.count
        let whiteCount = contacts.filter { $0.attentionLevel == .whitelist }.count
        let greyCount = contacts.filter { $0.attentionLevel == .greylist }.count
        return HStack(spacing: 12) {
            statPill("VIP", count: vipCount, color: .yellow)
            statPill("白名单", count: whiteCount, color: .blue)
            statPill("灰名单", count: greyCount, color: .gray)
            Spacer()
            Text("共 \(contacts.count) 人")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func statPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Section

    private func contactSection(level: AttentionLevel, title: String, color: Color) -> some View {
        let filtered = contacts.filter { $0.attentionLevel == level }
            .filter { searchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.role.label.contains(searchText) }
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("(\(filtered.count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 2) {
                    ForEach(filtered) { contact in
                        contactRow(contact, levelColor: color)
                    }
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        )
    }

    private func contactRow(_ contact: ContactEntry, levelColor: Color) -> some View {
        Button(action: { editingContact = contact }) {
            HStack(spacing: 8) {
                // Role icon
                Text(contact.role.icon)
                    .font(.system(size: 14))

                // Name
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Role badge
                Text(contact.role.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(levelColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.12))
                    .cornerRadius(3)

                // Reply window
                if contact.replyWindowMinutes > 0 {
                    Text("\(contact.replyWindowMinutes)m")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
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

    private func reload() {
        contacts = store.loadContacts(level: nil)
    }
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

    init(contact: ContactEntry, store: HUDStore, onSave: @escaping () -> Void) {
        self.contact = contact
        self.store = store
        self.onSave = onSave
        _selectedLevel = State(initialValue: contact.attentionLevel)
        _selectedRole = State(initialValue: contact.role)
        _roleNote = State(initialValue: contact.roleNote)
        _replyWindow = State(initialValue: contact.replyWindowMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(contact.role.icon)
                    .font(.system(size: 24))
                VStack(alignment: .leading) {
                    Text(contact.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(contact.username)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Level picker
            VStack(alignment: .leading, spacing: 4) {
                Text("关注级别")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: $selectedLevel) {
                    Text("VIP").tag(AttentionLevel.vip)
                    Text("白名单").tag(AttentionLevel.whitelist)
                    Text("灰名单").tag(AttentionLevel.greylist)
                }
                .pickerStyle(.segmented)
            }

            // Role picker
            VStack(alignment: .leading, spacing: 4) {
                Text("身份角色")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 4) {
                    ForEach(rolesForLevel(selectedLevel), id: \.self) { role in
                        Button(action: {
                            selectedRole = role
                            replyWindow = role.defaultReplyWindowMinutes
                        }) {
                            HStack(spacing: 3) {
                                Text(role.icon)
                                    .font(.system(size: 10))
                                Text(role.label)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selectedRole == role ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
            }

            // Role description
            Text(selectedRole.roleDescription)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)

            // Role note
            VStack(alignment: .leading, spacing: 4) {
                Text("备注")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("如：负责华东区的大客户经理", text: $roleNote)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            // Reply window
            VStack(alignment: .leading, spacing: 4) {
                Text("回复窗口（分钟，0 = 不追踪）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                HStack {
                    TextField("", value: $replyWindow, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 80)
                    Text("默认 \(selectedRole.defaultReplyWindowMinutes)m")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Actions
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Button("保存") {
                    try? store.upsertContact(
                        username: contact.username,
                        displayName: contact.displayName,
                        attentionLevel: selectedLevel,
                        role: selectedRole,
                        roleNote: roleNote,
                        replyWindowMinutes: replyWindow
                    )
                    onSave()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .fontWeight(.medium)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func rolesForLevel(_ level: AttentionLevel) -> [ContactRole] {
        switch level {
        case .vip: return [.boss, .keyClient, .family, .partner]
        case .whitelist: return [.colleague, .client, .friend, .supplier]
        case .greylist: return [.acquaintance, .groupOnly, .service]
        case .stranger: return []
        }
    }
}
