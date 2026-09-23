import SwiftUI

/// One place for this page's promises.
///
/// The group-chat rule used to be stated as two different promises in this
/// one file, only one of which matched the send gate. The behaviour these
/// strings must describe is fixed by ChatMonitor: a group reply is always
/// held for manual confirmation, so it can exist as a draft and can never be
/// sent unattended.
enum AutopilotSettingsCopy {
    static let autoSendTitle = "自动发出去"
    static let autoSendOn = "够把握就发出去。"
    static let autoSendOff = "只写草稿，确认后发送。"

    static let groupAtTitle = "群里 @我 时也准备回复"
    static let groupRule = "群聊默认只记录；打开上面的开关后只写待确认草稿，不会自动发出。"
    static let groupAtOff = "群消息默认只记录，不写回复。"

    static let confidenceTitle = "自动发送把握程度"
    static let confidenceHint = "达到这个门槛才会尝试自动发送，仍受发送限制约束。"
    static let perHourTitle = "每小时最多"
    /// The window is rolling (`now - 3600` in `serialSendWithRateLimit`), not a
    /// clock hour, so "超了就等下一个小时" described a reset that does not
    /// happen. And the counter is shared: `executeSend` — a reply the user
    /// approved by hand in 待确认回复 — goes through the same limiter, which the
    /// old wording hid from someone with 自动发出去 switched off.
    static let perHourHint = "所有对话加起来一小时内最多发这么多条，自动发出和你确认后才发的都算。"

    static let alwaysManualTitle = "哪些一定交给你"
    static let alwaysManualRule = "群聊、转账、红包、小程序不会自动发送。其他敏感内容需人工确认。"

    /// The batch option is a window in seconds, not a message count. The old
    /// "连着几条一起回" title read as "reply after N messages", which is not
    /// what `batchWindowSeconds` does.
    ///
    /// `batchSection` names the group; `batchTitle` names the knob inside it.
    /// They used to be the same string, so the page printed the sentence twice
    /// in a row — a header immediately repeated by the only row under it, which
    /// reads as a rendering fault rather than as emphasis.
    static let batchSection = "连发的时候"
    static let batchTitle = "连发时等几秒一起回"
    static let batchHint = "连续几条消息会先等这个时长，再合成一次回复。单位是秒，不是条数。"

    static func excludedTitle(count: Int) -> String { "不会自动回复的人 (\(count))" }
    static let excludedEmpty = "还没有添加。这里的人不会被自动回复；要不要真的发出去，仍由上面的开关决定。"
    static let excludedAddButton = "添加排除对象"
    static let advancedTitle = "高级设置"
   static let historyTitle = "自动回复记录"
    static func historyEmpty(active: Bool) -> String {
        active
            ? "这一轮还没有记下会话。写好的草稿会进待确认。"
            : "开始整理后，每次会话会出现在这里。"
    }
   static let historyClear = "清除历史"
    static let historyClearConfirmTitle = "确定清除所有自动回复记录？"
    static let historyClearConfirm = "清除"
    static let historyClearCancel = "取消"
    static let historyClearFailed = "记录没清掉，请稍后重试（已发出的消息不受影响）"
    static let historyClearConfirmMessage = "只清掉助手里的自动回复记录，已发出的微信消息不受影响。"
}

struct AutopilotSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor
    @EnvironmentObject private var panelState: PanelState

    @State private var confidenceThreshold: Double = 0.8
    @State private var autoSendEnabled: Bool = false
    @State private var handleGroupAt: Bool = false
    @State private var maxRepliesPerHour: Int = 20
    @State private var batchWindowSeconds: Int = 10
    @State private var replyStyle: AutopilotReplyStyle = .auto
    @State private var excludedContacts: [String] = []
    @State private var sendKey: WeChatSendKey = .cmdEnter

    @State private var isHydrating = true
    @State private var saveError: String?
    /// 载入失败时非空：这一页显示的就必须是盘上的值，不接受改动。
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var showClearConfirm = false
    @State private var sessions: [AutopilotSession] = []
    @State private var isClearingHistory = false
    @State private var allContacts: [ContactEntry] = []
    @State private var safetyConfig = AutopilotConfig()
    @State private var saved = false
    @State private var pendingEnableAutoSend = false
    @State private var isEnablingAutoSend = false

    let replyLimits = [5, 10, 20, 50]
    let batchOptions = [5, 10, 15, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.autopilotActive ? CompanionPalette.jade : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(monitor.autopilotActive ? "正在整理回复" : "尚未开始整理")
                    .companionFont(size: 13)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看待确认回复") { panelState.pendingSettingsTab = "autopilotDashboard" }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .companionFont(size: 13, weight: .medium)
            }

            // The page header already reads 自动回复; a section repeating it
            // says nothing. Three cards below answer one question each — how
            // far the automation goes, when a reply goes out, what is never
            // automated — and grey out as a set when the config cannot be read.
            Group {
                SettingsSection("发到什么程度") {
                    SettingsToggleRow(
                        AutopilotSettingsCopy.autoSendTitle,
                        subtitle: autoSendEnabled ? AutopilotSettingsCopy.autoSendOn : AutopilotSettingsCopy.autoSendOff,
                        isOn: Binding(
                            get: { autoSendEnabled },
                            set: { newValue in
                                if newValue && !autoSendEnabled {
                                    pendingEnableAutoSend = true
                                } else {
                                    autoSendEnabled = newValue
                                    save()
                                }
                            }
                        )
                    )
                    SettingsRowDivider()
                    SettingsToggleRow(
                        AutopilotSettingsCopy.groupAtTitle,
                        subtitle: handleGroupAt
                            ? AutopilotSettingsCopy.groupRule
                            : AutopilotSettingsCopy.groupAtOff,
                        isOn: Binding(
                            get: { handleGroupAt },
                            set: { handleGroupAt = $0; save() }
                        )
                    )
                    SettingsRowDivider()
                    SettingsRow("回复风格", subtitle: replyStyle.hint) {
                        Picker("回复风格", selection: $replyStyle) {
                            ForEach(AutopilotReplyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .companionScaledWidth(140)
                        .onChange(of: replyStyle) { save() }
                    }
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(AutopilotSettingsCopy.confidenceTitle)
                                .companionFont(size: 13)
                            Spacer()
                            Text("\(Int(confidenceThreshold * 100))%")
                                .companionFont(size: 13, weight: .semibold)
                                .foregroundStyle(CompanionPalette.jadeInk)
                        }
                        Slider(value: $confidenceThreshold, in: 0.5...1.0, step: 0.05)
                            .tint(CompanionPalette.jade)
                            .accessibilityLabel(AutopilotSettingsCopy.confidenceTitle)
                            .onChange(of: confidenceThreshold) { save() }
                        Text(AutopilotSettingsCopy.confidenceHint)
                            .companionFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    SettingsRowDivider()
                    SettingsRow(AutopilotSettingsCopy.perHourTitle, subtitle: AutopilotSettingsCopy.perHourHint) {
                        Picker(AutopilotSettingsCopy.perHourTitle, selection: $maxRepliesPerHour) {
                            ForEach(replyLimits, id: \.self) { Text("\($0) 条").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .companionScaledWidth(80)
                        .onChange(of: maxRepliesPerHour) { save() }
                    }
                }

                // The batch window gets its own card: it is part of "when do
                // replies go out", not an expert tweak, and its old home behind
                // 高级设置 hid the answer from the question it answers.
                limitsBatchRow

                SettingsSection(AutopilotSettingsCopy.alwaysManualTitle) {
                    Text(AutopilotSettingsCopy.alwaysManualRule)
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    SettingsRowDivider()
                    DisclosureGroup {
                        exclusionSection
                    } label: {
                        Text(AutopilotSettingsCopy.excludedTitle(count: excludedContacts.count))
                            .companionDisclosureLabel()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    SettingsRowDivider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            advancedSection
                            historySection
                        }
                    } label: {
                        Text(AutopilotSettingsCopy.advancedTitle)
                            .companionDisclosureLabel()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            // The config could not be read, so every control in these cards is
            // drawn from Swift defaults, and `save()` is gated off: dragging
            // the 置信度 slider used to move the slider, print nothing, and
            // write nothing — while 「不会自动回复的人 (0)」 claimed an empty
            // list was a fact. Editable-looking and inert is worse than greyed
            // out. The gate has to sit on the Group wrapping all three cards:
            // chained onto one sibling it only greys that sibling, which is
            // what the old chain on the last disclosure did.
            .disabled(loadError != nil)
            .opacity(loadError == nil ? 1 : 0.55)

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .transition(.companionStatusReveal)
                Button("重新读取设置") { load() }
                    .transition(.companionStatusReveal)
                // 旧的错误文案把恢复说成「保存一次就行」，而这条页根本保存不了：
                // keep: `save()` is gated on `loadError == nil`, so a corrupt
                // row had no way out — while all five send sites tell the user
                // to go recover it here. The rebuild exists in the store
                // (`updateAutopilotConfig` maps `.corrupt` onto defaults); it
                // simply was not reachable from this screen.
                if loadIsCorrupt {
                    Button("用默认设置覆盖并重载（含敏感词、发送上限等本页不显示的项）") { rebuildFromDefaults() }
                    // This has to render INSIDE the loadError branch. `saveError`
                    // sits in the `else if` below it, so a failed rebuild wrote a
                    // sentence the page could only show once the read had already
                    // recovered — the one escape hatch the send-side refusals
                    // point at looked like a button that did nothing.
                    if let rebuildError {
                        Label(rebuildError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                            .transition(.companionStatusReveal)
                    }
                }
            } else if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .transition(.companionStatusReveal)
                Button("重试保存设置") { save() }
                    .transition(.companionStatusReveal)
            } else if saved {
                Label("设置已保存", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(CompanionPalette.jadeInk)
                    .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: loadError)
        .companionAnimation(CompanionMotion.ease(), value: saveError)
        .companionAnimation(CompanionMotion.ease(), value: rebuildError)
        .companionAnimation(CompanionMotion.ease(), value: saved)
        .onAppear {
            if !didLoad {
                didLoad = true
                load()
                DispatchQueue.main.async { isHydrating = false }
            }
        }
        .companionDialogBackdrop(pendingEnableAutoSend || showClearConfirm) {
            if pendingEnableAutoSend {
                CompanionDialog(title: CompanionProductCopy.autoSendConfirmTitle, onClose: {
                    if !isEnablingAutoSend {
                        pendingEnableAutoSend = false
                        autoSendEnabled = false
                    }
                }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.autoSendConfirmMessage)
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let saveError {
                            Text(saveError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.autoSendKeepManual) {
                                pendingEnableAutoSend = false
                                autoSendEnabled = false
                            }
                                .companionBusyHold(isEnablingAutoSend, "正在保存自动发送设置")
                            Button {
                                guard !isEnablingAutoSend else { return }
                                isEnablingAutoSend = true
                                autoSendEnabled = true
                                Task { @MainActor in
                                    let ok = save()
                                    isEnablingAutoSend = false
                                    if ok {
                                        pendingEnableAutoSend = false
                                    } else {
                                        autoSendEnabled = false
                                    }
                                }
                            } label: {
                                Text(isEnablingAutoSend ? "正在开启自动发送…" : CompanionProductCopy.autoSendAllow)
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isEnablingAutoSend)
                            .help(isEnablingAutoSend ? "正在保存自动发送设置" : "")
                            .accessibilityHint(isEnablingAutoSend ? "正在保存自动发送设置" : "")
                        }
                    }
                }
            }
            else if showClearConfirm {
                CompanionDialog(title: AutopilotSettingsCopy.historyClearConfirmTitle, onClose: { if !isClearingHistory { showClearConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(AutopilotSettingsCopy.historyClearConfirmMessage)
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let saveError {
                            Text(saveError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button(AutopilotSettingsCopy.historyClearCancel) { showClearConfirm = false }
                                .companionBusyHold(isClearingHistory, "正在清除自动回复记录")
                            Button(role: .destructive) {
                                guard !isClearingHistory else { return }
                                isClearingHistory = true
                                Task { @MainActor in
                                    do {
                                        try store.clearAutopilotHistory()
                                        sessions = store.loadAutopilotSessions(limit: 10)
                                        saveError = nil
                                        showClearConfirm = false
                                    } catch {
                                        saveError = AutopilotSettingsCopy.historyClearFailed
                                    }
                                    isClearingHistory = false
                                }
                            } label: {
                                Text(isClearingHistory ? "正在清除记录…" : AutopilotSettingsCopy.historyClearConfirm)
                            }
                            .disabled(isClearingHistory)
                            .help(isClearingHistory ? "正在清除自动回复记录" : "")
                            .accessibilityHint(isClearingHistory ? "正在清除自动回复记录" : "")
                        }
                    }
                }
            }
        }
    }

    private var limitsBatchRow: some View {
        SettingsSection(AutopilotSettingsCopy.batchSection) {
            SettingsRow(AutopilotSettingsCopy.batchTitle, subtitle: AutopilotSettingsCopy.batchHint) {
                Picker(AutopilotSettingsCopy.batchTitle, selection: $batchWindowSeconds) {
                    ForEach(batchOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .companionScaledWidth(80)
                .onChange(of: batchWindowSeconds) { save() }
            }
        }
    }

    // MARK: - Exclusion

    private var exclusionSection: some View {
        // Headerless: the disclosure label above already carries this exact
        // string and its count.
        SettingsSection(nil) {
            if excludedContacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AutopilotSettingsCopy.excludedEmpty)
                        .companionFont(size: 11)
                        .foregroundColor(.secondary)
                    if allContacts.isEmpty {
                        Button("关注谁") {
                            NotificationCenter.default.post(name: .hudSwitchTab, object: "contacts")
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .accessibilityLabel("去关注谁，才能添加排除对象")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(Array(excludedContacts.enumerated()), id: \.element) { idx, username in
                    if idx > 0 { SettingsRowDivider() }
                    HStack {
                        Text(contactDisplayName(username))
                            .companionFont(size: 12)
                        Spacer()
                        Button {
                            excludedContacts.removeAll { $0 == username }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .companionFont(size: 13)
                                .foregroundColor(.red.opacity(0.6))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CompanionIconButtonStyle())
                        .accessibilityLabel("移除排除对象")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }

            let available = allContacts.filter { !excludedContacts.contains($0.username) }
            if !available.isEmpty {
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Menu {
                        ForEach(available, id: \.username) { contact in
                            Button("\(contact.role.icon) \(contact.displayName)") {
                                excludedContacts.append(contact.username)
                                save()
                            }
                        }
                    } label: {
                        Label(AutopilotSettingsCopy.excludedAddButton, systemImage: "plus.circle")
                            .companionFont(size: 11)
                    }
                    .menuStyle(.borderlessButton)
                    .companionScaledWidth(70)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        // No header: the disclosure this sits inside is already labelled
        // 高级设置, and the group-chat rule it used to open with is printed
        // verbatim as that toggle's own subtitle two rows up.
        SettingsSection(nil) {
            // A fixed guardrail, not a knob. In the main section it looked
            // like a picker that had failed to draw.
            SettingsRow("单次整理上限", subtitle: "一次整理最多自动发出这么多条，防止跑飞。") {
                Text(safetyConfig.maxSendsPerSession > 0 ? "\(safetyConfig.maxSendsPerSession) 条" : "未设置上限")
                    .foregroundStyle(.secondary)
            }
            SettingsRowDivider()
            SettingsRow(
                "微信发送键",
                subtitle: sendKey == .cmdEnter ? "默认：Enter 换行，Cmd+Enter 发送" : "你已在微信里改成 Enter 直接发送",
                icon: "paperplane.fill",
                iconColor: .blue
            ) {
                Picker("", selection: $sendKey) {
                    Text("Cmd+Enter").tag(WeChatSendKey.cmdEnter)
                    Text("Enter").tag(WeChatSendKey.enter)
                }
                .pickerStyle(.segmented)
                .companionScaledWidth(170)
                .onChange(of: sendKey) { save() }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection(AutopilotSettingsCopy.historyTitle) {
           if sessions.isEmpty {
                Text(AutopilotSettingsCopy.historyEmpty(active: monitor.autopilotActive))
                   .companionFont(size: 11)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                    if idx > 0 { SettingsRowDivider() }
                    sessionRow(session)
                }
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Button(AutopilotSettingsCopy.historyClear) { showClearConfirm = true }
                        // Was 10pt red at 0.7 opacity — below the AA
                        // contrast floor and a small hit target for a
                        // destructive action.
                        .companionFont(size: 12)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func sessionRow(_ session: AutopilotSession) -> some View {
        HStack(spacing: 8) {
            Text(formatDate(session.startedAt))
                .companionFont(size: 11, design: .monospaced)
                .foregroundColor(.primary)
            Text(sessionDuration(session))
                .companionFont(size: 10)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Label("\(session.totalSent)", systemImage: "checkmark.circle")
                    .companionFont(size: 10).foregroundColor(.green)
                Label("\(session.totalPending)", systemImage: "clock")
                    .companionFont(size: 10).foregroundColor(.orange)
            }
            if session.endedAt == nil {
                Text("运行中")
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func sessionDuration(_ session: AutopilotSession) -> String {
        let end = session.endedAt ?? Date()
        let s = Int(end.timeIntervalSince(session.startedAt))
        return RelativeTimeFormatter.elapsedLabel(TimeInterval(s))
    }

    private func contactDisplayName(_ username: String) -> String {
        allContacts.first { $0.username == username }?.displayName ?? username
    }

    // MARK: - Persistence

    private func load() {
        // §164 closed the write side of `nil == 读不到`; this is the other half,
        // and it is not a read-only default. The eight fields hydrated here are
        // exactly the eight that `save()` writes back over the stored record, so
        // one BUSY at onAppear used to paint defaults on screen — and the next
        // control the user touched pushed them onto disk: `excludedContacts`
        // emptied (「不再自动回复这些人」gone) and, if they then re-enabled
        // 自动发送, previously excluded people started receiving AI replies.
        let cfg: AutopilotConfig
        switch store.readSettingJSON("autopilot", as: AutopilotConfig.self) {
        case .value(let stored): cfg = stored
        case .absent: cfg = AutopilotConfig()
        case .unreadable:
            loadError = "读不到当前的托管设置，这一页暂时不接受改动。请点「重新读取设置」再试一次。"
            loadIsCorrupt = false
            saved = false
            return
        case .corrupt:
            // Same refusal, different sentence: this one will not fix itself by
            // retrying, and hydrating the page from defaults would let the next
            // 保存 write the defaults over whatever the user had set — so the
            // rebuild has to be an action the user takes with their eyes open.
            loadError = "托管设置的内容读不懂（可能被上次写入打断）。这一页暂时不接受改动；要恢复自动托管，只能显式用默认设置覆盖（会丢弃现有托管设置）。"
            loadIsCorrupt = true
            saved = false
            return
        }
        loadError = nil
        autoSendEnabled = cfg.autoSendEnabled
        handleGroupAt = cfg.handleGroupAt
        confidenceThreshold = cfg.confidenceThreshold
        maxRepliesPerHour = cfg.maxRepliesPerHour
        batchWindowSeconds = cfg.batchWindowSeconds
        replyStyle = cfg.replyStyle
        excludedContacts = cfg.excludedContacts
        sendKey = cfg.sendKey
        safetyConfig = cfg
        sessions = store.loadAutopilotSessions(limit: 10)
        allContacts = store.loadContacts(level: nil)
    }

    /// Set only by the `.corrupt` read: 「内容读不懂」 and 「这次读不到」 need
    /// different escape hatches, and only the first one is fixable by writing
    /// defaults over the row.
    @State private var loadIsCorrupt = false

    /// Rendered beside the rebuild button rather than in `saveError`: see the
    /// branch above for why a shared error slot hid it.
    @State private var rebuildError: String?

    /// The one write this page must be able to make *while* its read is failing:
    /// `updateAutopilotConfig` rebuilds from defaults on `.corrupt`, so a no-op
    /// mutation is what replaces the unreadable row with a readable one. It is
    /// destructive (every stored 托管 setting goes back to defaults), which is why
    /// it is a named button and not something 保存 does behind the user's back.
    private func rebuildFromDefaults() {
        rebuildError = nil
        guard (try? store.updateAutopilotConfig { _ in }) == true else {
            rebuildError = "默认设置也没写进去：本机设置可能正被占用。请稍后再试一次。"
            return
        }
        loadError = nil
        loadIsCorrupt = false
        load()
    }

    @discardableResult
    private func save() -> Bool {
        guard didLoad, !isHydrating, loadError == nil else { return false }
        // One merge-update for the whole page, so we don't clobber fields the
        // settings UI doesn't surface yet (maxSendsPerSession, sensitiveKeywords,
        // proactive*, etc. all default-construct and would blow away user values
        // if we rebuilt from scratch). The merge reads the stored record and
        // refuses to write when that read failed: `?? AutopilotConfig()` used to
        // rebuild from defaults on a busy lock, the INSERT then replaced the
        // user's guardrails with them, and this page printed 「设置已保存」.
        var written = AutopilotConfig()
        do {
            let wrote = try store.updateAutopilotConfig { cfg in
                cfg.autoSendEnabled = autoSendEnabled
                cfg.handleGroupAt = handleGroupAt
                cfg.confidenceThreshold = confidenceThreshold
                cfg.maxRepliesPerHour = maxRepliesPerHour
                cfg.batchWindowSeconds = batchWindowSeconds
                cfg.excludedContacts = excludedContacts
                cfg.replyStyle = replyStyle
                cfg.sendKey = sendKey
                written = cfg
            }
            guard wrote else {
                saveError = "读不回当前的托管设置，这次没有保存 —— 否则会用默认规则盖掉这页没有显示的开关。请稍后再试一次。"
                saved = false
                return false
            }
            saveError = nil
            safetyConfig = written
            saved = true
            return true
        } catch {
            saveError = "设置没保存成功，现在还是上次的规则。请再试一次。"
            return false
        }
    }

}
