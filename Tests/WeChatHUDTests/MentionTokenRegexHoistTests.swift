import XCTest
@testable import WeChatHUD

/// W5: AIClassifier.recipientScope now matches with one process-wide
/// NSRegularExpression instead of compiling the pattern per message.
/// These assertions pin all four branches and re-run every case inside a
/// single test, so a shared regex object that mutated or drifted between
/// calls would fail here.
final class MentionTokenRegexHoistTests: XCTestCase {

    private let identity = AIClassifier.RecipientContext(
        myUsername: "wxid_me",
        myDisplayName: "小王",
        mySelfNames: ["王老师"],
        knownOtherNames: ["小李"]
    )

    private func input(_ text: String, isGroup: Bool = true) -> ClassifierInput {
        ClassifierInput(msgUID: "m1", text: text, senderName: "同事", chatName: "项目群", isGroup: isGroup)
    }

    func testRecipientScopeBranchesAreStableAcrossRepeatedCalls() {
        let cases: [(text: String, expected: AIClassifier.RecipientScope)] = [
            ("@小王 发方案", .direct),          // addressed to me by display name
            ("@所有人 发方案", .collective),     // collective broadcast
            ("@小李 发方案给我", .other),        // a different, known person
            ("@新群昵称 请发方案", .uncertain),  // unnamed nickname may still be me
        ]
        for (text, expected) in cases {
            for _ in 0..<3 {
                XCTAssertEqual(
                    AIClassifier.recipientScope(message: input(text), context: identity),
                    expected,
                    "repeated call changed the answer for " + text
                )
            }
        }
    }

    func testRecipientScopePrivateChatSkipsMentionMatching() {
        XCTAssertEqual(
            AIClassifier.recipientScope(message: input("@小王 发方案", isGroup: false), context: identity),
            .direct
        )
    }
}
