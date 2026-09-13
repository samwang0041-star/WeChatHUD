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
}

private struct ContactsSettingsSource {
    let text: String

    static func load() throws -> ContactsSettingsSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("ContactsSettingsView.swift not found at \(url.path)")
        }
        return ContactsSettingsSource(text: text)
    }
}
