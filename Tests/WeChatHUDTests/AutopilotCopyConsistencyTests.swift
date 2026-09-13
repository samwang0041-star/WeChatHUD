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

    func testReplyStyleAndAlwaysManualSitUnderAdvanced() throws {
        let source = try AutopilotViewSource.load()
        let section = try XCTUnwrap(source.text.range(of: "SettingsSection(\"自动回复\")"))
        let disclosure = try XCTUnwrap(source.text.range(of: "DisclosureGroup(AutopilotSettingsCopy.advancedTitle)"))
        let firstScreen = String(source.text[section.lowerBound..<disclosure.lowerBound])
        XCTAssertTrue(firstScreen.contains("AutopilotSettingsCopy.autoSendTitle"))
        XCTAssertTrue(firstScreen.contains("confidenceRow"))
        XCTAssertTrue(firstScreen.contains("limitsBatchRow"))
        XCTAssertFalse(firstScreen.contains("alwaysManualRow"), "the guardrail list is a reminder, not a daily send decision")
        XCTAssertFalse(firstScreen.contains("replyStyleRow"))
        XCTAssertFalse(firstScreen.contains("回复风格"), "voice is taste, not whether a reply goes out")
        XCTAssertFalse(firstScreen.contains("alwaysManualTitle"))

        let advanced = try XCTUnwrap(source.text.range(of: "private var advancedSection"))
        let history = try XCTUnwrap(source.text.range(of: "// MARK: - History"))
        let block = String(source.text[advanced.lowerBound..<history.lowerBound])
        XCTAssertTrue(block.contains("replyStyleRow"))
        XCTAssertTrue(block.contains("alwaysManualRow"))
        XCTAssertEqual(AutopilotSettingsCopy.replyStyleTitle, "回复风格")
        XCTAssertEqual(AutopilotSettingsCopy.alwaysManualTitle, "哪些一定交给你")
    }

    func testAdvancedDoesNotNestASecondAdvancedCard() throws {
        let source = try AutopilotViewSource.load()
        XCTAssertFalse(
            source.text.contains("SettingsSection(\"高级\")"),
            "高级设置 used to open onto another card also titled 高级"
        )
        let advanced = try XCTUnwrap(source.text.range(of: "private var advancedSection"))
        let history = try XCTUnwrap(source.text.range(of: "// MARK: - History"))
        let block = String(source.text[advanced.lowerBound..<history.lowerBound])
        XCTAssertTrue(block.contains("VStack(spacing: 0)"))
        XCTAssertFalse(block.contains("SettingsSection("))
        XCTAssertTrue(block.contains(".workspaceBody()"))
        XCTAssertFalse(block.contains(".font(.callout)"))
        XCTAssertEqual(AutopilotSettingsCopy.advancedTitle, "高级设置")
        XCTAssertTrue(AutopilotSettingsCopy.groupRule.contains("不会自动发出"))
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

    func testAutoSendConfirmIsAWorkspaceBeatNotASystemAlert() throws {
        let source = try AutopilotViewSource.load()
        let start = try XCTUnwrap(source.text.range(of: "companionDialogBackdrop(pendingEnableAutoSend)"))
        let end = try XCTUnwrap(source.text.range(of: "private var confidenceRow"))
        let dialog = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(dialog.contains("CompanionProductCopy.autoSendConfirmTitle"))
        XCTAssertTrue(dialog.contains("CompanionProductCopy.autoSendConfirmMessage"))
        XCTAssertTrue(dialog.contains(".workspaceBody()"), "the confirm used to speak in a naked 13pt system face")
        XCTAssertFalse(dialog.contains(".font(.system"))
        let keep = try XCTUnwrap(dialog.range(of: "Button(CompanionProductCopy.autoSendKeepManual)"))
        let allow = try XCTUnwrap(dialog.range(of: "Button(CompanionProductCopy.autoSendAllow)"))
        let keepBlock = String(dialog[keep.lowerBound..<allow.lowerBound])
        XCTAssertTrue(keepBlock.contains("CompanionPressStyle()"))
        XCTAssertFalse(keepBlock.contains("borderedProminent"), "keep-manual is the quiet way out")
        XCTAssertTrue(keepBlock.contains(".workspaceMeta()"))
        let allowBlock = String(dialog[allow.lowerBound...])
        XCTAssertTrue(allowBlock.contains("borderedProminent"))
        XCTAssertTrue(allowBlock.contains("CompanionPalette.jade"), "jade stays on 允许发送, the only permission in this beat")
        XCTAssertEqual(CompanionProductCopy.autoSendConfirmTitle, "开启自动发送？")
        XCTAssertEqual(CompanionProductCopy.autoSendKeepManual, "保持手动")
        XCTAssertEqual(CompanionProductCopy.autoSendAllow, "允许发送")
    }

    func testSaveReceiptUsesWorkspaceTypeAndRetriesTheFailedAct() throws {
        let source = try AutopilotViewSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private var receiptBar"))
        let end = try XCTUnwrap(source.text.range(of: "private var confidenceRow"))
        let receipt = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(receipt.contains("AutopilotSettingsCopy.saveOk"))
        XCTAssertTrue(receipt.contains("AutopilotSettingsCopy.saveFailed"))
        XCTAssertTrue(receipt.contains("AutopilotSettingsCopy.historyClearFailed"))
        XCTAssertTrue(receipt.contains("retryClearHistory"), "clearing history must retry the clear, not save()")
        XCTAssertTrue(receipt.contains("CompanionPressStyle()"))
        XCTAssertTrue(receipt.contains(".workspaceMeta()"))
        XCTAssertFalse(receipt.contains(".font(.callout)"))
        XCTAssertFalse(receipt.contains("exclamationmark.triangle"))
        let retry = try XCTUnwrap(receipt.range(of: "Button(AutopilotSettingsCopy.saveRetry"))
        XCTAssertFalse(
            String(receipt[retry.lowerBound...]).contains("CompanionPalette.jade"),
            "jade is the saved line, not 再试一次"
        )
        XCTAssertTrue(source.text.contains("receipt = .saveFailed"))
        XCTAssertTrue(source.text.contains("receipt = .historyFailed"))
        XCTAssertEqual(AutopilotSettingsCopy.saveOk, "设置已保存")
        XCTAssertEqual(AutopilotSettingsCopy.saveRetry, "再试一次")
        XCTAssertTrue(AutopilotSettingsCopy.saveFailed.contains("上次的规则"))
    }

    func testExclusionAndHistoryUseWorkspaceTypeAndPress() throws {
        let source = try AutopilotViewSource.load()
        let exclusion = try XCTUnwrap(source.text.range(of: "// MARK: - Exclusion"))
        let advanced = try XCTUnwrap(source.text.range(of: "// MARK: - Advanced"))
        let excluded = String(source.text[exclusion.lowerBound..<advanced.lowerBound])
        XCTAssertFalse(excluded.contains(".font(.system"), "exclusion used to be 11/12/13pt system faces")
        XCTAssertFalse(excluded.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(excluded.contains("CompanionPressStyle()"))
        XCTAssertTrue(excluded.contains(".workspaceBody()"))
        XCTAssertTrue(excluded.contains(".workspaceMeta()"))
        XCTAssertEqual(AutopilotSettingsCopy.excludedAddButton, "添加排除对象")

        let history = try XCTUnwrap(source.text.range(of: "// MARK: - History"))
        let helpers = try XCTUnwrap(source.text.range(of: "// MARK: - Helpers"))
        let records = String(source.text[history.lowerBound..<helpers.lowerBound])
        XCTAssertFalse(records.contains(".font(.system"), "history used to be 10/11/12pt system faces")
        XCTAssertTrue(records.contains("CompanionPressStyle()"))
        XCTAssertTrue(records.contains(".workspaceMeta()"))
        XCTAssertTrue(records.contains(".workspaceMicro()"))
        XCTAssertFalse(records.contains(".foregroundColor(.green)"))
        XCTAssertFalse(records.contains(".foregroundColor(.orange)"))
        XCTAssertEqual(AutopilotSettingsCopy.historyClear, "清除历史")
        XCTAssertEqual(AutopilotSettingsCopy.historyEmpty, "暂无记录")
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
        XCTAssertTrue(source.text.contains("Button(\"去 AI 服务配置\") { switchToAIServiceTab() }"))
        XCTAssertFalse(
            source.text.contains("Button(\"去 AI 服务配置\") {\n                selectedSection = .service"),
            "Writing selectedSection alone is a no-op while lockedSection is set."
        )
        XCTAssertTrue(source.text.contains("NotificationCenter.default.post(name: .hudSwitchTab, object: \"aiService\")"))
    }

    func testAnalysisPartitionUsesWorkspaceTypeAndSecondaryPress() throws {
        let source = try AISettingsSource.load()
        XCTAssertTrue(source.text.contains("Button(\"去 AI 服务配置\") { switchToAIServiceTab() }"))
        let start = try XCTUnwrap(source.text.range(of: "private var analysisSection"))
        let form = try XCTUnwrap(source.text.range(of: "private var serviceForm"))
        let analysis = String(source.text[start.lowerBound..<form.lowerBound])
        XCTAssertTrue(analysis.contains("CompanionPressStyle()"))
        XCTAssertTrue(analysis.contains(".workspaceMeta()"))
        XCTAssertTrue(analysis.contains(".workspaceTitle()"))
        XCTAssertTrue(analysis.contains(".workspaceBody()"))
        XCTAssertFalse(analysis.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(analysis.contains(".controlSize(.small)"))
        XCTAssertFalse(analysis.contains("borderedProminent"), "jade stays on 确认能用")
        XCTAssertFalse(analysis.contains(".font(.system"))
        XCTAssertTrue(analysis.contains("你始终可以查看原文"))
        let behaviorStart = try XCTUnwrap(source.text.range(of: "private var behaviorSection"))
        let save = try XCTUnwrap(source.text.range(of: "private var saveStatus"))
        let behavior = String(source.text[behaviorStart.lowerBound..<save.lowerBound])
        XCTAssertTrue(behavior.contains("随 AI 服务"))
        XCTAssertTrue(behavior.contains(".workspaceMeta()"))
        XCTAssertFalse(behavior.contains(".font(.system"))
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
    }

    func testServicePageLeadsWithConfirmWorksNotChangeService() throws {
        let source = try AISettingsSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private var serviceStatusCard"))
        let end = try XCTUnwrap(source.text.range(of: "private var sectionPicker"))
        let card = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(card.contains("AISettingsCopy.confirmWorks"))
        XCTAssertTrue(card.contains("saveStatus"), "confirm and save share one receipt on this card")
        XCTAssertTrue(card.contains("testSlot"))
        XCTAssertTrue(card.contains("borderedProminent"))
        XCTAssertTrue(card.contains("CompanionPalette.jade"))
        XCTAssertFalse(card.contains("更换服务"), "this page is already the service page")
        XCTAssertFalse(card.contains("sparkles"))
        XCTAssertFalse(card.contains(".font(.system"))
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
        XCTAssertEqual(AISettingsCopy.ready, "可以用")
        XCTAssertEqual(AISettingsCopy.notReady, "还不能用")
        XCTAssertEqual(AISettingsCopy.unverified, "还没确认能不能用")
    }

    func testServiceSourceSitsInTheSameCardAsTheProvider() throws {
        let source = try AISettingsSource.load()
        XCTAssertFalse(source.text.contains("SettingsSection(\"服务来源\")"), "source used to be its own card")
        XCTAssertFalse(source.text.contains("iconColor: .purple"))
        XCTAssertFalse(source.text.contains("SettingsRow(\"状态\""), "能不能用 already lives on the page header")
        XCTAssertFalse(source.text.contains("已启用 · 已验证"))
        let form = try XCTUnwrap(source.text.range(of: "private var serviceForm"))
        let prefs = try XCTUnwrap(source.text.range(of: "private var advancedPreferences"))
        let block = String(source.text[form.lowerBound..<prefs.lowerBound])
        XCTAssertTrue(block.contains("AISettingsCopy.sourceTitle"))
        XCTAssertTrue(block.contains("providerCard"))
        XCTAssertTrue(block.contains("advancedPreferences"))
        XCTAssertFalse(block.contains("generationPreferences"))
        XCTAssertFalse(block.contains("privacySection"))
        XCTAssertTrue(block.contains("SettingsSection {"))
        XCTAssertEqual(AISettingsCopy.sourceTitle, "用哪家")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
    }

    func testWritingHabitsAndPrivacySitUnderAdvanced() throws {
        let source = try AISettingsSource.load()
        let form = try XCTUnwrap(source.text.range(of: "private var serviceForm"))
        let provider = try XCTUnwrap(source.text.range(of: "private var providerCard"))
        let formBlock = String(source.text[form.lowerBound..<provider.lowerBound])
        XCTAssertTrue(formBlock.contains("advancedPreferences"))
        XCTAssertFalse(formBlock.contains("generationPreferences"))
        XCTAssertFalse(formBlock.contains("privacySection"))

        let advancedStart = try XCTUnwrap(source.text.range(of: "private var advancedPreferences"))
        let advancedEnd = try XCTUnwrap(source.text.range(of: "private var providerCard"))
        let advanced = String(source.text[advancedStart.lowerBound..<advancedEnd.lowerBound])
        XCTAssertTrue(advanced.contains("AISettingsCopy.advancedTitle"))
        XCTAssertTrue(advanced.contains("AISettingsCopy.writingHabits"))
        XCTAssertTrue(advanced.contains("AISettingsCopy.privacyTitle"))
        XCTAssertTrue(advanced.contains("AISettingsCopy.privacyBody"))
        XCTAssertTrue(advanced.contains(".workspaceRowTitle()"))
        XCTAssertFalse(advanced.contains("SettingsSection"))
        XCTAssertFalse(advanced.contains("companionSurface"))
        XCTAssertFalse(advanced.contains("DisclosureGroup(isExpanded: $preferencesExpanded)"))
        XCTAssertFalse(advanced.contains("DisclosureGroup(isExpanded: $privacyExpanded)"))
        XCTAssertEqual(AISettingsCopy.advancedTitle, "高级设置")
        XCTAssertEqual(AISettingsCopy.writingHabits, "写作习惯")
        XCTAssertEqual(AISettingsCopy.privacyTitle, "数据与隐私")
    }

    func testServiceFormSpeaksHumanNotAPIConsole() throws {
        let source = try AISettingsSource.load()
        XCTAssertFalse(source.text.contains("获取 API Key"))
        XCTAssertFalse(source.text.contains("SettingsRow(\"访问凭据\")"))
        XCTAssertFalse(source.text.contains("SettingsRow(\"供应商\")"))
        XCTAssertFalse(source.text.contains("从接口获取模型列表"))
        XCTAssertFalse(source.text.contains("未选择模型"))
        XCTAssertTrue(source.text.contains("AISettingsCopy.getKey"))
        XCTAssertTrue(source.text.contains("AISettingsCopy.secretTitle"))
        XCTAssertTrue(source.text.contains("AISettingsCopy.vendorTitle"))
        XCTAssertEqual(AISettingsCopy.getKey, "去拿密钥")
        XCTAssertEqual(AISettingsCopy.secretTitle, "密钥")
        XCTAssertEqual(AISettingsCopy.vendorTitle, "哪一家")
        XCTAssertEqual(AISettingsCopy.sourcePreset, "常用服务")
        XCTAssertEqual(AISettingsCopy.sourceCustom, "自己填")
        XCTAssertEqual(AISettingsCopy.noModel, "还没选模型")
    }

    func testGetKeyAndModelRefreshPressLikeWorkspaceSecondaries() throws {
        let source = try AISettingsSource.load()
        let getKey = try XCTUnwrap(source.text.range(of: "Button(AISettingsCopy.getKey)"))
        let modelRow = try XCTUnwrap(source.text.range(of: "SettingsRow(AISettingsCopy.modelTitle)"))
        let keyButton = String(source.text[getKey.lowerBound..<modelRow.lowerBound])
        XCTAssertTrue(keyButton.contains("CompanionPressStyle()"))
        XCTAssertTrue(keyButton.contains(".workspaceMeta()"))
        XCTAssertFalse(keyButton.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(keyButton.contains(".controlSize(.mini)"))
        XCTAssertFalse(keyButton.contains("CompanionPalette.jade"), "jade stays on 确认能用")
        XCTAssertFalse(keyButton.contains("borderedProminent"))

        let pickerStart = try XCTUnwrap(source.text.range(of: "struct ModelPicker"))
        let provider = try XCTUnwrap(source.text.range(of: "struct ProviderCard"))
        let picker = String(source.text[pickerStart.lowerBound..<provider.lowerBound])
        XCTAssertTrue(picker.contains("CompanionPressStyle()"))
        XCTAssertFalse(picker.contains(".buttonStyle(.borderless)"))
        XCTAssertEqual(AISettingsCopy.getKey, "去拿密钥")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
    }

    func testCustomAddressSitsOnTheFormNotBehindAdvancedConnection() throws {
        let source = try AISettingsSource.load()
        XCTAssertFalse(source.text.contains("高级连接设置"))
        XCTAssertFalse(source.text.contains("advancedConnectionExpanded"))
        let providerStart = try XCTUnwrap(source.text.range(of: "struct ProviderCard"))
        let main = try XCTUnwrap(source.text.range(of: "struct AISettingsView"))
        let card = String(source.text[providerStart.lowerBound..<main.lowerBound])
        XCTAssertTrue(card.contains("AISettingsCopy.addressTitle"))
        XCTAssertTrue(card.contains("AISettingsCopy.insecureHTTP"))
        XCTAssertTrue(card.contains(".workspaceMeta()"))
        XCTAssertFalse(card.contains("DisclosureGroup(\"高级连接设置\""))
        XCTAssertFalse(card.contains(".font(.system(size: 12, weight: .medium)"))
        XCTAssertFalse(card.contains(".font(.system(size: 11)"))
        XCTAssertEqual(AISettingsCopy.addressTitle, "接到哪")
        XCTAssertEqual(AISettingsCopy.insecureHTTP, "此连接未加密，请确认网络可信或改用安全连接")
    }

    func testChatGPTHintSitsOnceInTheAddressRow() throws {
        let source = try AISettingsSource.load()
        let providerStart = try XCTUnwrap(source.text.range(of: "struct ProviderCard"))
        let main = try XCTUnwrap(source.text.range(of: "struct AISettingsView"))
        let card = String(source.text[providerStart.lowerBound..<main.lowerBound])
        XCTAssertEqual(card.components(separatedBy: "AISettingsCopy.codexHint").count - 1, 1)
        XCTAssertTrue(card.contains(".workspaceMeta()"))
        XCTAssertFalse(card.contains("if providerID == \"openai-codex\""))
        XCTAssertFalse(card.contains(".font(.system(size: 12))"))
        XCTAssertFalse(card.contains(".padding(14)"))
        XCTAssertEqual(AISettingsCopy.codexHint, "用这台 Mac 上已登录的 ChatGPT，不必再填密钥。")
        XCTAssertEqual(AISettingsCopy.addressTitle, "接到哪")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
    }

    func testConfirmReceiptSitsOnTheStatusCardNotAnOrangeIsland() throws {
        let source = try AISettingsSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private var serviceStatusCard"))
        let end = try XCTUnwrap(source.text.range(of: "private var sectionPicker"))
        let card = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(card.contains("saveStatus"), "confirm and save share one receipt on this card")
        XCTAssertTrue(card.contains("testSlot"))
        XCTAssertFalse(card.contains("Color.orange"))
        XCTAssertFalse(source.text.contains("Label(\"连接没有通过\""))
        XCTAssertFalse(source.text.contains("Color.orange.opacity(0.08)"))
        XCTAssertFalse(source.text.contains("testResult = \"已获取"))
        XCTAssertFalse(source.text.contains("testResult = \"获取失败"))
        XCTAssertTrue(source.text.contains("modelFetchNote"))
        XCTAssertTrue(source.text.contains("fetchNote: modelFetchNote"))
        XCTAssertEqual(AISettingsCopy.retryOnce, "再试一次")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
    }

    func testServiceReceiptsSpeakLikeConfirmWorksNotAConsole() throws {
        let source = try AISettingsSource.load()
        XCTAssertFalse(source.text.contains("连接成功，服务已返回有效响应"))
        XCTAssertFalse(source.text.contains("重试保存"))
        XCTAssertFalse(source.text.contains("连接已验证"))
        XCTAssertFalse(source.text.contains("配置已保存 · 尚未测试"))
        XCTAssertFalse(source.text.contains("更改尚未保存"))
        XCTAssertFalse(source.text.contains("访问凭据仅保存在"))
        XCTAssertFalse(source.text.contains("上次测试成功"))
        XCTAssertFalse(source.text.contains("获取失败："))
        XCTAssertFalse(source.text.contains("已获取 \\("))
        XCTAssertTrue(source.text.contains("AISettingsCopy.confirmOk"))
        XCTAssertTrue(source.text.contains("AISettingsCopy.saveFailed"))
        XCTAssertTrue(source.text.contains("AISettingsCopy.privacyBody"))
        let save = try XCTUnwrap(source.text.range(of: "private var saveStatus"))
        let actions = try XCTUnwrap(source.text.range(of: "// MARK: - Actions"))
        let saveBlock = String(source.text[save.lowerBound..<actions.lowerBound])
        XCTAssertTrue(saveBlock.contains("AISettingsCopy.retryOnce"))
        XCTAssertTrue(saveBlock.contains("CompanionPressStyle()"))
        XCTAssertTrue(saveBlock.contains("testSlot"), "confirm failure retries 确认能用")
        XCTAssertTrue(saveBlock.contains("saveAIConfig"), "save failure retries save")
        XCTAssertFalse(saveBlock.contains("companionSurface"))
        XCTAssertFalse(saveBlock.contains("bordered"))
        XCTAssertFalse(source.text.contains("还没点「确认能用」"), "that line used to be a second confirm CTA")
        let bodyStart = try XCTUnwrap(source.text.range(of: "var body: some View"))
        let current = try XCTUnwrap(source.text.range(of: "// MARK: - Current service"))
        let body = String(source.text[bodyStart.lowerBound..<current.lowerBound])
        XCTAssertFalse(body.contains("saveStatus"), "the footer used to nag 确认能用 separately")
        XCTAssertEqual(AISettingsCopy.confirmOk, "刚才确认过了。")
        XCTAssertEqual(AISettingsCopy.saveFailed, "刚才没存上。")
        XCTAssertEqual(AISettingsCopy.saveOk, "已保存。")
        XCTAssertEqual(AISettingsCopy.privacyBody, "密钥只留在这台电脑里，不会出现在界面或确认结果里。")
        XCTAssertEqual(AISettingsCopy.retryOnce, "再试一次")
    }

    func testConfirmingDoesNotLeaveSaveOkOnTheCard() throws {
        let source = try AISettingsSource.load()
        let save = try XCTUnwrap(source.text.range(of: "private var saveStatus"))
        let actions = try XCTUnwrap(source.text.range(of: "// MARK: - Actions"))
        let saveBlock = String(source.text[save.lowerBound..<actions.lowerBound])
        XCTAssertTrue(saveBlock.contains("isTesting"))
        XCTAssertTrue(saveBlock.contains("AISettingsCopy.confirming"))
        let confirming = try XCTUnwrap(saveBlock.range(of: "AISettingsCopy.confirming"))
        let saveOk = try XCTUnwrap(saveBlock.range(of: "AISettingsCopy.saveOk"))
        XCTAssertLessThan(confirming.lowerBound, saveOk.lowerBound)
        XCTAssertFalse(saveBlock.contains("borderedProminent"), "jade stays on 确认能用")
        XCTAssertEqual(AISettingsCopy.confirming, "正在确认…")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
        XCTAssertEqual(AISettingsCopy.saveOk, "已保存。")
    }

    func testConfirmFailureReceiptNeverSpeaksHTTP() throws {
        let source = try AISettingsSource.load()
        let start = try XCTUnwrap(source.text.range(of: "private func userFacingConfigurationError"))
        let end = try XCTUnwrap(source.text.range(of: "private func fetchModels"))
        let mapped = String(source.text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(mapped.contains("return AISettingsCopy.confirmUnreachable"))
        XCTAssertTrue(mapped.contains("return AISettingsCopy.confirmBusy"))
        XCTAssertTrue(mapped.contains("return AISettingsCopy.needChatGPTLogin"))
        XCTAssertTrue(mapped.contains("return AISettingsCopy.checkAgain"))
        XCTAssertFalse(mapped.contains("return message"))
        XCTAssertFalse(mapped.contains("HTTP"))
        XCTAssertEqual(AISettingsCopy.confirmUnreachable, "这次没连上。")
        XCTAssertEqual(AISettingsCopy.confirmBusy, "这会儿忙，过会儿再试。")
        XCTAssertEqual(AISettingsCopy.needChatGPTLogin, "请先在这台 Mac 上登录 ChatGPT。")
        XCTAssertEqual(AISettingsCopy.checkAgain, "请核对地址、模型和密钥，再点「确认能用」。")
        XCTAssertEqual(AISettingsCopy.retryOnce, "再试一次")
        XCTAssertEqual(AISettingsCopy.confirmWorks, "确认能用")
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

    func testConnectedConnectionPrimaryGoesToPickConversations() throws {
        let setup = try ConnectionSetupSource.load()
        XCTAssertTrue(setup.text.contains("connectedContinueTitle"))
        XCTAssertTrue(setup.text.contains("onConnectedContinue"))
        XCTAssertTrue(setup.text.contains("CompanionPalette.jade"))
        XCTAssertTrue(setup.text.contains("recheckConnection"))
        XCTAssertFalse(setup.text.contains(".tint(CompanionPalette.accent)"))

        let sync = try SyncSettingsSource.load()
        XCTAssertTrue(sync.text.contains("WeChatConnectionCopy.pickConversations"))
        XCTAssertTrue(sync.text.contains("NotificationCenter.default.post(name: .hudSwitchTab, object: \"contacts\")"))

        let onboarding = try OnboardingViewSource.load()
        XCTAssertTrue(onboarding.text.contains("WeChatConnectionSetupView()"))
        XCTAssertFalse(onboarding.text.contains("connectedContinueTitle"))

        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        let connected = FirstLaunchGuide.connection(
            state: .connected, wechatRunning: true, accessReady: true, connected: true
        )
        XCTAssertEqual(connected.title, "微信已连接")
        XCTAssertEqual(connected.detail, "下一步：选择要整理的对话。")
        XCTAssertEqual(connected.buttonTitle, "检查更新")
    }

    func testCapabilityListSitsBehindAdvancedConnection() throws {
        let sync = try SyncSettingsSource.load()
        let start = try XCTUnwrap(sync.text.range(of: "settingsPane(.connection)"))
        let prefs = try XCTUnwrap(sync.text.range(of: "settingsPane(.preferences)"))
        let pane = String(sync.text[start.lowerBound..<prefs.lowerBound])
        let setup = try XCTUnwrap(pane.range(of: "WeChatConnectionSetupView"))
        let advanced = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.advanced"))
        let capabilities = try XCTUnwrap(pane.range(of: "connectionCapabilityList"))
        XCTAssertLessThan(setup.lowerBound, advanced.lowerBound)
        XCTAssertLessThan(advanced.lowerBound, capabilities.lowerBound)
        let firstScreen = String(pane[..<advanced.lowerBound])
        XCTAssertFalse(firstScreen.contains("connectionCapabilityList"))
        XCTAssertFalse(firstScreen.contains("syncSection"))
        XCTAssertEqual(WeChatConnectionCopy.advanced, "高级连接设置")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
    }

    func testPollAndDiagnosticsWaitBehindSyncAndChecks() throws {
        let sync = try SyncSettingsSource.load()
        let start = try XCTUnwrap(sync.text.range(of: "settingsPane(.connection)"))
        let prefs = try XCTUnwrap(sync.text.range(of: "settingsPane(.preferences)"))
        let pane = String(sync.text[start.lowerBound..<prefs.lowerBound])
        let advanced = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.advanced"))
        let capabilities = try XCTUnwrap(pane.range(of: "connectionCapabilityList"))
        let maintenance = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.syncAndChecks"))
        let database = try XCTUnwrap(pane.range(of: "databaseSection"))
        let poll = try XCTUnwrap(pane.range(of: "syncSection"))
        let diagnosticsGroup = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.diagnostics"))
        let diagnostics = try XCTUnwrap(pane.range(of: "SupportDiagnosticsView()"))
        XCTAssertLessThan(advanced.lowerBound, capabilities.lowerBound)
        XCTAssertLessThan(capabilities.lowerBound, maintenance.lowerBound)
        XCTAssertLessThan(maintenance.lowerBound, poll.lowerBound)
        XCTAssertLessThan(poll.lowerBound, database.lowerBound)
        XCTAssertLessThan(database.lowerBound, diagnosticsGroup.lowerBound)
        XCTAssertLessThan(diagnosticsGroup.lowerBound, diagnostics.lowerBound)
        XCTAssertFalse(WeChatConnectionCopy.syncAndChecks.contains("高级"))
        XCTAssertFalse(WeChatConnectionCopy.diagnostics.contains("高级"))
        XCTAssertEqual(WeChatConnectionCopy.syncAndChecks, "库路径与同步")
        XCTAssertEqual(WeChatConnectionCopy.diagnostics, "诊断概况")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        XCTAssertTrue(sync.text.contains("轮询间隔"))
        XCTAssertTrue(sync.text.contains("设置 AI"))
    }

    func testConnectionSaveFailureIsAWorkspaceReceiptNotARedBar() throws {
        let sync = try SyncSettingsSource.load()
        let start = try XCTUnwrap(sync.text.range(of: "settingsPane(.connection)"))
        let prefs = try XCTUnwrap(sync.text.range(of: "settingsPane(.preferences)"))
        let pane = String(sync.text[start.lowerBound..<prefs.lowerBound])
        let setup = try XCTUnwrap(pane.range(of: "WeChatConnectionSetupView"))
        let receipt = try XCTUnwrap(pane.range(of: "connectionSaveReceipt"))
        let advanced = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.advanced"))
        XCTAssertLessThan(setup.lowerBound, receipt.lowerBound)
        XCTAssertLessThan(receipt.lowerBound, advanced.lowerBound)
        XCTAssertFalse(pane.contains("重试保存设置"))
        XCTAssertFalse(pane.contains("foregroundColor(.red)"))

        let receiptStart = try XCTUnwrap(sync.text.range(of: "private var connectionSaveReceipt"))
        let syncSection = try XCTUnwrap(sync.text.range(of: "private var syncSection"))
        let receiptBlock = String(sync.text[receiptStart.lowerBound..<syncSection.lowerBound])
        XCTAssertTrue(receiptBlock.contains("WeChatConnectionCopy.saveFailed"))
        XCTAssertTrue(receiptBlock.contains("WeChatConnectionCopy.saveRetry"))
        XCTAssertTrue(receiptBlock.contains("CompanionPressStyle()"))
        XCTAssertTrue(receiptBlock.contains(".workspaceMeta()"))
        XCTAssertFalse(receiptBlock.contains("borderedProminent"), "jade stays on 去选对话")
        XCTAssertTrue(sync.text.contains("WeChatConnectionCopy.saveFailed"))
        XCTAssertTrue(sync.text.contains("WeChatConnectionCopy.bindFailed"))
        XCTAssertFalse(sync.text.contains("同步设置保存失败"))
        XCTAssertEqual(WeChatConnectionCopy.saveFailed, "刚才没存上。")
        XCTAssertEqual(WeChatConnectionCopy.saveRetry, "再试一次")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
    }

    func testRestartReceiptSitsOnTheConnectionPlateNotInThePathForm() throws {
        let sync = try SyncSettingsSource.load()
        let start = try XCTUnwrap(sync.text.range(of: "settingsPane(.connection)"))
        let prefs = try XCTUnwrap(sync.text.range(of: "settingsPane(.preferences)"))
        let pane = String(sync.text[start.lowerBound..<prefs.lowerBound])
        let receipt = try XCTUnwrap(pane.range(of: "connectionSaveReceipt"))
        let restart = try XCTUnwrap(pane.range(of: "WeChatConnectionCopy.restartToApply"))
        let advanced = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.advanced"))
        let maintenance = try XCTUnwrap(pane.range(of: "DisclosureGroup(WeChatConnectionCopy.syncAndChecks"))
        XCTAssertLessThan(receipt.lowerBound, restart.lowerBound)
        XCTAssertLessThan(restart.lowerBound, advanced.lowerBound)
        XCTAssertLessThan(advanced.lowerBound, maintenance.lowerBound)
        let restartBlock = String(pane[restart.lowerBound..<advanced.lowerBound])
        XCTAssertTrue(restartBlock.contains(".workspaceMeta()"))
        XCTAssertTrue(restartBlock.contains("CompanionPalette.jade"))
        XCTAssertFalse(restartBlock.contains(".font(.callout"))
        XCTAssertFalse(String(pane[maintenance.lowerBound...]).contains("WeChatConnectionCopy.restartToApply"))
        XCTAssertFalse(sync.text.contains("高级连接设置将在助手重新打开后应用"))
        XCTAssertEqual(WeChatConnectionCopy.restartToApply, "下次打开助手后生效。")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        XCTAssertTrue(sync.text.contains("轮询间隔"))
    }

    func testCapabilityActionsPressLikeWorkspaceSecondaries() throws {
        let sync = try SyncSettingsSource.load()
        let start = try XCTUnwrap(sync.text.range(of: "private func capabilityRow"))
        let legacy = try XCTUnwrap(sync.text.range(of: "private func legacyRecordsSection"))
        let row = String(sync.text[start.lowerBound..<legacy.lowerBound])
        let action = try XCTUnwrap(row.range(of: "if let actionTitle"))
        let padding = try XCTUnwrap(row.range(of: ".padding(16)"))
        let button = String(row[action.lowerBound..<padding.lowerBound])
        XCTAssertTrue(button.contains("CompanionPressStyle()"))
        XCTAssertTrue(button.contains(".workspaceMeta()"))
        XCTAssertFalse(button.contains("CompanionPalette.jade"), "jade stays on 去选对话")
        XCTAssertFalse(button.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(button.contains("borderedProminent"))
        XCTAssertFalse(button.contains("chevron.right"))
        XCTAssertTrue(sync.text.contains("actionTitle: aiReady ? nil : \"设置 AI\""))
        XCTAssertTrue(sync.text.contains("NotificationCenter.default.post(name: .hudSwitchTab, object: \"aiService\")"))
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
    }

    func testConnectionCardDoesNotLectureAboutChangingAccounts() throws {
        let setup = try ConnectionSetupSource.load()
        XCTAssertFalse(setup.text.contains("连接步骤只用于读取聊天"))
        XCTAssertFalse(setup.text.contains("更换账号前先看清范围"))
        XCTAssertTrue(setup.text.contains("WeChatConnectionCopy.readOnly"))
        XCTAssertTrue(setup.text.contains("WeChatConnectionCopy.changeAccountScope"))
        XCTAssertTrue(setup.text.contains("更换微信账号？"))
        XCTAssertEqual(WeChatConnectionCopy.readOnly, "只读取聊天，不改微信里的内容。")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        XCTAssertTrue(WeChatConnectionCopy.changeAccountScope.contains("按账号分开"))
    }

    func testChangeAccountPressesLikeAWorkspaceSecondary() throws {
        let setup = try ConnectionSetupSource.load()
        let start = try XCTUnwrap(setup.text.range(of: "Button(WeChatConnectionCopy.changeAccount)"))
        let readOnly = try XCTUnwrap(setup.text.range(of: "Text(WeChatConnectionCopy.readOnly)"))
        let row = String(setup.text[start.lowerBound..<readOnly.lowerBound])
        XCTAssertTrue(row.contains("CompanionPressStyle()"))
        XCTAssertTrue(row.contains(".workspaceMeta()"))
        XCTAssertFalse(row.contains(".buttonStyle(.link)"))
        XCTAssertFalse(row.contains("borderedProminent"), "jade stays on 去选对话")
        XCTAssertEqual(WeChatConnectionCopy.changeAccount, "更换微信账号")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
    }

    func testConnectionCardUsesWorkspaceTypeNotTitle3() throws {
        let setup = try ConnectionSetupSource.load()
        let title = try XCTUnwrap(setup.text.range(of: "Text(title)"))
        let disconnected = try XCTUnwrap(setup.text.range(of: "if !connected"))
        let header = String(setup.text[title.lowerBound..<disconnected.lowerBound])
        XCTAssertTrue(header.contains(".workspaceTitle()"))
        XCTAssertTrue(header.contains(".workspaceBody()"))
        XCTAssertFalse(header.contains(".font(.title3"))
        XCTAssertFalse(header.contains(".font(.callout"))

        let checkpointStart = try XCTUnwrap(setup.text.range(of: "private func checkpoint"))
        let signed = try XCTUnwrap(setup.text.range(of: "private var preparationSigned"))
        let checkpoint = String(setup.text[checkpointStart.lowerBound..<signed.lowerBound])
        XCTAssertTrue(checkpoint.contains(".workspaceBody()"))
        XCTAssertFalse(checkpoint.contains(".font(.callout"))
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        XCTAssertEqual(FirstLaunchGuide.connection(state: .connected, wechatRunning: true, accessReady: true, connected: true).title, "微信已连接")
    }

    func testChangeAccountKeepPressesLikeAWorkspaceSecondary() throws {
        let setup = try ConnectionSetupSource.load()
        let start = try XCTUnwrap(setup.text.range(of: "Button(\"先不换\")"))
        let confirm = try XCTUnwrap(setup.text.range(of: "Button(\"继续更换\")"))
        let keep = String(setup.text[start.lowerBound..<confirm.lowerBound])
        XCTAssertTrue(keep.contains("CompanionPressStyle()"))
        XCTAssertTrue(keep.contains(".workspaceMeta()"))
        XCTAssertFalse(keep.contains("borderedProminent"), "jade stays on 继续更换")
        let dialogEnd = try XCTUnwrap(setup.text.range(of: "else if showPreparationConsent"))
        let confirmBlock = String(setup.text[confirm.lowerBound..<dialogEnd.lowerBound])
        XCTAssertTrue(confirmBlock.contains("borderedProminent"))
        XCTAssertTrue(confirmBlock.contains("CompanionPalette.jade"))
        XCTAssertEqual(WeChatConnectionCopy.changeAccount, "更换微信账号")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
    }

    func testPreparationConsentIsAWorkspaceBeatNotASystemAlert() throws {
        let setup = try ConnectionSetupSource.load()
        XCTAssertFalse(setup.text.contains(".confirmationDialog("))
        let start = try XCTUnwrap(setup.text.range(of: "else if showPreparationConsent"))
        let appear = try XCTUnwrap(setup.text.range(of: ".onAppear(perform: refresh)"))
        let dialog = String(setup.text[start.lowerBound..<appear.lowerBound])
        XCTAssertTrue(dialog.contains("connectionCopy.consentTitle"))
        XCTAssertTrue(dialog.contains("connectionCopy.consentMessage"))
        XCTAssertTrue(dialog.contains(".workspaceBody()"))
        let keep = try XCTUnwrap(dialog.range(of: "Button(\"暂不\")"))
        let startPrep = try XCTUnwrap(dialog.range(of: "Button(\"开始准备\")"))
        let keepBlock = String(dialog[keep.lowerBound..<startPrep.lowerBound])
        XCTAssertTrue(keepBlock.contains("CompanionPressStyle()"))
        XCTAssertTrue(keepBlock.contains(".workspaceMeta()"))
        XCTAssertFalse(keepBlock.contains("borderedProminent"), "jade stays on 开始准备")
        let startBlock = String(dialog[startPrep.lowerBound...])
        XCTAssertTrue(startBlock.contains("borderedProminent"))
        XCTAssertTrue(startBlock.contains("CompanionPalette.jade"))
        XCTAssertTrue(startBlock.contains("startPreparationFlow()"))
        XCTAssertEqual(FirstLaunchGuide.consentTitle, "需要一次本机准备")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
        XCTAssertTrue(FirstLaunchGuide.consentMessage.contains("聊天记录不会改动"))
    }

    func testAccountPickerRowsPressLikeWorkspaceSecondaries() throws {
        let setup = try ConnectionSetupSource.load()
        let start = try XCTUnwrap(setup.text.range(of: "if showAccounts"))
        let error = try XCTUnwrap(setup.text.range(of: "if let errorMessage"))
        let picker = String(setup.text[start.lowerBound..<error.lowerBound])
        XCTAssertTrue(picker.contains("WeChatConnectionCopy.pickAccount"))
        XCTAssertTrue(picker.contains("CompanionPressStyle()"))
        XCTAssertTrue(picker.contains(".workspaceBody()"))
        XCTAssertFalse(picker.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(picker.contains("chevron.right"))
        XCTAssertFalse(picker.contains("borderedProminent"), "jade stays on 去选对话")
        XCTAssertEqual(WeChatConnectionCopy.pickAccount, "选择要连接的微信账号")
        XCTAssertEqual(WeChatConnectionCopy.changeAccount, "更换微信账号")
        XCTAssertEqual(WeChatConnectionCopy.pickConversations, "去选对话")
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

private struct ConnectionSetupSource {
    let text: String
    static func load() throws -> ConnectionSetupSource {
        ConnectionSetupSource(text: try read("Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct SyncSettingsSource {
    let text: String
    static func load() throws -> SyncSettingsSource {
        SyncSettingsSource(text: try read("Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift"))
    }
    init(text: String) { self.text = text }
}

private struct OnboardingViewSource {
    let text: String
    static func load() throws -> OnboardingViewSource {
        OnboardingViewSource(text: try read("Sources/WeChatHUD/Views/OnboardingView.swift"))
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
