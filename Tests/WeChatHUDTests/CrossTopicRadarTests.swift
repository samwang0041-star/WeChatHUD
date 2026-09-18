import XCTest
@testable import WeChatHUD

/// The global briefing is asked for `cross_topics`, and the insight header
/// promises 「列出该做的事和跨对话话题」 — but nothing rendered them, so the
/// only place a shared topic could surface was a per-chat prompt that is
/// structurally incapable of knowing it.
final class CrossTopicRadarTests: XCTestCase {

    func testSharedTopicBecomesARadarFinding() {
        let findings = radarFindings(for: [
            CrossTopic(
                name: "周报口径",
                chats: ["项目群", "小李"],
                summary: "两边给的数据来源不一样",
                conflict: nil,
                status: "进行中"
            )
        ])

        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.kind, .crossTopic)
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertEqual(finding.title, "「周报口径」在 2 个对话里都在讨论")
        XCTAssertEqual(finding.evidence, "项目群、小李 · 两边给的数据来源不一样")
    }

    func testInformationConflictLeadsAndRaisesSeverity() {
        let findings = radarFindings(for: [
            CrossTopic(
                name: "上线时间",
                chats: ["A 群", "B 群", "老板"],
                summary: "三个对话都在排期",
                conflict: "A 群说周三，老板说周五",
                status: "冲突"
            )
        ])

        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.severity, .high)
        // The count is in the headline: "这几个" makes the reader scroll to the
        // 依据 line to learn something the algorithm already knows.
        XCTAssertEqual(finding.title, "「上线时间」在 3 个对话里说法不一致")
        // The conflict is the actionable half, so it leads the 依据 line.
        XCTAssertEqual(finding.evidence, "A 群、B 群、老板 · A 群说周三，老板说周五")
    }

    func testTopicConfinedToOneChatIsNotCrossChat() {
        XCTAssertTrue(radarFindings(for: [
            CrossTopic(name: "预算", chats: ["项目群"], summary: "只有这里提到", conflict: nil, status: "")
        ]).isEmpty)
    }

    func testUnnameableChatsDoNotCountTowardTheCrossChatClaim() {
        // "全局"/"未知" are the model's filler values. Counting them would
        // print 「在 2 个对话里」 for a topic that is really in one.
        XCTAssertTrue(radarFindings(for: [
            CrossTopic(name: "预算", chats: ["项目群", "全局", "未知", ""], summary: "s", conflict: nil, status: "")
        ]).isEmpty)
    }

    func testVagueTopicNameIsDropped() {
        XCTAssertTrue(radarFindings(for: [
            CrossTopic(name: "  ", chats: ["A", "B"], summary: "s", conflict: nil, status: "")
        ]).isEmpty)
    }

    func testMoreThanThreeChatsSaysEtcInsteadOfTruncatingSilently() {
        let findings = radarFindings(for: [
            CrossTopic(
                name: "客户反馈",
                chats: ["A", "B", "C", "D", "E"],
                summary: "同一条反馈在流传",
                conflict: nil,
                status: ""
            )
        ])

        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.title, "「客户反馈」在 5 个对话里都在讨论")
        // 5 named in the claim, 3 named on screen, and the truncation says so.
        XCTAssertEqual(finding.evidence, "A、B、C 等 · 同一条反馈在流传")
    }

    func testCrossChatFindingNeverPretendsToOpenASingleChat() {
        let findings = radarFindings(for: [
            CrossTopic(name: "预算", chats: ["项目群", "财务"], summary: "s", conflict: nil, status: "")
        ])

        let finding = try! XCTUnwrap(findings.first)
        XCTAssertNil(finding.chatUsername)
        XCTAssertEqual(finding.route, .expandExplanation)
        XCTAssertEqual(finding.actionLabel, "看建议")
        // The row is about the topic, not whichever chat happens to be first.
        XCTAssertEqual(finding.source, "预算")
    }

    /// The renderer labels the expanded line 意义 and falls back to boilerplate
    /// ("来自多条消息里的弱信号…") whenever 依据 is empty. A cross-chat topic is
    /// neither of those things, so it must carry no 意义 line and always have
    /// non-empty evidence.
    func testNoInventedMeaningLineAndNoEvidenceFallback() {
        for conflict in [nil, "A 说周三，B 说周五"] {
            let finding = try! XCTUnwrap(radarFindings(for: [
                CrossTopic(name: "排期", chats: ["A 群", "B 群"], summary: "在排期", conflict: conflict, status: "")
            ]).first)
            XCTAssertNil(finding.reason)
            XCTAssertFalse(finding.evidence?.isEmpty == true)
        }
    }

    // MARK: - The prompt → model → UI chain stays wired

    /// Guards the rot this test suite was written for: the prompt asked, the
    /// decoder accepted, and the view dropped it.
    func testPromptRequestsAndRadarConsumesCrossTopics() throws {
        let prompt = try read("Sources/WeChatHUD/Resources/prompts/chat_insight_global_v2.txt")
        XCTAssertTrue(prompt.contains("cross_topics"))

        let radar = try read("Sources/WeChatHUD/Services/Insight/InsightRadar.swift")
        XCTAssertTrue(
            radar.contains("briefing.crossTopics"),
            "cross_topics is billed on every global briefing; decoding it without rendering it wastes the call"
        )

        let hero = try read("Sources/WeChatHUD/Views/Analytics/InsightHeroSection.swift")
        XCTAssertTrue(hero.contains("跨对话话题"))
    }

    /// Six slots, and a page full of routine asks. A conflict about the same
    /// fact in two chats is the finding you cannot get anywhere else, so it
    /// must not be pushed off the list by ordinary follow-ups.
    func testConflictOutranksRoutineAsksButAPlainSharedTopicDoesNot() {
        let seeded = makeBriefing(crossTopics: [
            CrossTopic(name: "上线时间", chats: ["A 群", "老板"], summary: "在排期", conflict: "A 群说周三，老板说周五", status: "冲突"),
            CrossTopic(name: "报销流程", chats: ["行政群", "财务"], summary: "口径一致", conflict: nil, status: "进行中")
        ])
        let briefing = GlobalBriefing(
            date: seeded.date,
            actionRequired: (1...5).map {
                ActionRequiredItem(source: "对话\($0)", what: "确认第 \($0) 件事", waitingHours: 1, urgency: "中")
            },
            headline: seeded.headline,
            stats: seeded.stats,
            crossTopics: seeded.crossTopics,
            darkSignals: seeded.darkSignals,
            overallMood: seeded.overallMood,
            blindSpots: seeded.blindSpots,
            topSuggestion: seeded.topSuggestion
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: [:], chatNames: [:], briefing: briefing, limit: 6
        )

        XCTAssertEqual(findings.first?.kind, .crossTopic)
        XCTAssertEqual(findings.first?.severity, .high)
        // Six slots: the conflict leads and every real ask keeps its place.
        // The row that drops is the medium shared topic with nothing to act on.
        XCTAssertEqual(findings.filter { $0.kind == .action }.count, 5)
        XCTAssertFalse(findings.contains { $0.title.contains("报销流程") })
    }

    // MARK: - Copied Markdown report

    /// The overview page's 「复制为 Markdown 总结」 must apply the same
    /// cross-chat rule as the radar, or a copied report claims more than the
    /// screen showed.
    func testCopiedReportAppliesTheSameCrossChatRule() {
        let markdown = InsightOverviewReport.markdown(overview: nil, briefing: makeBriefing(crossTopics: [
            CrossTopic(name: "上线时间", chats: ["A 群", "老板"], summary: "在排期", conflict: "A 群说周三，老板说周五", status: "冲突"),
            CrossTopic(name: "只有一个对话", chats: ["A 群"], summary: "不该进报告", conflict: nil, status: "")
        ]))

        XCTAssertTrue(markdown.contains("上线时间（A 群、老板）：A 群说周三，老板说周五"))
        XCTAssertFalse(markdown.contains("只有一个对话"))
    }

    func testCopiedReportNeverHandsBackABareTitle() {
        let markdown = InsightOverviewReport.markdown(overview: nil, briefing: nil)
        XCTAssertTrue(markdown.contains("还没有可导出的分析结果"))
    }

    // MARK: - Overview heading

    /// The heading sat next to the range picker and said 今天 regardless of it.
    func testOverviewHeadingFollowsTheSelectedRange() {
        XCTAssertEqual(InsightTimeWindow.today.overviewHeading, "今天聊了什么")
        XCTAssertEqual(InsightTimeWindow.month.overviewHeading, "近 30 天聊了什么")
        for window in InsightTimeWindow.allCases {
            XCTAssertTrue(window.overviewHeading.hasPrefix(window.rawValue))
        }
    }

    // MARK: - Helpers

    private func radarFindings(for crossTopics: [CrossTopic]) -> [InsightRadarFinding] {
        InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            briefing: makeBriefing(crossTopics: crossTopics)
        )
    }

    private func makeBriefing(crossTopics: [CrossTopic]) -> GlobalBriefing {
        GlobalBriefing(
            date: "2026-09-18",
            actionRequired: [],
            headline: "有事项等待确认",
            stats: BriefingStats(
                totalMessages: 10,
                myMessages: 1,
                activeGroups: 2,
                totalGroups: 2,
                activePrivateChats: 1,
                workRatio: 1
            ),
            crossTopics: crossTopics,
            darkSignals: DarkSignals(headline: nil),
            overallMood: "紧张",
            blindSpots: [],
            topSuggestion: "先回项目群"
        )
    }

    private func read(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
