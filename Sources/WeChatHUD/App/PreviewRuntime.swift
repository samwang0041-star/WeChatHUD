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
    static var largeType = false
    static var usingExternalDisplay = false
    static var hideDemoChromeForCapture = false
    private static var captureBridgeInstalled = false

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

    static func applyAccessibilityOverrides() {
        CompanionMotion.reduceMotionProvider = {
            reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        CompanionMotion.reduceTransparencyProvider = {
            reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
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
                                                longForm: Bool = false) {
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
            panelState.showNotification(duration: TimeInterval(config.durationSeconds))
        }
    }

    @MainActor static func seed(store: HUDStore, monitor: ChatMonitor) {
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
        if let app = NSApp.delegate as? AppDelegate {
            app.panelState.popoverOpen = true
        }
        hideDemoChromeForCapture = true
        NotificationCenter.default.post(name: .hudPreviewCaptureChrome, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        writeSurfaceBitmaps(tag: tag)
        hideDemoChromeForCapture = false
        NotificationCenter.default.post(name: .hudPreviewCaptureChrome, object: nil)
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
