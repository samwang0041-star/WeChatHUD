import XCTest
@testable import WeChatHUD

final class ContextAnalyzerTests: XCTestCase {
    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "context_analyzer_v1"))
    }

    func testAnalysisResultDecoding() {
        let json = """
        {
          "background": "王总在追Q3方案进度",
          "what_they_want": "确认方案最终版",
          "hidden_context": "他已经催过两次了",
          "stakeholder_map": [{"name": "李四", "stance": "支持", "detail": "已提交修改版"}],
          "your_position": "你昨天说今天改完，已超期",
          "suggested_action": "主动汇报进展",
          "suggested_timing": "immediate",
          "risk_if_ignore": "王总可能直接找你老板"
        }
        """
        let data = json.data(using: .utf8)!
        let result = try? JSONDecoder().decode(ContextAnalyzer.AnalysisResult.self, from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.background, "王总在追Q3方案进度")
        XCTAssertEqual(result?.suggestedTiming, "immediate")
        XCTAssertEqual(result?.stakeholderMap.count, 1)
        XCTAssertEqual(result?.stakeholderMap[0].name, "李四")
    }
}
