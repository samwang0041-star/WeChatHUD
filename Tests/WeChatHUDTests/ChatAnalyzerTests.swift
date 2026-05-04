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
}
