import XCTest
@testable import WeChatHUD

final class DailyReportWorkspaceContractTests: XCTestCase {
    func testExportIsTheJadePrimaryAndScopePillsAreQuiet() throws {
        let source = try DailyReportTabSource.load()
        let toolbarStart = try XCTUnwrap(source.text.range(of: "private var workspaceToolbar"))
        let weeklyStart = try XCTUnwrap(source.text.range(of: "private var weeklySummary"))
        let toolbar = String(source.text[toolbarStart.lowerBound..<weeklyStart.lowerBound])
        XCTAssertTrue(source.text.contains("日报"))
        XCTAssertTrue(source.text.contains("周报"))
        XCTAssertTrue(toolbar.contains("导出"))
        XCTAssertTrue(toolbar.contains("CompanionPalette.selectedFill"))
        XCTAssertFalse(toolbar.contains("CompanionFilterPill"))
        XCTAssertTrue(toolbar.contains("borderedProminent"))
        XCTAssertTrue(toolbar.contains("CompanionPressStyle()"))
        let chevronIsSystemBordered = toolbar.components(separatedBy: "\n").contains { line in
            line.contains("buttonStyle(.bordered)") && !line.contains("borderedProminent")
        }
        XCTAssertFalse(chevronIsSystemBordered)
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
    }

    func testWorkspaceSitsOnTheCanvasWithoutADivider() throws {
        let source = try DailyReportTabSource.load()
        let workspaceStart = try XCTUnwrap(source.text.range(of: "private var workspaceBody"))
        let compactStart = try XCTUnwrap(source.text.range(of: "private var compactBody"))
        let workspace = String(source.text[workspaceStart.lowerBound..<compactStart.lowerBound])
        XCTAssertFalse(workspace.contains("Divider()"))
        XCTAssertTrue(workspace.contains("CompanionPalette.canvas"))
        XCTAssertTrue(source.text.contains("导出"))
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
    }

    func testLoadingAndExportSpeakLikeAPerson() throws {
        let source = try DailyReportTabSource.load()
        let toolbarStart = try XCTUnwrap(source.text.range(of: "private var workspaceToolbar"))
        let weeklyStart = try XCTUnwrap(source.text.range(of: "private var weeklySummary"))
        let toolbar = String(source.text[toolbarStart.lowerBound..<weeklyStart.lowerBound])
        XCTAssertTrue(toolbar.contains("正在写今天的小结。"))
        XCTAssertTrue(toolbar.contains("正在写这周的小结。"))
        XCTAssertFalse(toolbar.contains("正在整理"))
        XCTAssertTrue(source.text.contains("打开这份小结"))
        XCTAssertFalse(source.text.contains("打开结果"))
        XCTAssertTrue(source.text.contains("小结已放到桌面。"))
        XCTAssertFalse(source.text.contains("小结已导出。可在访达中查看文件。"))
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
    }

    func testWeeklyDoneRowsAreNotJadeNumberBadges() throws {
        let source = try DailyReportTabSource.load()
        let weeklyStart = try XCTUnwrap(source.text.range(of: "private var weeklySummary"))
        let reloadStart = try XCTUnwrap(source.text.range(of: "private func reloadWeeklyCatalog"))
        let weekly = String(source.text[weeklyStart.lowerBound..<reloadStart.lowerBound])
        XCTAssertTrue(weekly.contains("已经推进"))
        XCTAssertFalse(weekly.contains("background(CompanionPalette.jade, in: Circle())"))
        XCTAssertFalse(weekly.contains("Button(\"查看待办\")"))
        XCTAssertTrue(weekly.contains("在待办里看"))
        XCTAssertTrue(weekly.contains("CompanionPressStyle()"))
        XCTAssertFalse(weekly.contains("buttonStyle(.plain)"))
        XCTAssertFalse(weekly.contains("foregroundStyle(CompanionPalette.jade)"))
        XCTAssertTrue(source.text.contains("导出"))
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
    }
}

private struct DailyReportTabSource {
    let text: String

    static func load() throws -> DailyReportTabSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/DailyReportTabView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("DailyReportTabView.swift not found at \(url.path)")
        }
        return DailyReportTabSource(text: text)
    }
}
