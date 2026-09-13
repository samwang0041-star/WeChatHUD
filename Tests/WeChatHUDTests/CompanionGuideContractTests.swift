import XCTest
@testable import WeChatHUD

final class CompanionGuideContractTests: XCTestCase {
    func testPageSaysTheFirstThreeSteps() throws {
        let source = try CompanionGuideSource.load()
        XCTAssertTrue(source.text.contains("GuideCopy.statusLine"))
        XCTAssertTrue(source.text.contains("workspaceTitle()"))
        XCTAssertEqual(GuideCopy.statusLine, "先连接微信，再选人，再看今天。")
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("选择关注的人"))
        XCTAssertTrue(source.text.contains("今天看待回和待办"))
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
        XCTAssertTrue(source.text.contains("还要看其余说明"))
        XCTAssertTrue(source.text.contains("GuideCopy.dailyDisclosure"))
        XCTAssertEqual(GuideCopy.dailyDisclosure, "每天怎么用")
        XCTAssertTrue(source.text.contains("每天怎么用"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("选择关注的人"))
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
        XCTAssertTrue(step.contains("workspaceBody()"))
        XCTAssertFalse(step.contains(".font(.body.weight(.semibold))"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("选择关注的人"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testStepCopySpeaksLikeAPerson() throws {
        XCTAssertEqual(GuideCopy.step1Detail, "登录这台 Mac 的微信。")
        XCTAssertEqual(GuideCopy.step2Detail, "选一个人或一个群。")
        XCTAssertEqual(GuideCopy.step3Detail, "今天看待回和待办。")
        XCTAssertFalse(GuideCopy.step1Detail.contains("已登录"))
        XCTAssertFalse(GuideCopy.step2Detail.contains("联系人"))
        let source = try CompanionGuideSource.load()
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("选择关注的人"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testOnlyTheFirstStepHasAButton() throws {
        let source = try CompanionGuideSource.load()
        let quickStart = try XCTUnwrap(source.text.range(of: "private var quickStartCard"))
        let faq = try XCTUnwrap(source.text.range(of: "private var faqColumn"))
        let card = String(source.text[quickStart.lowerBound..<faq.lowerBound])
        XCTAssertTrue(card.contains("buttonTitle: \"连接微信\""))
        XCTAssertFalse(card.contains("选择对话"))
        XCTAssertFalse(card.contains("打开今天"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("选择关注的人"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testConnectActionPressesQuietly() throws {
        let source = try CompanionGuideSource.load()
        let stepStart = try XCTUnwrap(source.text.range(of: "private func guideStep"))
        let topicStart = try XCTUnwrap(source.text.range(of: "private func guideTopic"))
        let step = String(source.text[stepStart.lowerBound..<topicStart.lowerBound])
        XCTAssertTrue(step.contains("CompanionPressStyle()"))
        XCTAssertFalse(step.contains(".bordered"))
        XCTAssertFalse(step.contains("CompanionPalette.jade"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testGuideActionsPressQuietly() throws {
        let source = try CompanionGuideSource.load()
        let troubleStart = try XCTUnwrap(source.text.range(of: "private func troubleshootingRow"))
        let shortcutStart = try XCTUnwrap(source.text.range(of: "private func shortcutRow"))
        let trouble = String(source.text[troubleStart.lowerBound..<shortcutStart.lowerBound])
        XCTAssertTrue(trouble.contains("检查连接") || source.text.contains("检查连接"))
        XCTAssertTrue(trouble.contains("CompanionPressStyle()"))
        XCTAssertFalse(trouble.contains(".bordered"))
        let aboutStart = try XCTUnwrap(source.text.range(of: "private var aboutCard"))
        let faqStart = try XCTUnwrap(source.text.range(of: "private func faqRow"))
        let about = String(source.text[aboutStart.lowerBound..<faqStart.lowerBound])
        XCTAssertTrue(about.contains("CompanionPressStyle()"))
        XCTAssertFalse(about.contains(".bordered"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("每天怎么用"))
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
    }

    func testUpdateCheckSpeaksAReceipt() throws {
        XCTAssertEqual(GuideCopy.updateChecking, "正在看有没有新版本。")
        XCTAssertEqual(GuideCopy.updateCurrent, "已经是最新。")
        XCTAssertEqual(GuideCopy.updateReceipt(phase: .checking, version: nil), "正在看有没有新版本。")
        XCTAssertEqual(GuideCopy.updateReceipt(phase: .upToDate, version: nil), "已经是最新。")
        XCTAssertEqual(GuideCopy.updateReceipt(phase: .idle, version: nil), nil)
        let source = try CompanionGuideSource.load()
        XCTAssertTrue(source.text.contains("askedUpdate"))
        XCTAssertTrue(source.text.contains("GuideCopy.updateReceipt"))
        XCTAssertFalse(source.text.contains("navigate(.preferences)"))
        XCTAssertTrue(source.text.contains("先连接微信"))
        XCTAssertTrue(source.text.contains("连接微信"))
        XCTAssertTrue(source.text.contains("每天怎么用"))
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
