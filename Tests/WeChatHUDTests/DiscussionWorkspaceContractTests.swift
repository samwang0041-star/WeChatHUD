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
