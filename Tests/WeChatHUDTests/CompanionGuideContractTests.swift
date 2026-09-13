import XCTest
@testable import WeChatHUD

final class CompanionGuideContractTests: XCTestCase {
    func testPageSaysTheFirstThreeSteps() throws {
        let source = try CompanionGuideSource.load()
        XCTAssertTrue(source.text.contains("GuideCopy.statusLine"))
        XCTAssertTrue(source.text.contains("workspaceTitle()"))
        XCTAssertEqual(GuideCopy.statusLine, "先连接微信，再选人，再看今天。")
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("选择对话"))
        XCTAssertTrue(source.text.contains("打开今天"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testExtraGuideWaitsBehindADisclosure() throws {
        let source = try CompanionGuideSource.load()
        let bodyStart = try XCTUnwrap(source.text.range(of: "var body: some View"))
        let quickStart = try XCTUnwrap(source.text.range(of: "private var quickStartCard"))
        let pane = String(source.text[bodyStart.lowerBound..<quickStart.lowerBound])
        XCTAssertTrue(source.text.contains("还要看其余说明"))
        let disclosureStart = try XCTUnwrap(pane.range(of: "DisclosureGroup"))
        let firstScreen = String(pane[..<disclosureStart.lowerBound])
        XCTAssertTrue(firstScreen.contains("GuideCopy.statusLine"))
        XCTAssertTrue(firstScreen.contains("quickStartCard"))
        XCTAssertFalse(firstScreen.contains("dailyUseCard"))
        XCTAssertFalse(firstScreen.contains("faqColumn"))
        XCTAssertTrue(source.text.contains("每天怎么用"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("选择对话"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testStepNumbersAreNotSystemAccent() throws {
        let source = try CompanionGuideSource.load()
        let stepStart = try XCTUnwrap(source.text.range(of: "private func guideStep"))
        let topicStart = try XCTUnwrap(source.text.range(of: "private func guideTopic"))
        let step = String(source.text[stepStart.lowerBound..<topicStart.lowerBound])
        XCTAssertFalse(step.contains("Color.accentColor"))
        XCTAssertFalse(step.contains(".background("))
        XCTAssertTrue(step.contains("workspaceMeta()"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("选择对话"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }
}

private struct CompanionGuideSource {
    let text: String

    static func load() throws -> CompanionGuideSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/CompanionGuideView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("CompanionGuideView.swift not found at \(url.path)")
        }
        return CompanionGuideSource(text: text)
    }
}
