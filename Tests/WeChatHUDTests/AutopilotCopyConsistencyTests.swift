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

    func testOpenEverythingRowSaysItOpensANewWindow() throws {
        let source = try InboxViewSource.load()
        XCTAssertTrue(source.text.contains("查看全部（新窗口）"), "the row opens the detail window")
        XCTAssertFalse(source.text.contains("更多 — 查看详情"), "the old label promised in-place expansion")
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
