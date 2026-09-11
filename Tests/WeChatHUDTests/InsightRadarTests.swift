import XCTest
@testable import WeChatHUD

final class InsightRadarTests: XCTestCase {
    func testBuildFindingsPrioritizesWaitingBeforeSoftSignals() {
        let result = makeInsight(
            waitingForMe: [
                WaitingItem(source: "张三", what: "等我确认排期", waitingHours: 3)
            ]
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: ["project@chatroom": result],
            chatNames: ["project@chatroom": "项目群"]
        )

        XCTAssertEqual(findings.first?.kind, .waiting)
        XCTAssertEqual(findings.first?.severity, .high)
        XCTAssertEqual(findings.first?.chatUsername, "project@chatroom")
        XCTAssertEqual(findings.first?.route, .openChat("project@chatroom"))
    }

    /// The radar is evidence-only: a card needs a named chat behind it.
    ///
    /// The old version of this test asserted `!contains(.pressure)` — which the
    /// builder satisfies by construction, because it has no pressure path at
    /// all — so the assertion could not fail and the "suppression" it claimed
    /// to verify was never exercised. These two runs pin both halves: counters
    /// alone produce nothing, a named contact produces a card.
    func testOverviewEvidenceProducesRelationshipCardButCountersAloneDoNot() {
        let countersOnly = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            overview: makeOverview(overdueChats: 3, pendingAsks: 248, urgentAsks: 5),
            limit: 6
        )
        XCTAssertTrue(countersOnly.isEmpty, "aggregate counters without a named chat are not a radar card")

        let withEvidence = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: ["vip@chatroom": "重要客户"],
            overview: makeOverview(neglectedHighValue: [(name: "重要客户", role: "客户")]),
            limit: 6
        )
        XCTAssertEqual(withEvidence.map(\.kind), [.relationship])
        XCTAssertEqual(withEvidence.first?.chatUsername, "vip@chatroom")
        XCTAssertEqual(withEvidence.first?.route, .openChat("vip@chatroom"))
    }

    /// Contract: only action / waiting / relationship cards leave `buildFindings`.
    /// Adding an attitude, pressure or blind-spot card without the evidence
    /// logic those signals need fails here on purpose.
    func testRadarEmitsOnlyEvidenceBackedKinds() {
        let result = makeInsight()
        let findings = InsightRadar.buildFindings(
            chatInsights: ["project@chatroom": result],
            chatNames: ["project@chatroom": "项目群"],
            overview: makeOverview(overdueChats: 1, pendingAsks: 248, urgentAsks: 0),
            limit: 6
        )
        XCTAssertTrue(
            findings.allSatisfy { [.action, .waiting, .relationship].contains($0.kind) },
            "unexpected radar kinds: \(findings.map(\.kind))"
        )
    }

    func testBriefingActionMapsDisplayNameBackToChatUsername() {
        let briefing = GlobalBriefing(
            date: "2026-05-04",
            actionRequired: [
                ActionRequiredItem(source: "项目群", what: "确认周报口径", waitingHours: 2, urgency: "高")
            ],
            headline: "有事项等待确认",
            stats: BriefingStats(
                totalMessages: 10,
                myMessages: 1,
                activeGroups: 1,
                totalGroups: 1,
                activePrivateChats: 0,
                workRatio: 1
            ),
            crossTopics: [],
            darkSignals: DarkSignals(headline: nil),
            overallMood: "紧张",
            blindSpots: [],
            topSuggestion: "先回项目群"
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: ["project@chatroom": "项目群"],
            briefing: briefing
        )

        XCTAssertEqual(findings.first?.kind, .action)
        XCTAssertEqual(findings.first?.chatUsername, "project@chatroom")
        XCTAssertEqual(findings.first?.severity, .high)
        XCTAssertEqual(findings.first?.route, .openChat("project@chatroom"))
        XCTAssertEqual(findings.first?.actionLabel, "打开对话")
    }

    func testBriefingActionFallsBackToInlineExplanationWhenChatCannotBeMapped() {
        let briefing = makeBriefing(actionSource: "陌生群", action: "确认周报口径")

        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            briefing: briefing
        )

        XCTAssertEqual(findings.first?.kind, .action)
        XCTAssertNil(findings.first?.chatUsername)
        XCTAssertEqual(findings.first?.route, .expandExplanation)
        XCTAssertEqual(findings.first?.actionLabel, "看处理建议")
    }

    func testNonConcreteGlobalBriefingSourcesAreSuppressed() {
        let briefing = makeBriefing(actionSource: "全局", action: "今日有 248 个请求待处理")

        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            briefing: briefing,
            limit: 6
        )

        XCTAssertTrue(findings.isEmpty)
    }

    func testPlaceholderOnlyFindingsAreFiltered() {
        let result = makeInsight(
            waitingForMe: [
                WaitingItem(source: "张三", what: "[消息]", waitingHours: 2)
            ]
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: ["project@chatroom": result],
            chatNames: ["project@chatroom": "项目群"]
        )

        XCTAssertFalse(findings.contains { $0.kind == .waiting })
    }

    func testSemanticDeduplicationCollapsesBriefingAndChatActionForSameChat() {
        let briefing = makeBriefing(actionSource: "项目群", action: "确认 周报口径!")
        let result = makeInsight(
            actionItems: [
                InsightActionItem(what: "确认周报口径", who: "我", deadline: nil)
            ],
            needsMyAttention: true
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: ["project@chatroom": result],
            chatNames: ["project@chatroom": "项目群"],
            briefing: briefing,
            limit: 6
        )

        let followups = findings.filter { $0.kind == .action || $0.kind == .waiting }
        XCTAssertEqual(followups.count, 1)
        XCTAssertEqual(followups.first?.route, .openChat("project@chatroom"))
    }

    func testBlindSpotDiagnosticsAreSuppressedFromMainRadar() {
        let briefing = GlobalBriefing(
            date: "2026-05-04",
            actionRequired: [],
            headline: "有盲区",
            stats: BriefingStats(
                totalMessages: 10,
                myMessages: 1,
                activeGroups: 1,
                totalGroups: 1,
                activePrivateChats: 0,
                workRatio: 1
            ),
            crossTopics: [],
            darkSignals: DarkSignals(headline: nil),
            overallMood: "紧张",
            blindSpots: ["检查今天是否漏看客户问题"],
            topSuggestion: "先看盲区"
        )

        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            briefing: briefing,
            overview: makeOverview(neglectedHighValue: [(name: "重要客户", role: "客户")]),
            limit: 6
        )

        XCTAssertFalse(findings.contains { $0.kind == .blindSpot })
        XCTAssertTrue(findings.contains { $0.kind == .relationship && $0.route == .expandRelationships })
    }

    func testRelationshipCardsNamePersonReasonAndPlainAction() {
        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: ["ponge_wxid": "ponge"],
            overview: makeOverview(neglectedHighValue: [(name: "ponge", role: "家人")]),
            limit: 6
        )

        let relationship = findings.first { $0.kind == .relationship }
        XCTAssertEqual(relationship?.source, "ponge")
        XCTAssertEqual(relationship?.title, "ponge 最近互动少，适合补一句")
        XCTAssertEqual(relationship?.evidence, "根据近期互动统计 · 家人")
        XCTAssertEqual(relationship?.actionLabel, "打开对话")
        XCTAssertEqual(relationship?.route, .openChat("ponge_wxid"))
    }

    func testUserFacingActionLabelsAvoidInternalTerms() {
        let briefing = makeBriefing(actionSource: "陌生群", action: "确认周报口径")
        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            briefing: briefing,
            overview: makeOverview(neglectedHighValue: [(name: "重要客户", role: "客户")]),
            limit: 6
        )

        let bannedLabels = ["展开压力", "展开说明", "展开关系", "展开判断", "值得看", "全局"]
        for finding in findings {
            XCTAssertFalse(bannedLabels.contains(finding.actionLabel))
            XCTAssertFalse(bannedLabels.contains(finding.source))
        }
    }

    func testPendingAskAggregateWithoutListIsNotRadarCard() {
        let findings = InsightRadar.buildFindings(
            chatInsights: [:],
            chatNames: [:],
            overview: makeOverview(pendingAsks: 248, urgentAsks: 0),
            limit: 6
        )

        XCTAssertTrue(findings.isEmpty)
    }

    private func makeInsight(
        waitingForMe: [WaitingItem] = [],
        actionItems: [InsightActionItem] = [],
        needsMyAttention: Bool = false
    ) -> ChatInsightResult {
        ChatInsightResult(
            headline: "项目群需要关注",
            topics: [],
            decisions: [],
            actionItems: actionItems,
            mentionsMe: 0,
            waitingForMe: waitingForMe,
            myCommitments: [],
            needsMyAttention: needsMyAttention,
            overallMood: "正常",
            signalNoiseRatio: 0.8,
            decisionEfficiency: "正常",
            importanceToMe: ImportanceLevel(level: "中", reason: "测试"),
            crossChatTopics: [],
            insight: "测试洞察",
            suggestion: "测试建议"
        )
    }

    private func makeBriefing(actionSource: String, action: String) -> GlobalBriefing {
        GlobalBriefing(
            date: "2026-05-04",
            actionRequired: [
                ActionRequiredItem(source: actionSource, what: action, waitingHours: 2, urgency: "高")
            ],
            headline: "有事项等待确认",
            stats: BriefingStats(
                totalMessages: 10,
                myMessages: 1,
                activeGroups: 1,
                totalGroups: 1,
                activePrivateChats: 0,
                workRatio: 1
            ),
            crossTopics: [],
            darkSignals: DarkSignals(headline: nil),
            overallMood: "紧张",
            blindSpots: [],
            topSuggestion: "先回项目群"
        )
    }

    private func makeOverview(
        overdueChats: Int = 0,
        neglectedHighValue: [(name: String, role: String)] = [],
        pendingAsks: Int = 0,
        urgentAsks: Int = 0
    ) -> ChatInsightEngine.GlobalOverview {
        ChatInsightEngine.GlobalOverview(
            totalMessages: 0,
            myMessages: 0,
            activeChats: 0,
            totalChats: 0,
            participants: 0,
            messagesByHour: Array(repeating: 0, count: 24),
            myRatio: 0,
            initiationRate: 0,
            groupMessages: 0,
            privateMessages: 0,
            groupChats: 0,
            privateChats: 0,
            typeDistribution: [],
            messagesByWeekday: Array(repeating: 0, count: 7),
            workHourMessages: 0,
            eveningMessages: 0,
            nightMessages: 0,
            morningMessages: 0,
            afterHoursRatio: 0,
            busiestHour: 0,
            busiestWeekday: 0,
            weekdayTotal: 0,
            weekendTotal: 0,
            avgResponseSeconds: 0,
            responseRate: 0,
            overdueChats: overdueChats,
            topContacts: [],
            oneWayChats: [],
            neglectedVIPs: [],
            tierDistribution: [],
            roleDistribution: [],
            mostSymmetric: nil,
            leastSymmetric: nil,
            workMessages: 0,
            lifeMessages: 0,
            otherMessages: 0,
            workAfterHoursCount: 0,
            boundaryScore: 100,
            atMentionChats: 0,
            superiorMessages: 0,
            subordinateMessages: 0,
            peerMessages: 0,
            externalMessages: 0,
            personalMessages: 0,
            activeGroupCount: 0,
            pendingCommitments: 0,
            overdueCommitments: 0,
            fulfilledCommitments: 0,
            commitmentCompletionRate: 0,
            vipMessageRatio: 0,
            topTimeBlackHoles: [],
            neglectedHighValue: neglectedHighValue,
            avgMessagesPerChat: 0,
            pendingAsks: pendingAsks,
            urgentAsks: urgentAsks,
            recalledMessages: 0,
            recentDensityRatio: 0
        )
    }
}
