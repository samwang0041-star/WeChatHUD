import SwiftUI

/// The single place that answers "谁的消息会提醒我".
///
/// Before this screen the answer was spread across 关注谁 / 不看谁 / 提醒方式,
/// and the inbox did not actually obey any of them — it listed every unread
/// conversation while the notification path only ever saw followed chats. The
/// screen is organised the way the question is actually asked: how wide is the
/// net, who is singled out inside a group, whose @s stay quiet, and who is
/// muted outright.
struct AdmissionSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var reader: WeChatReader
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var config = AdmissionConfig()
    @State private var followed: [WhitelistEntry] = []
    @State private var memberRules: [GroupMemberRule] = []
    @State private var globalMuted: [IgnoredSenderRule] = []
    @State private var loaded = false
    @State private var error: String?
    /// Set when the stored 托管规则 could not be read at all (`.unreadable`) or
    /// could not be decoded (`.corrupt`). Both freeze the form: `save()` writes the
    /// whole config back, so an edit landing on top of a defaulted read destroys
    /// what is stored.
    @State private var loadError: String?
    @State private var loadIsCorrupt = false

    @State private var picker: PickerTarget?

    /// Fixed inputs for previews and offscreen rendering, so the populated
    /// layout can be inspected without running a scan.
    struct Snapshot {
        var config = AdmissionConfig()
        var followed: [WhitelistEntry] = []
        var memberRules: [GroupMemberRule] = []
        var globalMuted: [IgnoredSenderRule] = []
    }

    init() {}

    init(snapshot: Snapshot) {
        _config = State(initialValue: snapshot.config)
        _followed = State(initialValue: snapshot.followed)
        _memberRules = State(initialValue: snapshot.memberRules)
        _globalMuted = State(initialValue: snapshot.globalMuted)
        _loaded = State(initialValue: true)
    }

    /// Which add-sheet is open. A single enum keeps the presentation modifiers
    /// to one, so SwiftUI cannot end up stacking two sheets.
    enum PickerTarget: Identifiable {
        case groupMember
        case mutedPerson
        case quietGroup

        var id: String {
            switch self {
            case .groupMember: return "groupMember"
            case .mutedPerson: return "mutedPerson"
            case .quietGroup: return "quietGroup"
            }
        }
    }

    private var followedGroups: [WhitelistEntry] {
        followed.filter(\.isGroup)
    }

    private var atMutedCount: Int {
        config.atMutedGroups.filter { id in followedGroups.contains { $0.id == id } }.count
    }

    var body: some View {
        ScrollView {
            content
        }
        .onAppear(perform: reload)
        .sheet(item: $picker) { target in
            switch target {
            case .groupMember:
                GroupMemberPickerSheet(
                    groups: followedGroups,
                    reader: reader,
                    store: store,
                    existing: memberRules,
                    onAdd: { chat, chatName, sender, senderName in
                        do {
                            try store.addGroupMemberRule(
                                chatUsername: chat,
                                chatName: chatName,
                                senderUsername: sender,
                                senderName: senderName
                            )
                            reload()
                            monitor.refreshNow()
                        } catch {
                            self.error = "没能保存，请重试。"
                        }
                    }
                )
            case .mutedPerson:
                MutedPersonPickerSheet(
                    store: store,
                    existing: globalMuted,
                    onAdd: { username, name in
                        do {
                            try store.ignoreSenderEverywhere(
                                senderUsername: username,
                                senderName: name
                            )
                            reload()
                            monitor.refreshNow()
                        } catch {
                            self.error = "没能保存，请重试。"
                        }
                    }
                )
            case .quietGroup:
                QuietGroupPickerSheet(
                    groups: addableQuietGroups,
                    onPick: { group in
                        config.atMutedGroups.insert(group.id)
                        save()
                    }
                )
            }
        }
    }

    /// The sections without the scrolling shell.
    ///
    /// Separate so the layout can be drawn offscreen for inspection:
    /// `ImageRenderer` renders a `ScrollView` as a blank image, which would
    /// silently defeat any screenshot check of the full screen.
    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            Group {
                modeSection
                watchedMemberSection
                atMentionSection
                mutedSection
            }
            .disabled(loadError != nil)
            .opacity(loadError == nil ? 1 : 0.55)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                HStack(spacing: 10) {
                    Button("重新读取规则") { reload() }
                        .controlSize(.small)
                    if loadIsCorrupt {
                        Button("用默认规则覆盖并重载（丢弃「群 @ 静默」名单）") { rebuildFromDefaults() }
                            .controlSize(.small)
                    }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary

    /// One sentence the user can check at a glance, instead of inferring the
    /// rules from four separate lists.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("现在的规则")
                .font(.system(size: 13, weight: .semibold))
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.jade.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CompanionPalette.jade.opacity(0.2))
        )
    }

    private var summaryText: String {
        if loadError != nil {
            // The sentence below is derived from `config`, which on a failed read
            // is a constructed default — printed as 「现在的规则」 that states a
            // rule the user never set.
            return "暂时读不到当前的规则，下面的开关先不接受改动。"
        }
        var parts: [String] = [config.mode == .whitelistOnly ? "只提醒关注的人" : "全部未读都提醒"]
        parts.append("关注 \(followed.count) 个对话")
        if !memberRules.isEmpty {
            parts.append("\(Set(memberRules.map(\.chatUsername)).count) 个群设了重点成员")
        }
        if !globalMuted.isEmpty {
            parts.append("\(globalMuted.count) 人不提醒")
        }
        if atMutedCount > 0 {
            parts.append("\(atMutedCount) 个群不弹 @")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Mode

    private var modeSection: some View {
        SettingsSection("提醒范围") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AdmissionMode.allCases, id: \.self) { mode in
                    Button {
                        config.mode = mode
                        save()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: config.mode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(config.mode == mode ? CompanionPalette.jadeInk : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(mode.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if mode != AdmissionMode.allCases.last { SettingsRowDivider() }
                }
            }
        }
    }

    // MARK: - Watched members

    private var watchedMemberSection: some View {
        SettingsSection("群里的重点成员") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    "他们说话就提醒我",
                    subtitle: "群里人多话杂。指定几个人，他们一开口就提醒你，不用等 @。",
                    icon: "person.badge.shield.checkmark",
                    iconColor: CompanionPalette.jade
                ) {
                    Button("添加") { picker = .groupMember }
                        .controlSize(.small)
                }

                if memberRules.isEmpty {
                    SettingsRowDivider()
                    Text("还没有设置。适合用在「群里只有两三个人值得看」的场合。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(groupedMemberRules, id: \.group) { group in
                        SettingsRowDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.group)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.rules) { rule in
                                HStack(spacing: 8) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(CompanionPalette.jadeInk)
                                    Text(rule.senderName)
                                        .font(.system(size: 13))
                                    Spacer(minLength: 4)
                                    Button("移除") {
                                        try? store.removeGroupMemberRule(
                                            chatUsername: rule.chatUsername,
                                            senderUsername: rule.senderUsername
                                        )
                                        reload()
                                        monitor.refreshNow()
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private struct MemberRuleGroup: Identifiable {
        let group: String
        let rules: [GroupMemberRule]
        var id: String { group }
    }

    private var groupedMemberRules: [MemberRuleGroup] {
        let byGroup = Dictionary(grouping: memberRules, by: \.chatName)
        return byGroup
            .map { MemberRuleGroup(group: $0.key, rules: $0.value.sorted { $0.senderName < $1.senderName }) }
            .sorted { $0.group < $1.group }
    }

    // MARK: - @ mentions

    private var atMentionSection: some View {
        SettingsSection("群 @ 提醒") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    "@ 我的消息会弹出来",
                    subtitle: "有群太吵就加到这里。关掉后 @ 你的消息仍会进收件箱，只是不弹出来，不会丢。",
                    icon: "bell.badge",
                    iconColor: CompanionPalette.jade
                ) {
                    Button("添加") { picker = .quietGroup }
                        .controlSize(.small)
                        .disabled(addableQuietGroups.isEmpty)
                }

                if followedGroups.isEmpty {
                    SettingsRowDivider()
                    Text("还没有关注的群。先在「关注的人」里添加群。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if quietGroups.isEmpty {
                    SettingsRowDivider()
                    Text("所有关注的群，@ 你时都会弹出来。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(quietGroups, id: \.id) { group in
                        SettingsRowDivider()
                        SettingsRow(group.displayName) {
                            Button("恢复弹出") {
                                config.atMutedGroups.remove(group.id)
                                save()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// Groups the user silenced for @.
    ///
    /// Listing only the muted ones — rather than every followed group as a row
    /// of switches — keeps the screen usable for someone who follows dozens of
    /// rooms, and matches how the other sections read: a short list plus an
    /// explicit way to add.
    private var quietGroups: [WhitelistEntry] {
        followedGroups.filter { config.atMutedGroups.contains($0.id) }
    }

    /// Followed groups that are still allowed to interrupt.
    ///
    /// The 添加 button disables on this, not on `quietGroups`: what matters is
    /// whether anything is left to add, and using the muted list would disable
    /// the button exactly when there was still work to do.
    private var addableQuietGroups: [WhitelistEntry] {
        followedGroups.filter { !config.atMutedGroups.contains($0.id) }
    }

    // MARK: - Muted people

    private var mutedSection: some View {
        SettingsSection("不提醒我的人") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    "在哪个对话都不提醒",
                    subtitle: "适合不想再被打扰的人。要只看某个群里的某人，用「不看谁」。",
                    icon: "person.slash",
                    iconColor: .red.opacity(0.6)
                ) {
                    Button("添加") { picker = .mutedPerson }
                        .controlSize(.small)
                }
                if globalMuted.isEmpty {
                    SettingsRowDivider()
                    Text("还没有拉黑任何人。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(globalMuted, id: \.id) { rule in
                        SettingsRowDivider()
                        SettingsRow(rule.senderName, subtitle: rule.senderUsername) {
                            Button("恢复") {
                                try? store.unignoreSender(
                                    chatUsername: HUDStore.globalIgnoreScopeKey,
                                    senderUsername: rule.senderUsername,
                                    senderName: rule.senderName
                                )
                                reload()
                                monitor.refreshNow()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func reload() {
        // The whole config is written back by `save()`, so a read that failed has
        // to stop the write rather than hydrate the page from defaults: that used
        // to paint 「只提醒关注的人」 on a broken read and push it to disk on the
        // next tap, which silently un-mutes every 群 @ 静默 the user had set.
        switch LoadDecision(store.admissionConfigRead()) {
        case .hydrate(let stored):
            config = stored
            loadError = nil
            loadIsCorrupt = false
            loaded = true
        case .frozen(let notice, let needsExplicitOverwrite):
            loadError = notice
            loadIsCorrupt = needsExplicitOverwrite
            loaded = false
        }
        followed = store.getWhitelist()
        memberRules = store.loadGroupMemberRules()
        globalMuted = store.loadIgnoredSenders().filter { $0.scope == .global }
    }

    /// What one read of the stored rules costs this page. One place decides, and
    /// both halves consume it: `reload()` freezes the form on it and `save()`
    /// refuses to write on it, so the classification cannot drift away from the
    /// gate that protects the stored 群 @ 静默 list.
    enum LoadDecision: Equatable {
        case hydrate(AdmissionConfig)
        case frozen(notice: String, needsExplicitOverwrite: Bool)

        init(_ read: HUDStore.SettingRead<AdmissionConfig>) {
            switch read {
            case .value(let stored):
                self = .hydrate(stored)
            case .absent:
                // Nothing stored yet: defaults here are the starting point, not a
                // loss, so the page may write.
                self = .hydrate(AdmissionConfig())
            case .unreadable:
                self = .frozen(
                    notice: "读不到当前的提醒规则，这一页暂时不接受改动。请点「重新读取规则」再试一次。",
                    needsExplicitOverwrite: false)
            case .corrupt:
                self = .frozen(
                    notice: "提醒规则的内容读不懂（可能被上次写入打断）。这一页暂时不接受改动；要重新用规则，只能显式覆盖成默认值（会丢弃现有的「群 @ 静默」名单）。",
                    needsExplicitOverwrite: true)
            }
        }

        var acceptsEdits: Bool {
            if case .hydrate = self { return true }
            return false
        }
    }

    /// The one write the page keeps while its read is failing: `.corrupt` has no
    /// other way out, since the stored blob cannot be merged into. Deliberately a
    /// named button — it throws away the 群 @ 静默 list.
    private func rebuildFromDefaults() {
        guard (try? store.saveAdmissionConfig(AdmissionConfig())) != nil else {
            error = "默认规则也没写进去：数据库可能正被占用。请稍后再试一次。"
            return
        }
        reload()
    }

    private func save() {
        guard loaded, loadError == nil else { return }
        do {
            try store.saveAdmissionConfig(config)
            error = nil
            monitor.refreshNow()
        } catch {
            self.error = "设置没保存成功，请重试。"
        }
    }
}

// MARK: - Group member picker

/// Pick a group, then pick the people in it worth hearing from.
///
/// Two steps rather than one long list: the member list only makes sense in the
/// context of a group, and the group is what the rule is attached to.
private struct GroupMemberPickerSheet: View {
    let groups: [WhitelistEntry]
    let reader: WeChatReader
    let store: HUDStore
    let existing: [GroupMemberRule]
    let onAdd: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroup: WhitelistEntry?
    @State private var search = ""

    private var members: [(username: String, name: String)] {
        guard let selectedGroup else { return [] }
        let contacts = store.loadContacts()
        // contacts has no unique constraint (multi-account residue can leave
        // two rows with the same username); uniqueKeysWithValues traps on
        // duplicates, so keep the first display name instead of crashing.
        let byUsername = Dictionary(contacts.map { ($0.username, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return reader.groupMemberNames(for: selectedGroup.id)
            .map { (username: $0, name: byUsername[$0] ?? $0) }
            .sorted { $0.name < $1.name }
    }

    private var filteredMembers: [(username: String, name: String)] {
        guard !search.isEmpty else { return members }
        return members.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.username.localizedCaseInsensitiveContains(search)
        }
    }

    private func alreadyAdded(_ username: String) -> Bool {
        guard let selectedGroup else { return false }
        return existing.contains {
            $0.chatUsername == selectedGroup.id && $0.senderUsername == username
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedGroup == nil ? "先选一个群" : "选群里要提醒你的人")
                .font(.system(size: 15, weight: .semibold))
            if selectedGroup != nil {
                TextField("搜索群成员", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let selectedGroup {
                        if members.isEmpty {
                            Text("这个群的成员名单还没读到。微信需要先同步过这个群的消息。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(filteredMembers, id: \.username) { member in
                            HStack(spacing: 8) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(member.name).font(.system(size: 13))
                                Spacer(minLength: 4)
                                if alreadyAdded(member.username) {
                                    Text("已添加")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("添加") {
                                        onAdd(
                                            selectedGroup.id,
                                            selectedGroup.displayName,
                                            member.username,
                                            member.name
                                        )
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } else {
                        ForEach(groups, id: \.id) { group in
                            Button {
                                selectedGroup = group
                            } label: {
                                HStack {
                                    Image(systemName: "person.3.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(CompanionPalette.jadeInk)
                                    Text(group.displayName).font(.system(size: 13))
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if selectedGroup != nil {
                    Button("换一个群") { selectedGroup = nil; search = "" }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 420, alignment: .topLeading)
    }
}

// MARK: - Muted person picker

/// Pick a followed group whose @s should stop interrupting.
private struct QuietGroupPickerSheet: View {
    let groups: [WhitelistEntry]
    let onPick: (WhitelistEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [WhitelistEntry] {
        let all = groups.sorted { $0.displayName < $1.displayName }
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("哪个群 @ 我不要弹出来")
                .font(.system(size: 15, weight: .semibold))
            Text("消息还是会在收件箱里，只是不打断你。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索群", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.id) { group in
                        HStack(spacing: 8) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(group.displayName).font(.system(size: 13))
                            Spacer(minLength: 4)
                            Button("不弹出") { onPick(group) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 420, alignment: .topLeading)
    }
}

private struct MutedPersonPickerSheet: View {
    let store: HUDStore
    let existing: [IgnoredSenderRule]
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var contacts: [ContactEntry] {
        let all = store.loadContacts().sorted { $0.displayName < $1.displayName }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.username.localizedCaseInsensitiveContains(search)
        }
    }

    private func alreadyMuted(_ username: String) -> Bool {
        existing.contains { $0.senderUsername == username }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("不想再看到谁的消息")
                .font(.system(size: 15, weight: .semibold))
            Text("选谁，就哪个对话都不再提醒——包括他所在的群。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索联系人", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(contacts, id: \.username) { contact in
                        HStack(spacing: 8) {
                            Text(contact.displayName).font(.system(size: 13))
                            Spacer(minLength: 4)
                            if alreadyMuted(contact.username) {
                                Text("已拉黑")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("不提醒") {
                                    onAdd(contact.username, contact.displayName)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 420, alignment: .topLeading)
    }
}
