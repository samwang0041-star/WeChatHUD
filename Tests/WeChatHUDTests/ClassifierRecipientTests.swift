import XCTest
@testable import WeChatHUD

final class ClassifierRecipientTests: XCTestCase {
    private var store: HUDStore!
    private var path: String!
    private let identity = AIClassifier.RecipientContext(myUsername: "wxid_me", myDisplayName: "小王", mySelfNames: ["王老师"], knownOtherNames: ["小李"])
    private let positive = #"{"is_ask":true,"type":"send_file","summary":"发方案","deadline_relative":"+1d","confidence":0.98}"#

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "classifier-recipient-\(UUID()).sqlite3"
        store = HUDStore(dbPath: path)
        try store.open()
    }
    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    private func input(_ text: String, group: Bool = true) -> ClassifierInput {
        ClassifierInput(msgUID: "m1", text: text, senderName: "同事", chatName: "项目群", isGroup: group)
    }

    func testExplicitOtherRecipientIsSuccessfulNonAskWithoutModelCall() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        let result = await classifier.classify(message: input("@小李 发方案给我"), recipientContext: identity)
        XCTAssertEqual(result?.isAsk, false)
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 0)
    }

    func testDirectSelfAndAliasMayRemainHighConfidence() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        for text in ["@小王 发方案", "@王老师 发方案", "@wxid_me 发方案"] {
            let result = await classifier.classify(message: input(text), recipientContext: identity)
            XCTAssertEqual(result?.confidence, 0.98)
            XCTAssertEqual(result?.summary, "发方案")
        }
    }

    func testCollectiveAndUnattributedGroupRequestsRequireReview() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        for text in ["@所有人 发方案", "@all 发方案", "你把方案发过来", "刚才跟 @小李 说过了，你来发方案"] {
            let result = await classifier.classify(message: input(text), recipientContext: identity)
            XCTAssertEqual(result?.isAsk, true)
            XCTAssertEqual(result?.confidence, 0.84)
            XCTAssertTrue(result?.summary.hasPrefix("待确认归属：") == true)
        }
    }

    func testPrivateRequestDoesNotBecomeGroupReview() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        let result = await classifier.classify(message: input("你把方案发来", group: false), recipientContext: identity)
        XCTAssertEqual(result?.confidence, 0.98)
    }

    func testUnknownIdentityDoesNotDiscardNamedGroupRequest() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        let result = await classifier.classify(message: input("@小王 发方案"))
        XCTAssertEqual(result?.isAsk, true)
        XCTAssertEqual(result?.confidence, 0.84)
    }

    func testFailureIsDistinctFromSuccessfulEmptyAndStrictRetryCanRecover() async {
        let ai = MockAIService()
        await ai.setDefaultResponse("bad JSON")
        let classifier = AIClassifier(store: store, aiService: ai)
        let failed = await classifier.classify(message: input("方案发来", group: false))
        XCTAssertNil(failed)
        let failedCalls = await ai.calls.count
        XCTAssertEqual(failedCalls, 2)
        await ai.setRoute(needle: "上一次输出无法被解析", response: positive)
        let recovered = await classifier.classify(message: input("方案发来", group: false))
        XCTAssertEqual(recovered?.isAsk, true)
        let emptyAI = MockAIService()
        await emptyAI.setDefaultResponse(#"{"is_ask":false,"type":"none","summary":"","confidence":0.9}"#)
        let empty = await AIClassifier(store: store, aiService: emptyAI).classify(message: input("收到", group: false))
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.isAsk, false)
    }

    func testIdentityAndPrecedingContextAreIncludedInVersionedPrompt() async {
        let ai = MockAIService()
        await ai.setDefaultResponse(positive)
        let classifier = AIClassifier(store: store, aiService: ai)
        var context = identity
        context.precedingMessages = "小王: 我负责方案"
        let result = await classifier.classify(message: input("@小王 发方案"), recipientContext: context)
        let prompt = await ai.calls.first?.user ?? ""
        XCTAssertTrue(prompt.contains("wxid_me / 小王 / 王老师"))
        XCTAssertTrue(prompt.contains("我负责方案"))
        XCTAssertFalse(prompt.contains("{self_identity}"))
        XCTAssertEqual(result?.promptVersion, "classifier_v4")
    }
    func testPromptDiscoveryInsideSignedAppResources() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-package-\(UUID())/Contents/Resources")
        let bundle = resources.appendingPathComponent("WeChatHUD_WeChatHUD.bundle")
        let prompts = bundle.appendingPathComponent("prompts")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent()) }
        let file = prompts.appendingPathComponent("classifier_v4.txt")
        try "packaged prompt".write(to: file, atomically: true, encoding: .utf8)
        let found = try XCTUnwrap(PromptLoader.packagedPromptURL(version: "classifier_v4", resourcesURL: resources))
        XCTAssertEqual(try String(contentsOf: found, encoding: .utf8), "packaged prompt")
        XCTAssertNil(PromptLoader.packagedPromptURL(version: "missing", resourcesURL: resources))
    }

    func testSelfNameContainingSpacesIsNotMistakenForAnotherRecipient() {
        let context = AIClassifier.RecipientContext(myUsername: "wxid_me", myDisplayName: "John Smith")
        XCTAssertEqual(AIClassifier.recipientScope(message: input("@John Smith 请发方案"), context: context), .direct)
    }

    func testUnknownGroupNicknameRemainsReviewInsteadOfBeingDiscarded() {
        XCTAssertEqual(AIClassifier.recipientScope(message: input("@新群昵称 请发方案"), context: identity), .uncertain)
    }

}
