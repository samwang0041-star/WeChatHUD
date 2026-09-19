import XCTest
@testable import WeChatHUD

/// The AI generation sliders and the auto-install switch both describe a
/// scope wider than the code implements. These gates hold the copy and the
/// call sites together: if someone later wires `maxTokens`/`temperature`
/// through to 摘要 and 草稿, the second test goes red and forces the label to
/// be re-read — which is the point, because right now the label is only true
/// of the tasks that pass no options at all.
final class SettingsScopeHonestyTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testGenerationSlidersDoNotClaimToShapeSummariesAndDrafts() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/AISettingsView.swift")
        XCTAssertFalse(
            view.contains("这是平时写摘要和草稿的习惯"),
            "旧文案把两个滑杆说成摘要与草稿的习惯，而这两条路径都传了固定参数")
        XCTAssertTrue(view.contains("摘要和草稿各有固定写法"),
                      "必须点名哪两条不受影响")
        XCTAssertFalse(
            view.contains("写摘要和草稿时多想一会儿"),
            "思考开关对要 JSON 输出的草稿是强制关闭的，不能再说草稿")
    }

    /// The other half of the same promise: the copy is only honest while those
    /// two call sites really do pass literals.
    func testSummaryAndDraftStillPinTheirOwnGenerationOptions() throws {
        let summarizer = try source("Sources/WeChatHUD/Services/AIInboxSummarizer.swift")
        let suggester = try source("Sources/WeChatHUD/Services/AIReplySuggester.swift")
        XCTAssertTrue(summarizer.contains("temperature: 0.1"),
                      "摘要不再固定参数 ⇒ 上面的文案要重写，而不是让这条测试静默过期")
        XCTAssertTrue(suggester.contains("temperature: 0.4"),
                      "草稿不再固定参数 ⇒ 同上")
        XCTAssertTrue(suggester.contains("responseFormatJSON: true"),
                      "草稿靠 JSON 格式强制关闭思考，思考开关的文案以此为前提")
    }

    /// 「不是聊天原文」 was false: the same function writes each 待回复 row's
    /// preview and the first 50 characters of a message the peer retracted. A
    /// caption that denies what the file contains is worse than no caption — it
    /// is the sentence the user relies on when deciding to leave the file on a
    /// shared machine.
    func testExportCaptionMatchesWhatTheFileHolds() throws {
        XCTAssertTrue(LocalDataRetrospection.exportCaption.contains("原文片段"),
                      LocalDataRetrospection.exportCaption)
        XCTAssertFalse(LocalDataRetrospection.exportCaption.contains("不是聊天原文"))
        let report = try source("Sources/WeChatHUD/Services/ChatMonitor+DailyReport.swift")
        XCTAssertTrue(report.contains("item.preview"), "caption promises previews; the export must still write them")
        XCTAssertTrue(report.contains("r.originalText.prefix(50)"), "same for the retracted-text line")
    }

    /// The 0600 rule was stated in one export function's comment and broken by
    /// its sibling two lines away — the 日报 page's own button wrote 0644.
    @MainActor
    func testBothExportPathsMakeTheFilePrivate() throws {
        let report = try source("Sources/WeChatHUD/Services/ChatMonitor+DailyReport.swift")
        XCTAssertEqual(
            report.components(separatedBy: "Self.makeExportPrivate(url:").count - 1, 2,
            "两个导出函数各自都要收紧权限（日报页走的是 exportDailyReport）"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-export-perm-\(UUID().uuidString).md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        ChatMonitor.makeExportPrivate(url: url)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(mode & 0o777, 0o600, String(format: "0%o", mode))
    }

    func testAutoInstallStatesWhenItCanFire() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/AppUpdateSettingsView.swift")
        let controller = try source("Sources/WeChatHUD/Services/AppUpdateController.swift")
        // The only `installIfEnabled: true` call is the launch check, and that
        // one is behind `autoCheckEnabled`.
        let launchOnly = controller.components(separatedBy: "installIfEnabled: true").count - 1
        XCTAssertEqual(launchOnly, 1, "自动安装多了一个入口，就要重新核对面上的说法")
        XCTAssertTrue(view.contains("启动时的自动检查"),
                      "「发现后自动安装」不说明只在启动检查生效，用户点手动检查会以为它坏了")
    }
}
