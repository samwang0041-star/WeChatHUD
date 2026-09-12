import XCTest
@testable import WeChatHUD

final class ReplySuggestionSafetyTests: XCTestCase {

    func testVaccineRelayDoesNotRecommendAMedicalDecision() {
        let source = "不接种流感疫苗需在9月12日12时前微信群接龙"
        let replies = [
            SuggestedReply(
                text: "收到，我家孩子需要接种，谢谢老师",
                tone: "recommended",
                recommended: true,
                rationale: "明确表态需接种，避免漏统计"
            ),
            SuggestedReply(
                text: "老师，我家不接种，已在群里接龙",
                tone: "formal",
                recommended: false,
                rationale: "按通知要求接龙不接种"
            ),
            SuggestedReply(
                text: "收到，我确认后回复您",
                tone: "brief",
                recommended: false,
                rationale: "未定前不硬表态"
            ),
        ]

        let kept = ReplySuggestionSafety.sanitize(replies, sourceTexts: [source])

        XCTAssertEqual(kept.map(\.text), ["收到，我确认后回复您"])
    }

    func testSensitiveSourceFallsBackWhenEveryDraftInventedADecision() {
        let kept = ReplySuggestionSafety.sanitize(
            [
                SuggestedReply(text: "收到，我家孩子需要接种，谢谢老师", tone: "recommended", recommended: true),
                SuggestedReply(text: "老师，我家不接种，已在群里接龙", tone: "formal", recommended: false),
            ],
            sourceTexts: ["流感疫苗接种统计接龙"]
        )
        XCTAssertEqual(kept.map(\.text), ["我确认下再回你"])
        XCTAssertEqual(kept.first?.recommended, true)
    }

    func testOrdinaryChatKeepsOrdinaryDrafts() {
        let replies = [
            SuggestedReply(text: "好，12:40 到", tone: "recommended", recommended: true)
        ]
        XCTAssertEqual(
            ReplySuggestionSafety.sanitize(replies, sourceTexts: ["明儿中饭咱们12:40到"]).map(\.text),
            ["好，12:40 到"]
        )
    }
}
