import XCTest
@testable import WeChatHUD

final class PreferencesSettingsContractTests: XCTestCase {
    func testPageSaysWhereTheHUDSits() throws {
        let source = try PreferencesSettingsSource.load()
        let prefsStart = try XCTUnwrap(source.text.range(of: "settingsPane(.preferences)"))
        let dataStart = try XCTUnwrap(source.text.range(of: "settingsPane(.data)"))
        let pane = String(source.text[prefsStart.lowerBound..<dataStart.lowerBound])
        XCTAssertTrue(pane.contains("PreferencesCopy.hudLine"))
        XCTAssertTrue(pane.contains("displaySection"))
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertTrue(source.text.contains("显示位置"))
        XCTAssertEqual(PreferencesCopy.hudLine(.builtIn), "浮窗在原生屏幕。")
        XCTAssertEqual(PreferencesCopy.hudLine(.external), "浮窗在扩展屏。")
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testDisplayLocationIconIsNotJade() throws {
        let source = try PreferencesSettingsSource.load()
        let displayStart = try XCTUnwrap(source.text.range(of: "private var displaySection"))
        let footerStart = try XCTUnwrap(source.text.range(of: "static func connectionFooter"))
        let display = String(source.text[displayStart.lowerBound..<footerStart.lowerBound])
        XCTAssertTrue(display.contains("displayTitle"))
        XCTAssertFalse(display.contains("CompanionPalette.jade"))
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testPermissionNotesSitOnTheCanvasNotInsideTheCard() throws {
        let source = try MacExperienceSettingsSource.load()
        let sectionStart = try XCTUnwrap(source.text.range(of: "SettingsSection(\"macOS 体验与权限\")"))
        let noteStart = try XCTUnwrap(source.text.range(of: "关闭这个窗口后"))
        let section = String(source.text[sectionStart.lowerBound..<noteStart.lowerBound])
        XCTAssertTrue(section.contains("登录时启动"))
        XCTAssertFalse(section.contains("关闭这个窗口后"))
        XCTAssertFalse(source.text.contains("更改已保存"))
        XCTAssertTrue(source.text.contains("workspaceMeta()"))
        let prefs = try PreferencesSettingsSource.load()
        XCTAssertTrue(prefs.text.contains("浮窗在"))
        XCTAssertTrue(prefs.text.contains("显示位置"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testPreferenceCopySpeaksLikeAPerson() throws {
        XCTAssertEqual(PreferencesCopy.displaySubtitle, "浮窗出现在哪块屏。那块屏不在时用还连着的。")
        XCTAssertFalse(PreferencesCopy.displaySubtitle.contains("未连接所选屏幕"))
        let mac = try MacExperienceSettingsSource.load()
        XCTAssertTrue(mac.text.contains("跳转微信和发出回复要用。读聊天不用这个。"))
        XCTAssertTrue(mac.text.contains("系统开了减少动态或减少透明，这里会跟着走。"))
        XCTAssertFalse(mac.text.contains("不影响读取聊天"))
        let prefs = try PreferencesSettingsSource.load()
        XCTAssertTrue(prefs.text.contains("浮窗在"))
        XCTAssertTrue(prefs.text.contains("显示位置"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testUpdatesWaitBehindADisclosure() throws {
        let source = try PreferencesSettingsSource.load()
        let prefsStart = try XCTUnwrap(source.text.range(of: "settingsPane(.preferences)"))
        let dataStart = try XCTUnwrap(source.text.range(of: "settingsPane(.data)"))
        let pane = String(source.text[prefsStart.lowerBound..<dataStart.lowerBound])
        XCTAssertTrue(pane.contains("PreferencesCopy.updatesDisclosure"))
        XCTAssertTrue(source.text.contains("还要看版本"))
        XCTAssertTrue(pane.contains("DisclosureGroup"))
        let disclosureStart = try XCTUnwrap(pane.range(of: "DisclosureGroup"))
        let firstScreen = String(pane[..<disclosureStart.lowerBound])
        XCTAssertTrue(firstScreen.contains("displaySection"))
        XCTAssertTrue(firstScreen.contains("MacExperienceSettingsView"))
        XCTAssertFalse(firstScreen.contains("AppUpdateSettingsView"))
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertTrue(source.text.contains("显示位置"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testDisplayCardDoesNotRepeatItsTitle() throws {
        let source = try PreferencesSettingsSource.load()
        let displayStart = try XCTUnwrap(source.text.range(of: "private var displaySection"))
        let footerStart = try XCTUnwrap(source.text.range(of: "static func connectionFooter"))
        let display = String(source.text[displayStart.lowerBound..<footerStart.lowerBound])
        XCTAssertTrue(display.contains("SettingsSection {"))
        XCTAssertFalse(display.contains("SettingsSection(\"显示位置\")"))
        XCTAssertTrue(display.contains("displayTitle"))
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertTrue(source.text.contains("显示位置"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }

    func testDisplayScreenChoicesPressQuietlyInsteadOfAMenu() throws {
        let source = try PreferencesSettingsSource.load()
        let displayStart = try XCTUnwrap(source.text.range(of: "private var displaySection"))
        let footerStart = try XCTUnwrap(source.text.range(of: "static func connectionFooter"))
        let display = String(source.text[displayStart.lowerBound..<footerStart.lowerBound])
        XCTAssertFalse(display.contains("Picker("))
        XCTAssertTrue(display.contains("CompanionPressStyle()"))
        XCTAssertTrue(display.contains("CompanionPalette.selectedFill"))
        XCTAssertFalse(display.contains("CompanionFilterPill"))
        XCTAssertTrue(display.contains("screen.label"))
        XCTAssertEqual(DisplayScreen.builtIn.label, "原生屏幕")
        XCTAssertEqual(DisplayScreen.external.label, "扩展屏")
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertTrue(source.text.contains("显示位置"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
    }
}

private struct MacExperienceSettingsSource {
    let text: String

    static func load() throws -> MacExperienceSettingsSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("MacExperienceSettingsView.swift not found at \(url.path)")
        }
        return MacExperienceSettingsSource(text: text)
    }
}

private struct PreferencesSettingsSource {
    let text: String

    static func load() throws -> PreferencesSettingsSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("SyncSettingsView.swift not found at \(url.path)")
        }
        return PreferencesSettingsSource(text: text)
    }
}
