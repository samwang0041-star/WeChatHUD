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
        XCTAssertTrue(display.contains("显示位置"))
        XCTAssertFalse(display.contains("CompanionPalette.jade"))
        XCTAssertTrue(source.text.contains("浮窗在"))
        XCTAssertEqual(SettingsView.Tab.preferences.label, "使用偏好")
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
