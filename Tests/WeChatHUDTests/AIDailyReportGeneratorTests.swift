import Foundation
import XCTest
@testable import WeChatHUD

final class AIDailyReportGeneratorTests: XCTestCase {

    // MARK: - Prompt formatting

    func testFormatPromptWithData() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let report = makeSampleReport()
        let template = """
        unread: {unread_count}
        chats: {analyzed_chat_count}
        highlights: {highlight_count}
        pending: {pending_todo_count}
        HL:\n{highlights}
        AC:\n{actions}
        R:\n{risks}
        """

        let prompt = generator.formatPrompt(template: template, report: report)

        XCTAssertTrue(prompt.contains("unread: 5"))
        XCTAssertTrue(prompt.contains("chats: 3"))
        XCTAssertTrue(prompt.contains("highlights: 2"))
        XCTAssertTrue(prompt.contains("pending: 1"))
        XCTAssertTrue(prompt.contains("HL:"))
        XCTAssertTrue(prompt.contains("[Team Chat] 决定使用方案A"))
        XCTAssertTrue(prompt.contains("AC:"))
        XCTAssertTrue(prompt.contains("[待办][Team Chat] 跟进方案A实施"))
        XCTAssertTrue(prompt.contains("R:"))
        XCTAssertTrue(prompt.contains("承诺「交付报告」已超期"))
    }

    func testFormatPromptEmptyData() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let report = DailyReport(
            date: Date(),
            dateRange: (start: Date(), end: Date()),
            generatedAt: Date(),
            metrics: DailyReportMetrics(
                unreadMessageCount: 0, pendingTodoCount: 0,
                pendingAskCount: 0, pendingCommitmentCount: 0,
                overdueCommitmentCount: 0, replyDebtCount: 0,
                recalledMessageCount: 0, highlightCount: 0,
                analyzedChatCount: 0
            ),
            highlights: [],
            actions: [],
            risks: [],
            pendingAsks: [],
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )

        let template = "HL:\n{highlights}\nAC:\n{actions}\nR:\n{risks}"
        let prompt = generator.formatPrompt(template: template, report: report)

        XCTAssertTrue(prompt.contains("暂无高亮数据"))
        XCTAssertTrue(prompt.contains("暂无待办"))
        XCTAssertTrue(prompt.contains("暂无风险"))
    }

    func testFormatPromptHighlightsCapped() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        var highlights: [DailyReportHighlight] = []
        for i in 0..<15 {
            highlights.append(DailyReportHighlight(
                summary: "Highlight \(i)",
                category: .discussion,
                sourceChatName: "Chat \(i)",
                sourceChatUsername: "wxid_\(i)",
                date: Date(),
                confidence: 0.9,
                quotedSnippet: nil,
                involved: []
            ))
        }

        let report = DailyReport(
            date: Date(),
            dateRange: (start: Date(), end: Date()),
            generatedAt: Date(),
            metrics: DailyReportMetrics(
                unreadMessageCount: 0, pendingTodoCount: 0,
                pendingAskCount: 0, pendingCommitmentCount: 0,
                overdueCommitmentCount: 0, replyDebtCount: 0,
                recalledMessageCount: 0, highlightCount: 15,
                analyzedChatCount: 0
            ),
            highlights: highlights,
            actions: [],
            risks: [],
            pendingAsks: [],
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )

        let prompt = generator.formatPrompt(template: "{highlights}", report: report)
        let lines = prompt.split(separator: "\n")
        XCTAssertEqual(lines.count, 8, "Highlights should be capped at 8")
    }

    // MARK: - JSON parsing

    func testParseValidJSON() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let json = """
        {
            "narrative": "Today was productive.",
            "tomorrow_focus": "Finish the report.",
            "wechat_draft": "2026-05-05 工作小结\\n今日完成..."
        }
        """

        let result = generator.parse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.narrative, "Today was productive.")
        XCTAssertEqual(result?.tomorrowFocus, "Finish the report.")
        XCTAssertEqual(result?.wechatDraft, "2026-05-05 工作小结\n今日完成...")
    }

    func testParseInvalidJSON() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let result = generator.parse("not json at all")
        XCTAssertNil(result)
    }

    func testParseJSONWithMarkdownFence() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let json = """
        ```json
        {
            "narrative": "Good day.",
            "tomorrow_focus": "Meeting.",
            "wechat_draft": "Draft text"
        }
        ```
        """

        let result = generator.parse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.narrative, "Good day.")
    }

    func testParseJSONWithExtraText() {
        let generator = AIDailyReportGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )

        let json = """
        Sure, here is the JSON:
        {
            "narrative": "Busy day.",
            "tomorrow_focus": "Code review.",
            "wechat_draft": "Draft"
        }
        Hope that helps!
        """

        let result = generator.parse(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.narrative, "Busy day.")
    }

    // MARK: - DailyReport.withAI

    func testDailyReportWithAI() {
        let report = makeSampleReport()
        let enriched = report.withAI(
            narrative: "AI narrative",
            tomorrowFocus: "AI focus",
            wechatDraft: "AI draft"
        )

        XCTAssertEqual(enriched.narrative, "AI narrative")
        XCTAssertEqual(enriched.tomorrowFocus, "AI focus")
        XCTAssertEqual(enriched.wechatDraft, "AI draft")
        XCTAssertEqual(enriched.metrics.unreadMessageCount, 5)
        XCTAssertEqual(enriched.highlights.count, 2)
    }

    // MARK: - Helpers

    private func makeSampleReport() -> DailyReport {
        let now = Date()
        return DailyReport(
            date: now,
            dateRange: (start: now, end: now),
            generatedAt: now,
            metrics: DailyReportMetrics(
                unreadMessageCount: 5,
                pendingTodoCount: 1,
                pendingAskCount: 2,
                pendingCommitmentCount: 3,
                overdueCommitmentCount: 1,
                replyDebtCount: 4,
                recalledMessageCount: 0,
                highlightCount: 2,
                analyzedChatCount: 3
            ),
            highlights: [
                DailyReportHighlight(
                    summary: "决定使用方案A",
                    category: .decision,
                    sourceChatName: "Team Chat",
                    sourceChatUsername: "wxid_team",
                    date: now,
                    confidence: 0.92,
                    quotedSnippet: "我们决定用方案A",
                    involved: ["Alice", "Bob"]
                ),
                DailyReportHighlight(
                    summary: "项目延期风险",
                    category: .risk,
                    sourceChatName: "Boss",
                    sourceChatUsername: "wxid_boss",
                    date: now,
                    confidence: 0.85,
                    quotedSnippet: nil,
                    involved: ["Boss"]
                )
            ],
            actions: [
                DailyReportAction(
                    content: "跟进方案A实施",
                    type: .todo,
                    urgency: .high,
                    deadline: now.addingTimeInterval(3600),
                    sourceChatName: "Team Chat",
                    sourceChatUsername: "wxid_team",
                    relatedID: "1"
                )
            ],
            risks: [
                DailyReportRisk(
                    type: .overdueCommitment,
                    description: "承诺「交付报告」已超期",
                    severity: .high,
                    sourceChatName: "Boss",
                    sourceChatUsername: "wxid_boss"
                )
            ],
            pendingAsks: [],
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )
    }
}
