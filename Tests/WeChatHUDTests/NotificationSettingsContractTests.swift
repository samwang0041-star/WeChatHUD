import XCTest
@testable import WeChatHUD

final class NotificationSettingsContractTests: XCTestCase {
    func testPageSaysWhatWillPopNow() throws {
        let source = try NotificationSettingsSource.load()
        XCTAssertTrue(source.text.contains("现在会弹出"))
        XCTAssertTrue(source.text.contains("现在浮窗不会自己弹出。"))
        XCTAssertTrue(source.text.contains("群 @"))
        XCTAssertTrue(source.text.contains("重点的人"))
        XCTAssertTrue(source.text.contains("群里 @ 我的消息"))
        XCTAssertFalse(source.text.contains("CompanionPalette.jade"))
        XCTAssertEqual(SettingsView.Tab.notifications.label, "提醒方式")
        XCTAssertEqual(
            NotificationSettingsCopy.popupLine(atMention: true, important: true, allWhitelist: false),
            "现在会弹出：群 @、重点的人。"
        )
        XCTAssertEqual(
            NotificationSettingsCopy.popupLine(atMention: false, important: false, allWhitelist: false),
            "现在浮窗不会自己弹出。"
        )
    }

    func testSaveNotesSitOnTheCanvasNotInsideTheSwitchCard() throws {
        let source = try NotificationSettingsSource.load()
        let sectionStart = try XCTUnwrap(source.text.range(of: "SettingsSection(\"谁来的消息要弹出\")"))
        let noteStart = try XCTUnwrap(source.text.range(of: "这些开关控制顶部浮窗"))
        let section = String(source.text[sectionStart.lowerBound..<noteStart.lowerBound])
        XCTAssertTrue(section.contains("展示时间"))
        XCTAssertFalse(section.contains("设置已保存"))
        XCTAssertFalse(section.contains(".font(.caption)"))
        XCTAssertTrue(source.text.contains("workspaceMeta()"))
        XCTAssertFalse(source.text.contains(".font(.caption)"))
        XCTAssertFalse(source.text.contains(".font(.callout)"))
        XCTAssertTrue(source.text.contains("现在会弹出"))
        XCTAssertTrue(source.text.contains("群里 @ 我的消息"))
        XCTAssertEqual(SettingsView.Tab.notifications.label, "提醒方式")
    }
}

private struct NotificationSettingsSource {
    let text: String

    static func load() throws -> NotificationSettingsSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("NotificationSettingsView.swift not found at \(url.path)")
        }
        return NotificationSettingsSource(text: text)
    }
}
