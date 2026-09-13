import XCTest
@testable import WeChatHUD

/// The autopilot page used to contradict itself about group chats and about
/// what the batch option measures, and it offered a dead "clear history"
/// instruction. These tests pin the copy to the behaviour the send gate
/// actually enforces (see AutopilotSafetyTests for the gate itself).
final class AutopilotCopyConsistencyTests: XCTestCase {

    // MARK: - Group-chat promise

    func testGroupChatRuleMatchesTheSendGate() {
        // ChatMonitor's gate always holds group replies for manual confirmation,
        // so the copy may promise a draft but never an unattended send.
        XCTAssertTrue(AutopilotSettingsCopy.groupRule.contains("群聊默认只记录"), AutopilotSettingsCopy.groupRule)
        XCTAssertTrue(AutopilotSettingsCopy.groupRule.contains("待确认草稿"), AutopilotSettingsCopy.groupRule)
        XCTAssertTrue(AutopilotSettingsCopy.groupRule.contains("不会自动发出"), AutopilotSettingsCopy.groupRule)
        XCTAssertFalse(
            AutopilotSettingsCopy.groupRule.contains("仅记录，不自动发送回复"),
            "The old advanced-page wording contradicted the toggle's wording."
        )
    }

    func testEveryGroupChatPromiseOnThePageIsTheSameSentence() throws {
        let source = try AutopilotViewSource.load()
        // The toggle and the advanced section must not each own their own
        // version of the promise.
        XCTAssertEqual(
            source.occurrences(of: "AutopilotSettingsCopy.groupRule"),
            2,
            "The rule is stated once and reused; the view still renders it twice."
        )
        XCTAssertFalse(source.text.contains("群 @ 会写成待确认草稿"), "old contradictory string")
        XCTAssertFalse(source.text.contains("群聊消息仅记录，不自动发送回复"), "old contradictory string")
    }

    // MARK: - Exclusion wording

    func testExclusionCopySaysWhatHappensRatherThanTheReverse() {
        // The verb is now "these people are never auto-replied to"; the button
        // adds the contact TO the exclusion set, which the old "排除" framing
        // described backwards.
        XCTAssertEqual(AutopilotSettingsCopy.excludedTitle(count: 3), "不会自动回复的人 (3)")
        XCTAssertEqual(AutopilotSettingsCopy.excludedAddButton, "添加排除对象")
        XCTAssertTrue(AutopilotSettingsCopy.excludedEmpty.contains("不会被自动回复"))
        XCTAssertEqual(AutopilotSettingsCopy.excludedTitle(count: 0), "不会自动回复的人 (0)")
    }

    // MARK: - Batch window

    func testBatchCopyNamesTheUnitItActuallyUses() {
        // The picker writes seconds into AutopilotConfig.batchWindowSeconds, so
        // "连着几条一起回" read as a message count and got it wrong.
        XCTAssertTrue(AutopilotSettingsCopy.batchTitle.contains("秒"), AutopilotSettingsCopy.batchTitle)
        XCTAssertTrue(AutopilotSettingsCopy.batchHint.contains("秒"), AutopilotSettingsCopy.batchHint)
        XCTAssertTrue(AutopilotSettingsCopy.batchHint.contains("不是条数"), AutopilotSettingsCopy.batchHint)
        XCTAssertFalse(AutopilotSettingsCopy.batchTitle.contains("几条"), "counts are not the unit")
    }

    func testBatchOptionsRemainASecondsWindow() {
        // Values move with the config; the test locks the semantics, not a
        // specific number: each option is a duration, and the default stays
        // what it always was.
        let options = [5, 10, 15, 30]
        XCTAssertTrue(options.allSatisfy { $0 > 0 && $0 <= 60 })
        XCTAssertEqual(AutopilotConfig().batchWindowSeconds, 10)
    }

    func testBatchSettingSitsInTheMainSectionNotOnlyUnderAdvanced() throws {
        let source = try AutopilotViewSource.load()
        let mainRange = try XCTUnwrap(source.text.range(of: "limitsBatchRow"))
        let advancedRange = try XCTUnwrap(source.text.range(of: "DisclosureGroup(AutopilotSettingsCopy.advancedTitle)"))
        XCTAssertLessThan(mainRange.lowerBound, advancedRange.lowerBound, "the window is visible without opening 高级设置")
        XCTAssertFalse(source.text.contains("DisclosureGroup(\"高级设置\")"), "the window left the advanced disclosure group")
    }

    func testBatchWindowIsARowNotANestedCard() throws {
        let source = try AutopilotViewSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private var limitsBatchRow"))
        let end = try XCTUnwrap(source.text.range(of: "// MARK: - Exclusion"))
        let row = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("SettingsRow(AutopilotSettingsCopy.batchTitle"))
        XCTAssertFalse(row.contains("SettingsSection("), "a second card inside 自动回复 broke the one-surface rule")
    }

    func testMainSendRowsUseWorkspaceTypeNotNakedSystemFonts() throws {
        let source = try AutopilotViewSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private var confidenceRow"))
        let end = try XCTUnwrap(source.text.range(of: "// MARK: - Exclusion"))
        let rows = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(rows.contains("SettingsRow(AutopilotSettingsCopy.confidenceTitle"))
        XCTAssertTrue(rows.contains("AutopilotSettingsCopy.confidenceHint"))
        XCTAssertTrue(rows.contains("SettingsRow(AutopilotSettingsCopy.alwaysManualTitle"))
        XCTAssertTrue(rows.contains("AutopilotSettingsCopy.alwaysManualRule"))
        XCTAssertFalse(rows.contains(".font(.system"))
        XCTAssertTrue(rows.contains("WorkspaceType.body"))
        XCTAssertEqual(AutopilotSettingsCopy.confidenceTitle, "多有把握才发出去")
        XCTAssertTrue(AutopilotSettingsCopy.confidenceHint.contains("只写草稿"))
        XCTAssertFalse(AutopilotSettingsCopy.confidenceHint.contains("门槛"))
        XCTAssertFalse(AutopilotSettingsCopy.confidenceHint.contains("发送限制"))
    }

    func testSendLimitsAndExclusionsSitUnderAdvanced() throws {
        let source = try AutopilotViewSource.load()
        let advanced = try XCTUnwrap(source.text.range(of: "DisclosureGroup(AutopilotSettingsCopy.advancedTitle)"))
        let hourly = try XCTUnwrap(source.text.range(of: "AutopilotSettingsCopy.perHourTitle"))
        let session = try XCTUnwrap(source.text.range(of: "AutopilotSettingsCopy.sessionTitle"))
        XCTAssertGreaterThan(hourly.lowerBound, advanced.lowerBound)
        XCTAssertGreaterThan(session.lowerBound, advanced.lowerBound)
        XCTAssertFalse(source.text.contains("DisclosureGroup(\"不自动回复的人\")"))
        XCTAssertTrue(source.text.contains("exclusionSection"))
        let advancedBlock = String(source.text[advanced.lowerBound...])
        XCTAssertTrue(advancedBlock.contains("exclusionSection"))
    }

    func testPendingLinkIsNotThePrimaryAction() throws {
        let source = try AutopilotViewSource.load()
        let body = try XCTUnwrap(source.text.range(of: "var body: some View"))
        let section = try XCTUnwrap(source.text.range(of: "SettingsSection(\"自动回复\")"))
        let header = String(source.text[body.lowerBound..<section.lowerBound])
        XCTAssertTrue(header.contains("AutopilotSettingsCopy.openPending"))
        XCTAssertTrue(header.contains("pendingSettingsTab = \"autopilotDashboard\""))
        XCTAssertTrue(header.contains(".workspaceMeta()"))
        XCTAssertFalse(header.contains("weight: .medium"), "the pending link used to look like the page's next step")
        let button = try XCTUnwrap(header.range(of: "Button(AutopilotSettingsCopy.openPending)"))
        let pending = String(header[button.lowerBound...])
        XCTAssertFalse(pending.contains("CompanionPalette.jade"), "jade is reserved for the send switch, not this navigation")
        XCTAssertTrue(pending.contains("CompanionPressStyle()"))
        XCTAssertFalse(pending.contains(".buttonStyle(.plain)"))
        XCTAssertEqual(AutopilotSettingsCopy.openPending, "查看待确认回复")
        XCTAssertEqual(AutopilotSettingsCopy.statusIdle, "尚未开始整理")
        XCTAssertEqual(AutopilotSettingsCopy.statusActive, "正在整理回复")
    }

    // MARK: - Clear history

    func testClearHistoryFailureDoesNotInventAPrecondition() {
        XCTAssertTrue(AutopilotSettingsCopy.historyClearFailed.contains("记录没清掉"))
        XCTAssertTrue(AutopilotSettingsCopy.historyClearFailed.contains("请稍后重试"))
        XCTAssertTrue(
            AutopilotSettingsCopy.historyClearFailed.contains("已发出的消息不受影响"),
            "The consequence users care about must be in the failure message."
        )
        XCTAssertFalse(
            AutopilotSettingsCopy.historyClearFailed.contains("停止自动回复"),
            "Clearing history never required stopping autopilot."
        )
    }

    // MARK: - Reachability of the service switcher

    func testChangeServiceButtonGoesThroughTheRealTabSwitch() throws {
        let source = try AISettingsSource.load()
        XCTAssertTrue(source.text.contains("Button(\"更换服务\") { switchToAIServiceTab() }"))
        XCTAssertFalse(
            source.text.contains("Button(\"更换服务\") {\n                selectedSection = .service"),
            "Writing selectedSection alone is a no-op while lockedSection is set."
        )
        XCTAssertTrue(source.text.contains("NotificationCenter.default.post(name: .hudSwitchTab, object: \"aiService\")"))
    }

    func testOpenEverythingRowSaysItOpensToday() throws {
        let source = try InboxViewSource.load()
        XCTAssertTrue(source.text.contains("IslandInboxCopy.moreInWorkspace"))
        XCTAssertTrue(source.text.contains("pendingSettingsTab = \"today\""))
        XCTAssertFalse(source.text.contains("查看全部（新窗口）"), "users do not think in windows")
        XCTAssertFalse(source.text.contains("更多 — 查看详情"), "the old label promised in-place expansion")
        XCTAssertEqual(IslandInboxCopy.moreInWorkspace(4), "还有 4 条，打开今天查看")
        XCTAssertEqual(IslandInboxCopy.tasks, "待办")
        XCTAssertEqual(IslandInboxCopy.openToday, "今天")
    }

    func testApprovalPageLeadsWithTheQueueNotASessionDashboard() throws {
        let source = try ApprovalWorkspaceSource.load()
        XCTAssertTrue(source.text.contains("ApprovalCopy.confirmSend"))
        XCTAssertTrue(source.text.contains("AutopilotStartCopy.start"))
        XCTAssertTrue(source.text.contains("ApprovalWorkspacePolicy.statusSentence"))
        XCTAssertFalse(source.text.contains("ContentUnavailableView"))
        XCTAssertFalse(source.text.contains("arrow.triangle.2.circlepath"))
        XCTAssertEqual(ApprovalCopy.confirmSend, "确认发送")
        XCTAssertEqual(ApprovalCopy.emptyPending, "还没有待确认的回复")

        guard let toolbar = source.text.range(of: "private var toolbar"),
              let empty = source.text.range(of: "private var emptyState"),
              let start = source.text.range(of: "AutopilotStartCopy.start") else {
            XCTFail("toolbar, empty state, and 开始整理 should all still exist")
            return
        }
        XCTAssertLessThan(toolbar.lowerBound, empty.lowerBound)
        XCTAssertGreaterThan(start.lowerBound, empty.lowerBound, "开始整理 belongs in the empty state, not the header dashboard")

        guard let confirm = source.text.range(of: "ApprovalCopy.confirmSend"),
              let save = source.text.range(of: "ApprovalCopy.saveDraft") else {
            XCTFail("confirm and save should sit together")
            return
        }
        let actions = String(source.text[confirm.lowerBound..<save.lowerBound])
        XCTAssertTrue(actions.contains("tint(CompanionPalette.jade)"))
        XCTAssertTrue(actions.contains("borderedProminent"))
    }

    func testApprovalReplyIsAReplyNotAnAIDraft() throws {
        let source = try ApprovalWorkspaceSource.load()
        XCTAssertTrue(source.text.contains("ApprovalCopy.reply"))
        XCTAssertFalse(source.text.contains("拟回复"))
        XCTAssertFalse(source.text.contains("AI 草稿"))
        XCTAssertFalse(source.text.contains("sparkles"))
        XCTAssertFalse(source.text.contains("text.badge.star"))
        XCTAssertFalse(source.text.contains("CompanionBadge"))
        XCTAssertEqual(ApprovalCopy.reply, "回复")
    }

    func testApprovalQueueRowsPress() throws {
        let source = try ApprovalWorkspaceSource.load()
        guard let listStart = source.text.range(of: "private var listPane"),
              let listEnd = source.text.range(of: "private func statusLabel") else {
            XCTFail("queue rows live in listPane")
            return
        }
        let list = String(source.text[listStart.lowerBound..<listEnd.lowerBound])
        XCTAssertTrue(list.contains("CompanionPressStyle()"))
        XCTAssertFalse(list.contains(".buttonStyle(.plain)"))
    }

    func testApprovalDetailUsesWorkspaceTypeAndPressesOpenChat() throws {
        let source = try ApprovalWorkspaceSource.load()
        guard let detailStart = source.text.range(of: "private var detailPane"),
              let detailEnd = source.text.range(of: "private func reconcileSelection") else {
            XCTFail("detail pane should still sit above reconcileSelection")
            return
        }
        let detail = String(source.text[detailStart.lowerBound..<detailEnd.lowerBound])
        XCTAssertTrue(detail.contains("ApprovalCopy.openChat"))
        XCTAssertTrue(detail.contains("CompanionPressStyle()"))
        XCTAssertFalse(detail.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(detail.contains(".font(.system"))
        XCTAssertTrue(detail.contains(".workspaceBody()"))
        XCTAssertTrue(detail.contains(".workspaceMeta()"))
        XCTAssertEqual(ApprovalCopy.openChat, "查看聊天记录")
    }

    func testApprovalWorkspaceHasNoNakedSystemFonts() throws {
        let source = try ApprovalWorkspaceSource.load()
        XCTAssertFalse(
            source.text.contains(".font(.system"),
            "approval chrome should use workspace type tokens, not ad-hoc system sizes"
        )
    }

    func testIslandGearNamesTheWorkspaceItOpens() throws {
        let source = try InboxViewSource.load()
        guard let wingStart = source.text.range(of: "Right wing —"),
              let wingEnd = source.text.range(of: "private var liveNotchWidth") else {
            XCTFail("the notch right wing should still be the gear's home")
            return
        }
        let wing = String(source.text[wingStart.lowerBound..<wingEnd.lowerBound])
        XCTAssertTrue(wing.contains("IslandInboxCopy.openSettings"))
        XCTAssertTrue(wing.contains("IslandInboxCopy.openSettingsHelp"))
        XCTAssertTrue(wing.contains("CompanionPressStyle()"))
        XCTAssertFalse(wing.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(wing.contains("CompanionProductCopy.openCompanion"))
        XCTAssertFalse(wing.contains(".font(.system(size: 11))"))
        XCTAssertEqual(IslandInboxCopy.openSettings, "设置")
        XCTAssertEqual(IslandInboxCopy.openSettingsHelp, "打开设置")
    }

    func testIslandActionPanelSpeaksHumanWhenOrganizingOrStuck() throws {
        let panel = try ActionPanelViewSource.load()
        XCTAssertTrue(panel.text.contains("IslandActionCopy.organizing"))
        XCTAssertTrue(panel.text.contains("IslandActionCopy.unreadTitle"))
        XCTAssertTrue(panel.text.contains("IslandActionCopy.unreadHint"))
        XCTAssertTrue(panel.text.contains("IslandActionCopy.retry"))
        XCTAssertFalse(panel.text.contains("分析暂不可用"))
        XCTAssertFalse(panel.text.contains("AI 正在整理重点"))
        XCTAssertFalse(panel.text.contains("分析失败"))
        XCTAssertFalse(panel.text.contains("语气依据"))
        XCTAssertEqual(IslandActionCopy.organizing, "正在整理这条消息…")
        XCTAssertEqual(IslandActionCopy.unreadTitle, "先看原文")
        XCTAssertEqual(IslandActionCopy.retry, "再试一次")

        let item = try InboxItemSource.load()
        XCTAssertTrue(item.text.contains("IslandActionCopy.organizingShort"))
        XCTAssertTrue(item.text.contains("IslandActionCopy.unreadTitle"))
        XCTAssertFalse(item.text.contains("分析暂不可用"))
        XCTAssertFalse(item.text.contains("AI 正在整理重点"))
    }

    func testIslandActionPanelHasOneEmphasizedJadePill() throws {
        let source = try ActionPanelViewSource.load()
        XCTAssertTrue(source.text.contains("IslandPillButtonStyle(emphasized: true)"))
        XCTAssertTrue(source.text.contains("IslandPillButtonStyle()"))
        XCTAssertFalse(
            source.text.contains(".background(Color.accentColor)"),
            "The primary action used the system accent, which is not jade on the island."
        )
        XCTAssertFalse(source.text.contains(".cornerRadius(6)"))
        XCTAssertFalse(
            source.text.contains("Color.accentColor"),
            "Expanded analysis chrome must use island mint / IslandInk, not the system accent."
        )
        XCTAssertFalse(source.text.contains("color = .green"))
        XCTAssertFalse(source.text.contains("color = .blue"))
    }

    func testIslandBriefingLeadsWithOneJadeReply() throws {
        let source = try GroupContextBriefingSource.load()
        XCTAssertTrue(source.text.contains("IslandPillButtonStyle(emphasized: true)"))
        XCTAssertTrue(source.text.contains("IslandPillButtonStyle()"))
        XCTAssertTrue(source.text.contains("IslandBriefingCopy.title"))
        XCTAssertFalse(source.text.contains("AI 解读"))
        XCTAssertFalse(source.text.contains("为什么 @ 你"))
        XCTAssertFalse(source.text.contains("查看完整上下文"))
        XCTAssertFalse(source.text.contains("Color.orange"))
        XCTAssertEqual(IslandBriefingCopy.title, "为什么找你")
        XCTAssertEqual(IslandBriefingCopy.retry, "再试一次")
    }

    func testIslandBriefingDropsNestedCards() throws {
        let source = try GroupContextBriefingSource.load()
        XCTAssertTrue(source.text.contains("quietLine(label:"))
        XCTAssertFalse(source.text.contains("func card("))
        XCTAssertFalse(source.text.contains("cornerRadius: 8"))
        XCTAssertFalse(source.text.contains("IslandInk.hover, in: RoundedRectangle"))
        XCTAssertEqual(IslandBriefingCopy.situation, "在聊")
        XCTAssertEqual(IslandBriefingCopy.next, "下一步")
    }

    func testCollapsedBannerPressesTheMessageNotTheHitLayer() throws {
        let source = try NotificationBannerViewSource.load()
        XCTAssertTrue(source.text.contains("BannerCardPressStyle"))
        XCTAssertTrue(source.text.contains("CompanionMotion.pressScale"))
        XCTAssertTrue(source.text.contains("IslandInk.hoverPressed"))
        XCTAssertTrue(source.text.contains(".buttonStyle(BannerCardPressStyle(pressed: $pressingCard))"))
        XCTAssertFalse(source.text.contains(".buttonStyle(.plain)"))
    }

    func testCompactWingsUseIslandInkNotTrafficLights() throws {
        let source = try CompactInboxBarSource.load()
        XCTAssertTrue(source.text.contains("IslandChrome.glowRed"))
        XCTAssertTrue(source.text.contains("IslandChrome.glowAmber"))
        XCTAssertTrue(source.text.contains(".islandMeta()"))
        XCTAssertFalse(source.text.contains("Color.red"))
        XCTAssertFalse(source.text.contains("Color.yellow"))
        XCTAssertFalse(source.text.contains("Color.blue"))
        XCTAssertFalse(source.text.contains("badgeSize"))
        XCTAssertFalse(source.text.contains(".font(.system(size: CompactInboxMetrics.badgeSize"))
    }

    func testIslandSnoozeMenuRowsPress() throws {
        let source = try InboxRowViewSource.load()
        guard let menuStart = source.text.range(of: "struct IslandSnoozeMenu"),
              let menuEnd = source.text.range(of: "struct SnoozePopoverContent") else {
            XCTFail("IslandSnoozeMenu should sit next to SnoozePopoverContent")
            return
        }
        let menu = String(source.text[menuStart.lowerBound..<menuEnd.lowerBound])
        XCTAssertTrue(menu.contains("CompanionPressStyle()"))
        XCTAssertFalse(menu.contains(".buttonStyle(.plain)"))
    }
}

// MARK: - Source readers

private struct AutopilotViewSource {
    let text: String

    func occurrences(of needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func load() throws -> AutopilotViewSource {
        AutopilotViewSource(text: try read("Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift"))
    }
}

private struct AISettingsSource {
    let text: String
    static func load() throws -> AISettingsSource {
        AISettingsSource(text: try read("Sources/WeChatHUD/Views/Settings/AISettingsView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct InboxViewSource {
    let text: String
    static func load() throws -> InboxViewSource {
        InboxViewSource(text: try read("Sources/WeChatHUD/Views/InboxView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct ActionPanelViewSource {
    let text: String
    static func load() throws -> ActionPanelViewSource {
        ActionPanelViewSource(text: try read("Sources/WeChatHUD/Views/ActionPanelView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct InboxItemSource {
    let text: String
    static func load() throws -> InboxItemSource {
        InboxItemSource(text: try read("Sources/WeChatHUD/Data/InboxItem.swift"))
    }
    init(text: String) { self.text = text }
}

private struct GroupContextBriefingSource {
    let text: String
    static func load() throws -> GroupContextBriefingSource {
        GroupContextBriefingSource(text: try read("Sources/WeChatHUD/Views/GroupContextBriefingButton.swift"))
    }
    init(text: String) { self.text = text }
}

private struct NotificationBannerViewSource {
    let text: String
    static func load() throws -> NotificationBannerViewSource {
        NotificationBannerViewSource(text: try read("Sources/WeChatHUD/Views/NotificationBannerView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct InboxRowViewSource {
    let text: String
    static func load() throws -> InboxRowViewSource {
        InboxRowViewSource(text: try read("Sources/WeChatHUD/Views/InboxRowView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct CompactInboxBarSource {
    let text: String
    static func load() throws -> CompactInboxBarSource {
        CompactInboxBarSource(text: try read("Sources/WeChatHUD/Views/CompactInboxBar.swift"))
    }
    init(text: String) { self.text = text }
}

private struct ApprovalWorkspaceSource {
    let text: String
    static func load() throws -> ApprovalWorkspaceSource {
        ApprovalWorkspaceSource(text: try read("Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift"))
    }
    init(text: String) { self.text = text }
}

private func read(_ relativePath: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw XCTSkip("\(relativePath) not found at \(url.path)")
    }
    return text
}
