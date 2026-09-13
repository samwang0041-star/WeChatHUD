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
        XCTAssertTrue(list.contains("搜索联系人或群聊"))
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
