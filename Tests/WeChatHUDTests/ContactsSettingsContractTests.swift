import XCTest
@testable import WeChatHUD

final class ContactsSettingsContractTests: XCTestCase {
    func testListChromeSitsOnTheCanvasNotAPlateOfJadePills() throws {
        let source = try ContactsSettingsSource.load()
        let listStart = try XCTUnwrap(source.text.range(of: "private struct ContactsListSubView"))
        let addDialog = try XCTUnwrap(source.text.range(of: "private var addContactDialog"))
        let list = String(source.text[listStart.lowerBound..<addDialog.lowerBound])
        XCTAssertFalse(list.contains("companionSurface"))
        XCTAssertFalse(list.contains("CompanionFilterPill"))
        XCTAssertTrue(list.contains("contactFilterChip"))
        XCTAssertTrue(list.contains("CompanionPalette.selectedFill"))
        XCTAssertFalse(list.contains("CompanionPalette.jade"))
        XCTAssertTrue(list.contains("FirstLaunchGuide.findPeopleField"))
        XCTAssertTrue(list.contains("FirstLaunchGuide.findPeople"))
        XCTAssertTrue(list.contains("更多"))
        XCTAssertTrue(list.contains("全部"))
        XCTAssertTrue(list.contains("重点关注"))
        XCTAssertTrue(list.contains("群聊"))
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
    }

    func testAddFollowIsTheJadePrimaryAndBackIsQuiet() throws {
        let settings = try SettingsViewSource.load()
        let headerStart = try XCTUnwrap(settings.text.range(of: "if selectedTab == .contacts"))
        let headerEnd = try XCTUnwrap(settings.text.range(of: "private var headerWidth"))
        let header = String(settings.text[headerStart.lowerBound..<headerEnd.lowerBound])
        XCTAssertTrue(header.contains("CompanionProductCopy.addFollow"))
        XCTAssertTrue(header.contains("CompanionPalette.jade"))
        XCTAssertTrue(header.contains("CompanionPressStyle()"))
        XCTAssertFalse(header.contains("borderedProminent"))
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")

        let contacts = try ContactsSettingsSource.load()
        let chromeStart = try XCTUnwrap(contacts.text.range(of: "struct ContactsSettingsView"))
        let listStart = try XCTUnwrap(contacts.text.range(of: "private struct ContactsListSubView"))
        let chrome = String(contacts.text[chromeStart.lowerBound..<listStart.lowerBound])
        XCTAssertTrue(chrome.contains("返回关注列表"))
        XCTAssertTrue(chrome.contains("CompanionPressStyle()"))
        XCTAssertFalse(chrome.contains("CompanionPalette.jade"))
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testVisibleCopySpeaksMinutesAndWhoPeopleAre() throws {
        let source = try ContactsSettingsSource.load()
        XCTAssertFalse(source.text.contains("批量整理关系"))
        XCTAssertTrue(source.text.contains("看看这些人是谁"))
        XCTAssertFalse(source.text.contains("replyWindowMinutes)m"))
        let rowStart = try XCTUnwrap(source.text.range(of: "private func contactRow"))
        let saveStart = try XCTUnwrap(source.text.range(of: "private func saveContact"))
        let row = String(source.text[rowStart.lowerBound..<saveStart.lowerBound])
        XCTAssertTrue(row.contains("分钟"))
        XCTAssertTrue(source.text.contains("更多"))
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
    }

    func testInspectorBreathesWithoutDividersOrAStatusPlate() throws {
        let source = try ContactsSettingsSource.load()
        let inspectorStart = try XCTUnwrap(source.text.range(of: "private struct ContactInspectorView"))
        let block = try XCTUnwrap(source.text.range(of: "// MARK: - Block Rules"))
        let inspector = String(source.text[inspectorStart.lowerBound..<block.lowerBound])
        XCTAssertFalse(inspector.contains("Divider()"))
        XCTAssertTrue(inspector.contains("整理范围"))
        XCTAssertTrue(inspector.contains("TA 是谁"))
        XCTAssertTrue(inspector.contains("操作"))
        XCTAssertTrue(inspector.contains("选择一个人或一个群"))

        let listStart = try XCTUnwrap(source.text.range(of: "private struct ContactsListSubView"))
        let addDialog = try XCTUnwrap(source.text.range(of: "private var addContactDialog"))
        let list = String(source.text[listStart.lowerBound..<addDialog.lowerBound])
        XCTAssertFalse(list.contains("controlBackgroundColor"))
        XCTAssertTrue(source.text.contains("看看这些人是谁"))
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testListLeadsWithFiltersNotASearchField() throws {
        let source = try ContactsSettingsSource.load()
        let listStart = try XCTUnwrap(source.text.range(of: "private struct ContactsListSubView"))
        let addDialog = try XCTUnwrap(source.text.range(of: "private var addContactDialog"))
        let list = String(source.text[listStart.lowerBound..<addDialog.lowerBound])
        let filters = try XCTUnwrap(list.range(of: "contactFilterChip"))
        let search = try XCTUnwrap(list.range(of: "FirstLaunchGuide.findPeopleField"))
        XCTAssertLessThan(filters.lowerBound, search.lowerBound)
        XCTAssertTrue(list.contains("Button(FirstLaunchGuide.findPeople)"))
        XCTAssertTrue(list.contains("还没有关注的人"))
        XCTAssertTrue(list.contains("CompanionProductCopy.addFollow"))
        XCTAssertEqual(FirstLaunchGuide.findPeople, "找人")
        XCTAssertEqual(FirstLaunchGuide.findPeopleField, "搜索联系人或群聊")
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testInspectorSpeaksAccountAndLookAgain() throws {
        let source = try ContactsSettingsSource.load()
        XCTAssertFalse(source.text.contains("微信 ID"))
        XCTAssertFalse(source.text.contains("重新整理"))
        XCTAssertTrue(source.text.contains("再看看"))
        let inspectorStart = try XCTUnwrap(source.text.range(of: "private struct ContactInspectorView"))
        let block = try XCTUnwrap(source.text.range(of: "// MARK: - Block Rules"))
        let inspector = String(source.text[inspectorStart.lowerBound..<block.lowerBound])
        XCTAssertTrue(inspector.contains("账号"))
        XCTAssertTrue(inspector.contains("再看看"))
        XCTAssertTrue(inspector.contains("TA 是谁"))
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testAddDialogIsAListNotATallyOrLecture() throws {
        let source = try ContactsSettingsSource.load()
        let dialogStart = try XCTUnwrap(source.text.range(of: "private var addContactDialog"))
        let candidatesStart = try XCTUnwrap(source.text.range(of: "private func addCandidates"))
        let dialog = String(source.text[dialogStart.lowerBound..<candidatesStart.lowerBound])
        XCTAssertFalse(dialog.contains("已选"))
        XCTAssertFalse(dialog.contains("只开始整理选中的对话"))
        XCTAssertTrue(dialog.contains("CompanionProductCopy.addFollow"))
        XCTAssertTrue(dialog.contains("取消"))
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")

        let listStart = try XCTUnwrap(source.text.range(of: "private struct ContactsListSubView"))
        let dialogMark = try XCTUnwrap(source.text.range(of: "private var addContactDialog"))
        let list = String(source.text[listStart.lowerBound..<dialogMark.lowerBound])
        XCTAssertTrue(list.contains("Menu(\"不看和静音\")"))
        XCTAssertTrue(list.contains("不看谁"))
        XCTAssertTrue(list.contains("静音"))
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testListRowsAndLookAgainGiveUnderPress() throws {
        let source = try ContactsSettingsSource.load()
        let rowStart = try XCTUnwrap(source.text.range(of: "private func contactRow"))
        let saveStart = try XCTUnwrap(source.text.range(of: "private func saveContact"))
        let row = String(source.text[rowStart.lowerBound..<saveStart.lowerBound])
        XCTAssertTrue(row.contains("CompanionPressStyle()"))
        XCTAssertFalse(row.contains("buttonStyle(.plain)"))

        let profileStart = try XCTUnwrap(source.text.range(of: "private func aiProfileSection"))
        let opsStart = try XCTUnwrap(source.text.range(of: "private func operationsSection"))
        let profile = String(source.text[profileStart.lowerBound..<opsStart.lowerBound])
        XCTAssertTrue(profile.contains("再看看"))
        XCTAssertTrue(profile.contains("CompanionPressStyle()"))
        XCTAssertFalse(profile.contains("buttonStyle(.bordered)"))
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }

    func testInspectorSpeaksWhatWillHappenNotASpecSheet() throws {
        let source = try ContactsSettingsSource.load()
        let trackingStart = try XCTUnwrap(source.text.range(of: "private func trackingSection"))
        let profileStart = try XCTUnwrap(source.text.range(of: "private func aiProfileSection"))
        let tracking = String(source.text[trackingStart.lowerBound..<profileStart.lowerBound])
        XCTAssertTrue(tracking.contains("trackingReason(contact)"))
        XCTAssertFalse(tracking.contains("只整理已关注的对话"))
        XCTAssertFalse(tracking.contains("infoRow(\"关注级别\""))
        XCTAssertFalse(tracking.contains("infoRow(\"提醒时机\""))
        XCTAssertTrue(source.text.contains("优先提醒该回的消息。"))
        XCTAssertTrue(source.text.contains("会整理这个人的聊天。"))
        XCTAssertTrue(source.text.contains("不日常提醒。"))

        let opsStart = try XCTUnwrap(source.text.range(of: "private func operationsSection"))
        let profile = String(source.text[profileStart.lowerBound..<opsStart.lowerBound])
        XCTAssertTrue(profile.contains("正在看这个人是谁。"))
        XCTAssertEqual(CompanionProductCopy.addFollow, "添加关注")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
    }
}

private struct ContactsSettingsSource {
    let text: String

    static func load() throws -> ContactsSettingsSource {
        ContactsSettingsSource(text: try readSource("Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift"))
    }
}

private struct SettingsViewSource {
    let text: String

    static func load() throws -> SettingsViewSource {
        SettingsViewSource(text: try readSource("Sources/WeChatHUD/Views/Settings/SettingsView.swift"))
    }
}

private func readSource(_ relativePath: String) throws -> String {
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
