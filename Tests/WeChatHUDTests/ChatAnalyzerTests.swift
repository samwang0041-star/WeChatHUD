import XCTest
@testable import WeChatHUD

final class ChatAnalyzerDecodingTests: XCTestCase {

    func testGroupAnalysisAcceptsStringKeySpeakers() throws {
        let raw = """
        {
          "topics": "讨论示例方案",
          "decisions": null,
          "my_action_items": null,
          "key_speakers": "测试成员A: 说明示例方案状态",
          "status": "discussing",
          "one_liner": "群友讨论示例方案"
        }
        """

        let decoded = try JSONDecoder().decode(ChatAnalyzer.GroupAnalysis.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.key_speakers, "测试成员A: 说明示例方案状态")
        XCTAssertEqual(decoded.one_liner, "群友讨论示例方案")
    }

    func testGroupAnalysisAcceptsArrayKeySpeakers() throws {
        let raw = """
        {
          "topics": "讨论示例方案及执行节奏",
          "decisions": null,
          "my_action_items": null,
          "key_speakers": [
            "测试成员A: 说明示例方案状态",
            "测试成员B: 补充执行节奏"
          ],
          "status": "discussing",
          "one_liner": "群友讨论示例方案推进"
        }
        """

        let decoded = try JSONDecoder().decode(ChatAnalyzer.GroupAnalysis.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.key_speakers, "测试成员A: 说明示例方案状态；测试成员B: 补充执行节奏")
        XCTAssertEqual(decoded.topics, "讨论示例方案及执行节奏")
    }

    func testGroupAnalysisWithOnlyUnreadableMessagesDoesNotCallModel() async throws {
        let tmp = NSTemporaryDirectory() + "test_chat_analyzer_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: tmp)
        try store.open()
        defer { store.close() }
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: #"{"topics":"空白消息","status":"discussing","one_liner":"大姑多次发送空白消息"}"#
        )

        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )
        let analyzer = ChatAnalyzer(store: store, aiService: AIService(config: cfg))
        let now = Int(Date().timeIntervalSince1970)
        let messages = [
            MessageInfo(
                id: "blank1",
                chatUsername: "room@chatroom",
                chatName: "家庭群",
                senderUsername: "aunt",
                senderName: "大姑",
                text: "内容无法显示",
                baseType: 1,
                subType: 0,
                createTime: now
            ),
            MessageInfo(
                id: "blank2",
                chatUsername: "room@chatroom",
                chatName: "家庭群",
                senderUsername: "uncle",
                senderName: "叔叔",
                text: "[消息]",
                baseType: 1,
                subType: 0,
                createTime: now - 1
            )
        ]

        let (result, error) = await analyzer.analyzeGroup(
            chatUsername: "room@chatroom",
            chatName: "家庭群",
            messages: messages,
            myUsername: "me",
            myName: "我"
        )

        XCTAssertNil(error)
        XCTAssertEqual(result?.one_liner, "暂无可读内容")
        XCTAssertTrue(URLRequestRecorder.capturedRequests.isEmpty)
    }
}
