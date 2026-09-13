import XCTest
@testable import WeChatHUD

final class DiscussionWorkspaceContractTests: XCTestCase {
    func testMarkDoneIsTheJadePrimaryAndCorrectionIsQuiet() throws {
        let source = try DiscussionWorkspaceSource.load()
        let detailStart = try XCTUnwrap(source.text.range(of: "private func taskDetail"))
        let metaStart = try XCTUnwrap(source.text.range(of: "private func metaRow"))
        let detail = String(source.text[detailStart.lowerBound..<metaStart.lowerBound])
        XCTAssertTrue(detail.contains("标记完成"))
        XCTAssertTrue(detail.contains("borderedProminent"))
        XCTAssertTrue(detail.contains("CompanionPalette.jade"))
        XCTAssertTrue(detail.contains("更正归属"))
        XCTAssertTrue(detail.contains("查看原文"))
        XCTAssertTrue(detail.contains("CompanionPressStyle()"))
        XCTAssertFalse(detail.contains("foregroundStyle(CompanionPalette.jade)"))
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
    }

    func testFiltersSitOnTheCanvasNotACard() throws {
        let source = try DiscussionWorkspaceSource.load()
        let barStart = try XCTUnwrap(source.text.range(of: "private var strictnessBar"))
        let receiptStart = try XCTUnwrap(source.text.range(of: "static func receiptLabel"))
        let bar = String(source.text[barStart.lowerBound..<receiptStart.lowerBound])
        XCTAssertTrue(bar.contains("receiptLabel"))
        XCTAssertFalse(bar.contains("secondarySurface"))
        XCTAssertFalse(bar.contains("pickerStyle"))
        XCTAssertFalse(bar.contains("CompanionPalette.jade"))

        let filtersStart = try XCTUnwrap(source.text.range(of: "private var filters"))
        let emptyStart = try XCTUnwrap(source.text.range(of: "private var emptyState"))
        let filters = String(source.text[filtersStart.lowerBound..<emptyStart.lowerBound])
        XCTAssertTrue(filters.contains("找待办"))
        XCTAssertTrue(filters.contains("showsSearchField"))
        XCTAssertTrue(filters.contains("Button(\"找待办\")"))
        XCTAssertTrue(filters.contains("searching = true"))
        XCTAssertFalse(filters.contains("搜索待办或对话"))
        XCTAssertTrue(filters.contains("清除搜索"))
        XCTAssertFalse(filters.contains("strokeBorder"))
        XCTAssertFalse(filters.contains("foregroundStyle(CompanionPalette.jade)"))
        XCTAssertTrue(filters.contains("CompanionPalette.selectedFill"))
        XCTAssertFalse(filters.contains("CompanionPalette.jade"))
        XCTAssertTrue(filters.contains("Menu(\"保留\")"))
        XCTAssertTrue(filters.contains("看已处理的"))
        XCTAssertFalse(filters.contains("Toggle("))
        XCTAssertFalse(filters.contains("当前只显示还没做完的"))
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
    }

    func testArchivedRevealGivesUnderPress() throws {
        let source = try DiscussionWorkspaceSource.load()
        let listStart = try XCTUnwrap(source.text.range(of: "private func listPane"))
        let detailStart = try XCTUnwrap(source.text.range(of: "private func detailPane"))
        let list = String(source.text[listStart.lowerBound..<detailStart.lowerBound])
        XCTAssertTrue(list.contains("点开查看"))
        XCTAssertTrue(list.contains("收起"))
        XCTAssertTrue(list.contains("CompanionPressStyle()"))
        XCTAssertFalse(list.contains("buttonStyle(.plain)"))
        XCTAssertFalse(list.contains("CompanionPalette.jade"))
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
    }

    func testEmptyStatesSpeakAndOfferANextStep() throws {
        let source = try DiscussionWorkspaceSource.load()
        XCTAssertFalse(source.text.contains("ContentUnavailableView"))
        let emptyStart = try XCTUnwrap(source.text.range(of: "private var emptyState"))
        let listStart = try XCTUnwrap(source.text.range(of: "private func listPane"))
        let empty = String(source.text[emptyStart.lowerBound..<listStart.lowerBound])
        XCTAssertTrue(empty.contains("还没有待办"))
        XCTAssertTrue(empty.contains("有 \\(hiddenHere.count) 条被收起") || empty.contains("条被收起"))
        XCTAssertTrue(empty.contains("全部都记"))
        XCTAssertTrue(empty.contains("清除搜索"))
        XCTAssertTrue(empty.contains("CompanionPressStyle()"))
        XCTAssertFalse(empty.contains("buttonStyle(.bordered)"))
        XCTAssertTrue(source.text.contains("从左边选一条"))
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
    }
}

private struct DiscussionWorkspaceSource {
    let text: String

    static func load() throws -> DiscussionWorkspaceSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("DiscussionWorkspaceView.swift not found at \(url.path)")
        }
        return DiscussionWorkspaceSource(text: text)
    }
}
