import XCTest
@testable import WeChatHUD

final class AutopilotSafetyTests: XCTestCase {

    // MARK: - AutopilotConfig defaults

    func testDefaultConfigValues() {
        let config = AutopilotConfig()
        XCTAssertEqual(config.maxSendsPerSession, 50)
        XCTAssertFalse(config.sensitiveKeywords.isEmpty)
        XCTAssertEqual(config.confidenceThreshold, 0.8)
        XCTAssertEqual(config.maxRepliesPerHour, 20)
        XCTAssertFalse(config.handleGroupAt)
        XCTAssertTrue(config.vipAutoNotify)
    }

    func testDefaultSensitiveKeywordsContainFinancialTerms() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("转账"))
        XCTAssertTrue(config.sensitiveKeywords.contains("密码"))
        XCTAssertTrue(config.sensitiveKeywords.contains("银行卡"))
    }

    func testDefaultSensitiveKeywordsContainProfanity() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("骂"))
    }

    func testDefaultSensitiveKeywordsContainHRTerms() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("辞职"))
        XCTAssertTrue(config.sensitiveKeywords.contains("合同"))
    }

    // MARK: - Sensitive keyword detection logic

    func testSensitiveKeywordMatchInReply() {
        let config = AutopilotConfig()
        let reply = "好的，我把密码发给你"
        let matched = config.sensitiveKeywords.first { reply.contains($0) }
        XCTAssertEqual(matched, "密码")
    }

    func testSensitiveKeywordNoMatchInSafeReply() {
        let config = AutopilotConfig()
        let reply = "好的，收到了，我看看"
        let matched = config.sensitiveKeywords.first { reply.contains($0) }
        XCTAssertNil(matched)
    }

    func testSensitiveKeywordEmptyList() {
        var config = AutopilotConfig()
        config.sensitiveKeywords = []
        let reply = "转账密码是123456"
        let matched = config.sensitiveKeywords.first { reply.contains($0) }
        XCTAssertNil(matched)
    }

    func testSensitiveKeywordCustomList() {
        var config = AutopilotConfig()
        config.sensitiveKeywords = ["机密", "保密"]
        let reply = "这个项目是保密的"
        let matched = config.sensitiveKeywords.first { reply.contains($0) }
        XCTAssertEqual(matched, "保密")
    }

    // MARK: - Session send limit logic

    func testSessionLimitZeroMeansUnlimited() {
        var config = AutopilotConfig()
        config.maxSendsPerSession = 0
        // 0 means unlimited — no cap check should trigger
        XCTAssertFalse(config.maxSendsPerSession > 0 && 100 >= config.maxSendsPerSession)
    }

    func testSessionLimitReached() {
        let config = AutopilotConfig()  // default 50
        let sessionSent = 50
        XCTAssertTrue(config.maxSendsPerSession > 0 && sessionSent >= config.maxSendsPerSession)
    }

    func testSessionLimitNotReached() {
        let config = AutopilotConfig()
        let sessionSent = 10
        XCTAssertFalse(config.maxSendsPerSession > 0 && sessionSent >= config.maxSendsPerSession)
    }

    // MARK: - AutopilotConfig Codable roundtrip

    func testAutopilotConfigCodable() throws {
        var config = AutopilotConfig()
        config.maxSendsPerSession = 100
        config.sensitiveKeywords = ["custom"]
        config.confidenceThreshold = 0.9

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: data)

        XCTAssertEqual(decoded.maxSendsPerSession, 100)
        XCTAssertEqual(decoded.sensitiveKeywords, ["custom"])
        XCTAssertEqual(decoded.confidenceThreshold, 0.9)
    }

    // MARK: - AutopilotAction and AutopilotRisk enums

    func testAutopilotActionRawValues() {
        XCTAssertEqual(AutopilotAction.sent.rawValue, "sent")
        XCTAssertEqual(AutopilotAction.pending.rawValue, "pending")
        XCTAssertEqual(AutopilotAction.skipped.rawValue, "skipped")
        XCTAssertEqual(AutopilotAction.vipNotified.rawValue, "vipNotified")
        XCTAssertEqual(AutopilotAction.failed.rawValue, "failed")
        XCTAssertEqual(AutopilotAction.groupLogged.rawValue, "groupLogged")
    }

    func testAutopilotRiskRawValues() {
        XCTAssertEqual(AutopilotRisk.low.rawValue, "low")
        XCTAssertEqual(AutopilotRisk.medium.rawValue, "medium")
        XCTAssertEqual(AutopilotRisk.high.rawValue, "high")
    }

    // MARK: - AutopilotReplyStyle

    func testReplyStylePromptFragment() {
        XCTAssertTrue(AutopilotReplyStyle.auto.promptFragment.isEmpty)
        XCTAssertFalse(AutopilotReplyStyle.brief.promptFragment.isEmpty)
        XCTAssertFalse(AutopilotReplyStyle.detailed.promptFragment.isEmpty)
    }
}
