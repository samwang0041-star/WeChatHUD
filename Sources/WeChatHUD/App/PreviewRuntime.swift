import Foundation
import AppKit

/// Explicit, isolated product preview. Never opens personal data or controls WeChat.
enum PreviewRuntime {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier == "com.wechathud.product-preview"
    }
    static let directory = NSTemporaryDirectory() + "wechathud-product-preview"
    static var pendingAITestFailure = false
    static var pendingAutoSendConfirm = false
    /// Preview-only stand-ins for system accessibility so 验收 7 / 9 can run
    /// without changing the host Mac's settings.
    static var reduceMotionOverride: Bool?
    static var reduceTransparencyOverride: Bool?
    static var increaseContrastOverride: Bool?
    static var differentiateWithoutColorOverride: Bool?
    static var largeType = false
    static var usingExternalDisplay = false
    static var hideDemoChromeForCapture = false
    private static var captureBridgeInstalled = false

    /// `--preview-capture=<seconds>` snapshots every visible surface once,
    /// that many seconds after launch — no pointer, no clicking the in-app
    /// 导出界面快照 button, no cross-process notification.
    ///
    /// The distributed-notification bridge below (`installCaptureBridge`)
    /// stays for a human driving the app by hand, but a script on a current
    /// macOS does not reliably get its notification delivered, which made
    /// "launch, then snap" unrepeatable for automated walkthroughs.
    /// A launch flag removes both the pointer and the IPC from the loop.
    @MainActor static func scheduleLaunchCapture() {
        guard isEnabled else { return }
        let prefix = "--preview-capture="
        guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              let delay = TimeInterval(raw.dropFirst(prefix.count)),
              delay >= 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            captureSurfaces(as: "auto")
            // A second sample a beat later: sheets and menu tracking settle on
            // their own schedule, and a single frame can catch a window
            // mid-presentation and report it as absent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                captureSurfaces(as: "auto2")
            }
        }
    }

    /// `--preview-hig-audit=<seconds>` runs `AccessibilityAudit` against the
    /// live window hierarchy once, that many seconds after launch. Separate
    /// from `--preview-capture` so a walkthrough can screenshot and measure in
    /// the same launch without one waiting on the other.
    @MainActor static func scheduleAccessibilityAudit() {
        guard isEnabled else { return }
        let prefix = "--preview-hig-audit="
        guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              let delay = TimeInterval(raw.dropFirst(prefix.count)),
              delay >= 0 else { return }
        AccessibilityAudit.run(after: delay)
    }

    /// `--preview-activate` brings the preview app to the front once.
    ///
    /// A menu-bar-only app (`LSUIElement`) has no menu bar of its own until it
    /// is active, so "does the 文件 menu actually appear" cannot be checked
    /// from a background launch. This flag exists so that check can be run
    /// from a repeatable launch instead of by clicking the Dock.
    @MainActor static func activateForMenuCheck() {
        guard isEnabled, CommandLine.arguments.contains("--preview-activate") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0 is SettingsWindow }?.makeKeyAndOrderFront(nil)
        }
    }

    /// `--preview-dark` / `--preview-light` pin this preview process to one
    /// appearance, so a surface that only follows the *system* scheme can be
    /// rendered in the other one without changing the host Mac's setting.
    @MainActor static func applyAppearanceOverride() {
        guard isEnabled else { return }
        let arguments = CommandLine.arguments
        if arguments.contains("--preview-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("--preview-light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// `--preview-hover` drives the compact pill's hover expansion without a
    /// real cursor, so the "cursor enters the idle island" transition can be
    /// traced and measured from a repeatable launch.
    @MainActor static func simulateHover(after delay: TimeInterval = 2.5) {
        guard isEnabled, CommandLine.arguments.contains("--preview-hover") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            (NSApp.delegate as? AppDelegate)?.panelState.mouseEntered()
        }
    }

    static func applyAccessibilityOverrides() {
        let arguments = CommandLine.arguments
        // Launch flags as well as the in-app demo buttons. The buttons move a
        // pointer and cannot be replayed; a flag makes "capture the app under
        // Increase Contrast" a repeatable command, which is the same reason
        // `--preview-tab` exists for the workspace pages.
        if arguments.contains("--preview-contrast") { increaseContrastOverride = true }
        if arguments.contains("--preview-no-color") { differentiateWithoutColorOverride = true }
        if arguments.contains("--preview-large-type") { largeType = true }

        CompanionMotion.reduceMotionProvider = {
            reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        CompanionMotion.reduceTransparencyProvider = {
            reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        CompanionAccessibility.increaseContrastProvider = {
            increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        CompanionAccessibility.differentiateWithoutColorProvider = {
            differentiateWithoutColorOverride
                ?? NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        }
    }

    @MainActor static func toggleIncreaseContrast() {
        guard isEnabled else { return }
        increaseContrastOverride = !(increaseContrastOverride ?? false)
        applyAccessibilityOverrides()
        // Same signal the real system switch raises, so the demo path and the
        // real one cannot diverge in what they redraw.
        CompanionAccessibility.noteDisplayOptionsChanged()
    }

    @MainActor static func toggleDifferentiateWithoutColor() {
        guard isEnabled else { return }
        differentiateWithoutColorOverride = !(differentiateWithoutColorOverride ?? false)
        applyAccessibilityOverrides()
        CompanionAccessibility.noteDisplayOptionsChanged()
    }

    @MainActor static func toggleReduceMotion() {
        guard isEnabled else { return }
        reduceMotionOverride = !(reduceMotionOverride ?? false)
        applyAccessibilityOverrides()
    }

    @MainActor static func toggleReduceTransparency() {
        guard isEnabled else { return }
        reduceTransparencyOverride = !(reduceTransparencyOverride ?? false)
        applyAccessibilityOverrides()
    }

    @MainActor static func toggleLargeType() {
        guard isEnabled else { return }
        largeType.toggle()
    }

    @MainActor static func toggleExternalDisplay(store: HUDStore) {
        guard isEnabled else { return }
        usingExternalDisplay.toggle()
        let screen: DisplayScreen = usingExternalDisplay ? .external : .builtIn
        var cfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        cfg.displayScreen = screen
        try? store.setSettingJSON("sync", value: cfg)
        NotificationCenter.default.post(name: .hudDisplayPreferenceDidChange, object: nil)
        if let app = NSApp.delegate as? AppDelegate {
            app.panel?.displayScreen = screen
            app.panel?.positionAtTop()
        }
    }

    @MainActor static func simulateAutoSendConfirm(panelState: PanelState) {
        guard isEnabled else { return }
        pendingAutoSendConfirm = true
        panelState.pendingSettingsTab = "autopilot"
        NotificationCenter.default.post(name: .hudPreviewAutoSendConfirm, object: nil)
    }

    /// Notification fixtures. The `long` form mirrors the reported
    /// real-world case — a long group name plus a multi-line message —
    /// so the banner's height budget can be exercised without reading
    /// or touching any real chat.
    private struct NotificationPreviewFixture {
        let chatUsername: String
        let chatName: String
        let senderName: String
        let text: String
        let summary: String

        static let short = NotificationPreviewFixture(
            chatUsername: "preview-project", chatName: "项目协作群", senderName: "林晓",
            text: "@我 明天下午评审，能否确认待办责任人的展示方案？",
            summary: "评审前需要你确认待办责任人的展示方案。")

        static let long = NotificationPreviewFixture(
            chatUsername: "preview-industry", chatName: "行业合作-小程序业务交流群", senderName: "周然",
            text: "@我 老师您好，我们这边正在做公众号年审，之前登记的行业是金融类-银行，现在后台的行业选项里找不到这个类型，麻烦看下应该选哪一个，我先把年审材料整理好等您的回复。",
            summary: "年审行业类型待确认，对方在等回复。")
    }

    @MainActor static func simulateNotification(monitor: ChatMonitor, panelState: PanelState,
                                                longForm: Bool = false,
                                                holdSeconds: TimeInterval? = nil) {
        guard isEnabled else { return }
        panelState.islandSnoozeUndo = nil
        panelState.toastMessage = nil
        panelState.popoverOpen = false
        panelState.collapse()
        let fixture = longForm ? NotificationPreviewFixture.long : NotificationPreviewFixture.short
        let text = fixture.text
        let notification = HUDNotification(chatUsername: fixture.chatUsername, chatName: fixture.chatName,
            senderUsername: "preview-peer", senderName: fixture.senderName, attentionLevel: .vip,
            messageID: "preview-notification-\(UUID().uuidString)", rawText: text, snippet: text,
            isAtMention: true, timestamp: Date(), kind: .groupAt)
        monitor.latestNotification = notification
        monitor.recentNotifications = [notification]
        if !monitor.inboxItems.contains(where: { $0.chatUsername == fixture.chatUsername }) {
            monitor.inboxItems.insert(
                InboxItem(id: fixture.chatUsername, chatUsername: fixture.chatUsername, chatName: fixture.chatName,
                    senderName: fixture.senderName, preview: text, isGroup: true, timestamp: Date(),
                    actionRequired: true, priority: .p1, isVIP: false, isWhitelisted: true,
                    unreadCount: 1, isAtMention: true, askType: .yesNo, reasons: [], suggestedReplyMinutes: 60,
                    status: .active, aiSummary: fixture.summary, moodEmoji: nil),
                at: 0)
        }
        monitor.groupContextStates[notification.briefingKey] = GroupContextBriefingLoadState(
            briefing: GroupContextBriefing(
                situation: "大家正在确认今天下午的评审安排。",
                whyMentioned: "林晓需要你确认待办责任人的展示方案。",
                currentStatus: "还在等你回复。",
                nextStep: "确认时间后，在群里回复。",
                participants: [fixture.senderName],
                confidence: 0.9,
                source: .ai,
                generatedAt: Date()
            ),
            isLoading: false,
            errorMessage: nil,
            updatedAt: Date()
        )
        let config = monitor.store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
        if config.shouldPresent(notification.presentationSemanticState) {
            // A caller that wants the banner to stay put (the
            // `--preview-notification` launch flag) passes the hold here
            // instead of rewriting the consumer-facing duration setting.
            // That write used to leak: killing the preview process between
            // "hold" and "restore" left a 900-second duration in the
            // preview database, so later preview launches showed a banner
            // that appeared to ignore repeat clicks.
            panelState.showNotification(duration: holdSeconds ?? TimeInterval(config.durationSeconds))
        }
    }

    static func missedReplyFixtures(now: Date = Date()) -> [MissedReplyFinder.Item] {
        [
            MissedReplyFinder.Item(
                id: "preview-xu|missed-1",
                chatUsername: "preview-xu",
                chatName: "许宁",
                senderName: "许宁",
                preview: "上周说的报价，你看了没？我这边要交差。",
                timestamp: now.addingTimeInterval(-3 * 86400),
                isGroup: false,
                isAtMention: false,
                isVIP: false,
                unrepliedCount: 2,
                sourceMessageID: "missed-1",
                sourceText: "上周说的报价，你看了没？我这边要交差。"
            ),
            MissedReplyFinder.Item(
                id: "preview-project|missed-2",
                chatUsername: "preview-project",
                chatName: "项目协作群",
                senderName: "林晓",
                preview: "@我 纪要还差你那一段，今天下班前能补上吗？",
                timestamp: now.addingTimeInterval(-2 * 86400),
                isGroup: true,
                isAtMention: true,
                isVIP: false,
                unrepliedCount: 1,
                sourceMessageID: "missed-2",
                sourceText: "@我 纪要还差你那一段，今天下班前能补上吗？"
            )
        ]
    }

    @MainActor static func seed(store: HUDStore, monitor: ChatMonitor) {
        try? store.setSetting("onboarded", value: "1")
        let now = Date()
        let examples: [(String, String, String, Bool)] = [
            ("preview-project", "项目协作群", "@我 明天下午评审，能否先确认交互稿里待办的责任人展示？", true),
            ("preview-colleague", "林晓 · 产品同事", "更新的验收清单已经整理好了，等你确认后我们就安排联调。", false),
            ("preview-design", "设计评审群", "首页改版今晚能过一遍吗？我把标注也补上了。", true)
        ]
        monitor.inboxItems = examples.enumerated().map { index, row in
            InboxItem(id: row.0, chatUsername: row.0, chatName: row.1, senderName: "林晓", preview: row.2,
                isGroup: row.3, timestamp: now.addingTimeInterval(-Double(index + 1) * 300),
                actionRequired: true, priority: .p1, isVIP: !row.3, isWhitelisted: true,
                unreadCount: 1, isAtMention: row.3, askType: .yesNo, reasons: [], suggestedReplyMinutes: 60,
                status: .active, aiSummary: [
                    "评审前需要你确认：待办是否应同时显示执行人和交代人。",
                    "验收清单已准备好，等你确认后安排联调。",
                    "今晚想请你过一遍首页改版和标注。"
                ][index], moodEmoji: nil)
        }
        monitor.missedReplies = missedReplyFixtures(now: now)
        monitor.recentNotifications = examples.map { row in
            HUDNotification(chatUsername: row.0, chatName: row.1, senderUsername: "preview-peer", senderName: "林晓",
                attentionLevel: .vip, messageID: "preview-message-\(row.0)", rawText: row.2, snippet: row.2,
                isAtMention: row.3, timestamp: now, kind: row.3 ? .groupAt : .privateChat)
        }
        for (index, owner) in [DiscussionItemOwner.mine, .theirs, .shared].enumerated() {
            _ = try? store.insertDiscussionItem(chatUsername: "preview-project", chatName: "项目协作群", kind: .todo, owner: owner,
                content: ["确认待办责任人的展示规则", "请林晓整理联调验收清单", "一起确认明天下午的评审安排"][index],
                detail: ["评审前需要明确执行人、交代人和完成状态，避免任务没人接。", "你已经交代对方准备，收到清单后再检查是否齐全。", "会议时间还需要双方确认，暂时没有明确截止时间。"][index],
                anchorMsgUID: "preview-task-\(index)", sourceTimestamp: Int(now.timeIntervalSince1970),
                dueAt: index == 2 ? nil : now.addingTimeInterval(Double(index + 1) * 3600), confidence: 0.9, promptVersion: "preview")
        }
        for item in store.loadDiscussionItems() where item.promptVersion == "preview" && item.status != .pending {
            try? store.updateDiscussionItemStatus(id: item.id, status: .pending)
        }
        // Keep demo records isolated and stable so native edit/filter flows
        // can be verified without touching any real contact or promise.
        if store.getContact(username: "preview-colleague") == nil {
            try? store.saveContactTracking(username: "preview-colleague", displayName: "林晓 · 产品同事",
                isGroup: false, category: .work, attentionLevel: .vip, role: .colleague)
        }
        if store.getContact(username: "preview-project") == nil {
            try? store.saveContactTracking(username: "preview-project", displayName: "项目协作群",
                isGroup: true, category: .work, attentionLevel: .whitelist, role: .colleague)
        }
        if store.getContact(username: "preview-design") == nil {
            try? store.saveContactTracking(username: "preview-design", displayName: "设计评审群",
                isGroup: true, category: .work, attentionLevel: .whitelist, role: .colleague)
        }
        if store.getContact(username: "preview-xu") == nil {
            try? store.saveContactTracking(username: "preview-xu", displayName: "许宁",
                isGroup: false, category: .work, attentionLevel: .whitelist, role: .colleague)
        }
        try? store.upsertCommitment(msgUID: "preview-promise-review", chatUsername: "preview-colleague",
            chatName: "林晓 · 产品同事", content: "评审前确认待办责任人的展示规则", commitTo: "林晓",
            deadlineAt: now.addingTimeInterval(3600), confidence: 0.93, promptVersion: "preview",
            sourceText: "我会在评审前确认展示规则，把结论发给你。", contextText: "同事需要据此准备联调验收。",
            captureReason: "明确承诺由我确认并反馈", nextStep: "核对交互稿后回复结论", deadlineLabel: "评审前")
        try? store.upsertCommitment(msgUID: "preview-promise-overdue", chatUsername: "preview-colleague",
            chatName: "林晓 · 产品同事", content: "把验收清单发到群里", commitTo: "林晓",
            deadlineAt: now.addingTimeInterval(-90000), confidence: 0.88, promptVersion: "preview",
            sourceText: "今天下午前我把验收清单发群里。", contextText: "联调前需要大家对齐范围。",
            captureReason: "明确承诺今天下午交付", nextStep: "补发清单并说明缺项", deadlineLabel: "今天下午")
        if store.loadDrafts().isEmpty {
            try? store.saveDraft(chatUsername: "preview-colleague", chatName: "林晓 · 产品同事",
                text: "我确认一下大家的时间，15:00 前回复你。", sendAt: nil)
            try? store.saveDraft(chatUsername: "preview-project", chatName: "项目协作群",
                text: "这份方案我再整理一下，晚点发你。", sendAt: nil)
        }
        if monitor.autopilotLog.isEmpty {
            monitor.autopilotLog = [
                AutopilotLogEntry(id: 1, sessionId: 1, chatUsername: "preview-colleague", chatName: "林晓 · 产品同事",
                    senderUsername: "preview-peer", senderName: "林晓", triggerMsgUID: "preview-ap-1",
                    triggerText: "今天的评审定在几点？", generatedReply: "我先确认一下，15:00 前回复你。",
                    confidence: 0.86, riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil, createdAt: now),
                AutopilotLogEntry(id: 2, sessionId: 1, chatUsername: "preview-colleague", chatName: "林晓 · 产品同事",
                    senderUsername: "preview-peer", senderName: "林晓", triggerMsgUID: "preview-ap-2",
                    triggerText: "这笔费用需要尽快处理一下", generatedReply: "我先核对本条，不直接回复转账信息。",
                    confidence: 0.41, riskLevel: .high, action: .pending, aiReasoning: "涉及转账需人工处理", sentAt: nil,
                    createdAt: now.addingTimeInterval(-1800))
            ]
        }
        try? store.setSetting("composer_draft:preview-colleague", value: "我再看一下时间，晚点回你。")
        try? store.setSetting("composer_draft:preview-project", value: "群里这事我再看一眼。")
        monitor.composerDraftEdits["preview-colleague"] = "我再看一下时间，晚点回你。"
        monitor.composerDraftEdits["preview-project"] = "群里这事我再看一眼。"
        if !store.loadDiscussionItems().contains(where: { $0.anchorMsgUID == "preview-task-colleague" }) {
            _ = try? store.insertDiscussionItem(
                chatUsername: "preview-colleague", chatName: "林晓 · 产品同事", kind: .todo, owner: .mine,
                content: "确认待办责任人的展示规则",
                detail: "评审前需要明确执行人、交代人和完成状态。",
                anchorMsgUID: "preview-task-colleague", sourceTimestamp: Int(now.timeIntervalSince1970),
                dueAt: now.addingTimeInterval(3600), confidence: 0.9, promptVersion: "preview"
            )
        }
        for commitment in store.loadCommitments() where commitment.promptVersion == "preview" && commitment.status != .pending {
            try? store.updateCommitmentStatus(msgUID: commitment.msgUID, status: .pending)
        }
        monitor.reloadAIData()
        monitor.stats.syncStatus = .ok
        monitor.stats.lastSyncAt = now
        let previewInsight = ChatInsightResult(
            headline: "本周评审正在收口",
            topics: [
                TopicInsight(name: "确定范围", messageCount: 8, participantCount: 3, summary: "已确认评审范围和参与人。", status: "已完成", myInvolvement: nil, crossChats: nil),
                TopicInsight(name: "等待评审时间", messageCount: 4, participantCount: 2, summary: "时间仍待确认。", status: "待确认", myInvolvement: nil, crossChats: nil)
            ],
            decisions: ["评审范围已确认"],
            actionItems: [InsightActionItem(what: "确认评审时间", who: "我来做", deadline: "今天 15:00")],
            mentionsMe: 1,
            waitingForMe: [WaitingItem(source: "林晓", what: "确认待办责任人的展示规则", waitingHours: 2)],
            myCommitments: ["评审前确认展示规则"],
            needsMyAttention: true,
            overallMood: "推进中",
            signalNoiseRatio: 0.8,
            decisionEfficiency: "快",
            importanceToMe: ImportanceLevel(level: "高", reason: "评审当天"),
            crossChatTopics: nil,
            insight: "10:20 林晓：今天的评审定在几点?",
            suggestion: "已确认评审范围，时间仍待你确认。"
        )
        monitor.insightCoordinator.seedPreviewResult(chatUsername: "preview-colleague", result: previewInsight)
        monitor.insightCoordinator.seedPreviewResult(chatUsername: "preview-project", result: previewInsight)
    }

    @MainActor static func simulateSendSuccess(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        panelState.previewSendReceipt = CompanionProductCopy.sendSuccess(name: "林晓 · 产品同事")
        panelState.showChatDetail(chatUsername: "preview-colleague", chatName: "林晓 · 产品同事")
    }

    @MainActor static func simulateSendUncertain(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        panelState.previewSendReceipt = CompanionProductCopy.sendUncertain
        panelState.showChatDetail(chatUsername: "preview-colleague", chatName: "林晓 · 产品同事")
    }

    @MainActor static func simulateCompact(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        if monitor.inboxItems.filter(\.surfacesInCompact).count < 3 {
            seed(store: monitor.store, monitor: monitor)
        }
        monitor.stats.syncStatus = .ok
        panelState.islandSurface = .inbox
        panelState.popoverOpen = false
        panelState.collapse()
    }

    /// `--preview-cycle=N` drives N expand/collapse cycles from inside the
    /// app: hover state, collapse and the wait between them all happen on the
    /// main queue, with no cursor movement and no second display involved.
    ///
    /// Animation QA used to be driven by synthesising mouse events, which
    /// commandeered the operator's real pointer and made every measurement
    /// depend on whatever window happened to be under it. A self-driven loop
    /// is repeatable, runs entirely on the screen the operator chose, and
    /// leaves their machine alone.
    @MainActor static func startAnimationCycle(monitor: ChatMonitor, panelState: PanelState, count: Int) {
        guard isEnabled, count > 0 else { return }
        if monitor.inboxItems.filter(\.surfacesInCompact).count < 3 {
            seed(store: monitor.store, monitor: monitor)
        }
        monitor.stats.syncStatus = .ok

        var remaining = count
        func cycle() {
            guard remaining > 0 else { return }
            remaining -= 1
            panelState.islandSurface = .inbox
            panelState.popoverOpen = false
            panelState.goExtended()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                panelState.collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { cycle() }
            }
        }
        // Let launch settle first: the first cycle would otherwise race the
        // workspace window's own first paint and measure that instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { cycle() }
    }

    /// One row of the transition report.
    struct TransitionSample: Codable {
        let transition: String
        let fromState: String
        let toState: String
        let durationMs: Double
        let frames: Int
        let fps: Double
        let averageMs: Double
        let p95Ms: Double
        let worstMs: Double
        let wasInstant: Bool
        /// Wall time from the leg starting to the panel reaching its
        /// destination state. nil means it never got there inside the poll
        /// window, which is itself a finding rather than a pass.
        let settledMs: Double?
    }

    /// `--preview-transitions` measures **every** island transition, not just
    /// the one path `--preview-peek` happens to drive.
    ///
    /// Why this exists: the acceptance record could say "peek and extended ran
    /// at 60 fps", which is true and covers two of the island's six transitions.
    /// Hover-in, hover-out, collapse, the notification banner, the row expand
    /// and the detail surface were all unmeasured — and a stutter in any one of
    /// them is exactly what a user notices, because each is triggered by their
    /// own click or cursor move.
    ///
    /// Each transition is driven through the same entry points the real
    /// pointer uses (`mouseEntered`/`mouseExited`/`goExtended`/`collapse`),
    /// waits for the frame spring to settle, then reads `IslandFrameTiming`,
    /// which the panel already feeds every vsync.
    @MainActor static func runTransitionMeasurement(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        if monitor.inboxItems.filter(\.surfacesInCompact).count < 3 {
            seed(store: monitor.store, monitor: monitor)
        }
        monitor.stats.syncStatus = .ok
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wechathud-island-transitions.json")
        var samples: [TransitionSample] = []
        IslandFrameTiming.resetHistory()

        /// Run one leg, wait for the spring to land, and record what the
        /// panel measured over that window.
        func leg(_ name: String, _ body: () -> Void, settle: Double, expect: String? = nil) {
            let from = "\(panelState.presentedState)"
            // Let the previous leg’s shadow/glow work drain before the next
            // window opens, or its frames land in this leg’s average.
            IslandFrameTiming.begin()
            let started = Date()
            body()
            // Poll for the destination rather than sleeping a fixed guess.
            // Some transitions resolve on a later run-loop turn: a debounced
            // pointer exit schedules a timer, and a banner presentation is
            // resolved by the monitor. With a fixed wait the leg could record
            // the *previous* state as its destination — which is exactly how
            // the hover-out leg first reported "peek → peek" with zero frames
            // and looked like it had passed.
            var settledMs: Double? = nil
            let deadline = Date().addingTimeInterval(settle)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                // Record *when* the destination arrived, but keep pumping the
                // run loop until the deadline. Breaking here would stop before
                // the frame spring had run, so `IslandFrameTiming` would hold
                // no samples and the leg would report 0 fps — a measurement
                // that looks like a result and is actually the absence of one.
                if settledMs == nil, let expect, "\(panelState.presentedState)" == expect {
                    settledMs = Date().timeIntervalSince(started) * 1000
                }
            }
            // A leg with no expectation still gets a settle time; it exists to
            // let the previous animation drain.
            if settledMs == nil, expect == nil {
                settledMs = Date().timeIntervalSince(started) * 1000
            }
            let to = "\(panelState.presentedState)"
            // Prefer the run that *finished* during this leg over the live
            // samples. `begin()` resets the live array, so a retarget — a
            // content remeasure, the next leg — would otherwise wipe the
            // numbers before they are read and report 0 fps.
            let run = IslandFrameTiming.lastRun(since: started)
            let intervals = run?.intervals ?? IslandFrameTiming.lastIntervals
            let sorted = intervals.sorted()
            let avg = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let worst = sorted.last ?? 0
            samples.append(TransitionSample(
                transition: name,
                fromState: from,
                toState: to,
                durationMs: (run?.duration ?? IslandFrameTiming.lastDuration) * 1000,
                frames: intervals.count,
                fps: avg > 0 ? 1 / avg : 0,
                averageMs: avg * 1000,
                p95Ms: p95 * 1000,
                worstMs: worst * 1000,
                wasInstant: IslandFrameTiming.lastWasInstant,
                settledMs: settledMs
            ))
        }

        func write() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(samples) { try? data.write(to: out) }
            let done = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("wechathud-transitions-done")
            try? "ok".write(to: done, atomically: true, encoding: .utf8)
        }

        // Let launch settle: the first leg would otherwise race the workspace
        // window's own first paint and measure that instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            panelState.islandSurface = .inbox
            panelState.popoverOpen = false
            panelState.collapse()
            leg("settle-compact", {}, settle: 0.5, expect: "compact")

            leg("hover-in-compact-peek", { panelState.mouseEntered() }, settle: 0.9, expect: "peek")
            // popoverOpen latches the panel open with no real cursor under it.
            leg("peek-extended", {
                panelState.popoverOpen = true
                panelState.goExtended()
            }, settle: 1.3, expect: "extended")

            leg("row-expand", {
                panelState.expandedInboxItemID = monitor.inboxItems.first?.id
            }, settle: 1.0)

            leg("collapse-open-compact", {
                panelState.expandedInboxItemID = nil
                panelState.popoverOpen = false
                panelState.collapse()
            }, settle: 1.2, expect: "extended")

            // Hold the peek. The dwell timer promotes peek → extended after
            // ~180 ms, so a hover-out measured after a hover-in would actually
            // collapse *from extended* and the peek-exit path would never be
            // exercised. Pushing the dwell out of the way keeps the panel in
            // peek for the duration of the two legs below, which is the state
            // a real cursor produces when it crosses the pill without stopping.
            CompanionMotion.hoverExpandDelayProvider = { 30 }
            leg("hover-in-second", { panelState.mouseEntered() }, settle: 0.9, expect: "peek")
            // Drive the *real* pointer-exit path, not `collapse()`. The two are
            // not the same code: `mouseExited` runs the debounce, the popover
            // and text-input guards, the mid-animation deferral, and then
            // `scheduleExitCollapse`. Measuring only `collapse()` would leave
            // the path the cursor actually takes unmeasured.
            leg("hover-out-to-compact", {
                panelState.popoverOpen = false
                panelState.mouseExited()
            }, settle: 1.6, expect: "compact")
            // Reopen so the banner legs below start from a known state.
            // Restore the live dwell before the banner legs.
            CompanionMotion.hoverExpandDelayProvider = { 0.18 }
            leg("reopen-for-banner", {
                panelState.mouseEntered()
                panelState.popoverOpen = true
                panelState.goExtended()
            }, settle: 1.2, expect: "extended")
            leg("banner-from-open", {
                panelState.popoverOpen = false
                simulateNotification(monitor: monitor, panelState: panelState, holdSeconds: 3)
            }, settle: 1.2, expect: "notification")
            leg("banner-collapse", {
                panelState.popoverOpen = false
                panelState.collapse()
            }, settle: 1.4, expect: "compact")

            write()
        }
    }

    @MainActor static func simulateEmptyIsland(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        monitor.handledItems = monitor.inboxItems + monitor.handledItems
        monitor.inboxItems = []
        monitor.stats.syncStatus = .ok
        monitor.stats.lastSyncAt = Date()
        panelState.islandSnoozeUndo = nil
        panelState.toastMessage = nil
        panelState.clearDetail()
        panelState.islandSurface = .inbox
        panelState.goExtended()
    }

    /// `--preview-peek` drives compact → peek → inbox from inside the process
    /// (no cursor). Captures each landing and writes geometry so QA can tell
    /// a mask spring from `setFrameInstantly`.
    @MainActor static func runPeekMorphCapture(panelState: PanelState) {
        guard isEnabled, CommandLine.arguments.contains("--preview-peek") else { return }
        CompanionMotion.hoverExpandDelayProvider = { 0.85 }
        panelState.collapse()
        panelState.islandSurface = .inbox
        panelState.popoverOpen = false

        func facts(_ tag: String) -> [String: Any] {
            let island = (NSApp.delegate as? AppDelegate)?.panel?.visibleIslandFrame
            return [
                "tag": tag,
                "currentState": "\(panelState.currentState)",
                "presentedState": "\(panelState.presentedState)",
                "width": island?.width ?? 0,
                "height": island?.height ?? 0,
                "instant": IslandFrameTiming.lastWasInstant,
                "durationMs": IslandFrameTiming.lastDuration * 1000,
                "fps": IslandFrameTiming.estimatedFPS,
                "worstMs": IslandFrameTiming.worstInterval * 1000,
            ]
        }

        var notes: [[String: Any]] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            notes.append(facts("compact"))
            captureSurfaces(as: "peek-compact")
            panelState.mouseEntered()
            // No real cursor: keep the island from collapsing when the mask
            // spring lands and the hit test reports the pointer outside.
            panelState.popoverOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                notes.append(facts("peek"))
                captureSurfaces(as: "peek-hover")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    notes.append(facts("peek-landed"))
                    captureSurfaces(as: "peek-landed")
                    panelState.goExtended()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    notes.append(facts("extended"))
                    captureSurfaces(as: "peek-inbox")
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("wechathud-peek-qa.json")
                    if let data = try? JSONSerialization.data(
                        withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]
                    ) {
                        try? data.write(to: url)
                    }
                    }
                }
            }
        }
    }

    /// `--preview-hold-island` pins the expanded island open and
    /// `--preview-disconnected` forces the connection-error banner, so a
    /// snapshot can capture expanded surfaces that normally collapse the
    /// moment the pointer is not inside them. Without this, QA has to move
    /// the user's pointer into the panel to keep it on screen.
    ///
    /// The expand is **deferred to the next runloop turn**, not performed here.
    ///
    /// Called inline from `applicationDidFinishLaunching`, `goExtended()` ran
    /// before the panel had laid out its first frame. The state flip and the
    /// window frame then disagreed about which shape was on screen, and the
    /// mask kept covering the whole stage while only the workspace bar painted:
    /// the flag produced a 560×252 black slab with two glyphs in the corner.
    /// An independent review measured that slab and could not reconcile it with
    /// the AX dump for the same run, because the two artifacts were of two
    /// different states — the real hover/click path renders correctly.
    ///
    /// A preview flag that manufactures the defect it exists to photograph is
    /// worse than no flag, so this now waits for the first layout, exactly as
    /// the `--preview-expand-row` path below already did.
    @MainActor static func applyIslandSnapshotOverrides(monitor: ChatMonitor, panelState: PanelState) {
        guard isEnabled else { return }
        let arguments = CommandLine.arguments
        if arguments.contains("--preview-disconnected") {
            monitor.stats.syncStatus = .error("preview")
        }
        let holdIsland = arguments.contains("--preview-hold-island")
        let expandRow = arguments.contains("--preview-expand-row")
        guard holdIsland || expandRow else { return }

        DispatchQueue.main.async {
            panelState.islandSurface = .inbox
            panelState.goExtended()
            // popoverOpen is the panel's existing "do not auto-collapse"
            // latch; reuse it rather than adding preview state to PanelState.
            panelState.popoverOpen = true

            guard expandRow else { return }
            // Let the inbox measure and the mask spring land before the row
            // opens, so this is a real click-expand, not a launch-sized panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                captureSurfaces(as: "inbox-closed")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                panelState.expandedInboxItemID = monitor.inboxItems.first?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    captureSurfaces(as: "row-expanded")
                }
            }
        }
    }

    /// `--preview-tab=<raw>` opens the workspace on one page, so every
    /// workspace surface can be captured from a repeatable launch instead of
    /// by clicking through the sidebar (which moves the operator's pointer and
    /// cannot be replayed).
    @MainActor static func applyWorkspaceTabOverride(panelState: PanelState) {
        guard isEnabled else { return }
        // `--preview-tab=<raw>` opens the workspace on one page, so every
        // workspace surface can be captured from a repeatable launch
        // instead of by clicking through the sidebar (which moves the
        // operator's pointer and cannot be replayed).
        let tabPrefix = "--preview-tab="
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix(tabPrefix) }) {
            let tab = String(raw.dropFirst(tabPrefix.count))
            if !tab.isEmpty {
                panelState.pendingSettingsTab = tab
                panelState.showDetail()
            }
        }
    }

    @MainActor static func simulateAITestFailure() {
        guard isEnabled else { return }
        pendingAITestFailure = true
        NotificationCenter.default.post(name: .hudPreviewAITestFailure, object: nil)
    }

    /// Lets an external AX walker snapshot without clicking 导出界面快照,
    /// so sheets and alerts stay on screen.
    static func installCaptureBridge() {
        guard isEnabled, !captureBridgeInstalled else { return }
        captureBridgeInstalled = true
        DistributedNotificationCenter.default().addObserver(
            forName: .hudPreviewCaptureSurfaces,
            object: nil,
            queue: .main
        ) { note in
            let tag = note.userInfo?["tag"] as? String
            MainActor.assumeIsolated {
                captureSurfaces(as: tag?.isEmpty == true ? nil : tag)
            }
        }
    }

    /// Writes PNG snapshots of the workspace, island, onboarding, and any
    /// attached sheet/alert from inside the process.
    @MainActor static func captureSurfaces(as tag: String? = nil) {
        guard isEnabled else { return }
        // Latch the panel open only for the duration of the capture. This
        // used to be set and never restored, which left popoverOpen true for
        // the rest of the process: mouseExited() refuses to collapse while a
        // popover is open, so every preview session silently stopped
        // auto-collapsing after its first snapshot — and QA then read that
        // artifact as a product bug.
        let panelState = (NSApp.delegate as? AppDelegate)?.panelState
        let wasPopoverOpen = panelState?.popoverOpen ?? false
        panelState?.popoverOpen = true
        hideDemoChromeForCapture = true
        NotificationCenter.default.post(name: .hudPreviewCaptureChrome, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        writeSurfaceBitmaps(tag: tag)
        hideDemoChromeForCapture = false
        NotificationCenter.default.post(name: .hudPreviewCaptureChrome, object: nil)
        panelState?.popoverOpen = wasPopoverOpen
        let done = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechathud-capture-done")
        try? (tag ?? "ok").write(to: done, atomically: true, encoding: .utf8)
    }

    @MainActor private static func writeSurfaceBitmaps(tag: String?) {
        let suffix = tag.map { "-\($0)" } ?? ""
        var overlayIndex = 0
        func write(_ window: NSWindow, name: String) {
            guard let view = window.contentView, view.bounds.width > 8, view.bounds.height > 8,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechathud-\(name).png")
                try? data.write(to: url)
            }
        }
        for window in NSApp.windows where window.isVisible {
            if window is FloatingPanel {
                write(window, name: "island\(suffix)")
            } else if window.identifier?.rawValue == "onboarding" {
                write(window, name: "onboarding\(suffix)")
            } else if window.title == CompanionProductCopy.brandName, window.sheetParent == nil, !window.isSheet {
                write(window, name: "workspace\(suffix)")
            } else if window.isSheet || window.sheetParent != nil || window.level.rawValue >= NSWindow.Level.modalPanel.rawValue {
                write(window, name: overlayIndex == 0 ? "overlay\(suffix)" : "overlay\(overlayIndex)\(suffix)")
                overlayIndex += 1
            }
            if let sheet = window.attachedSheet {
                write(sheet, name: overlayIndex == 0 ? "overlay\(suffix)" : "overlay\(overlayIndex)\(suffix)")
                overlayIndex += 1
            }
        }
    }
}
