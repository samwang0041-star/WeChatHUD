import XCTest
@testable import WeChatHUD

final class RelationshipRadarTests: XCTestCase {
    func testSingleDayInsightDecodingDropsReservedInferenceFields() throws {
        let json = """
        {
          "headline": "只谈排期",
          "topics": [],
          "decisions": [],
          "action_items": [],
          "mentions_me": 0,
          "waiting_for_me": [],
          "my_commitments": [],
          "needs_my_attention": false,
          "overall_mood": "正式",
          "mood_shift": "突然变冷",
          "attitudes": [{"person": "张三", "attitude": "表面配合"}],
          "tone_changes": [{"from": "热", "to": "冷"}],
          "signal_noise_ratio": 0.5,
          "decision_efficiency": "正常",
          "importance_to_me": {"level": "中", "reason": "等回复"},
          "insight": "对方在等排期",
          "suggestion": "回一句进度"
        }
        """
        let result = try JSONDecoder().decode(ChatInsightResult.self, from: Data(json.utf8))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        for key in ChatInsightResult.reservedInferenceKeys {
            XCTAssertNil(encoded?[key], "单聊分析 must not persist \(key)")
        }
        XCTAssertEqual(result.headline, "只谈排期")
        XCTAssertEqual(result.overallMood, "正式")
    }

    func testRadarDetectsCoolingSilenceAndToneChange() {
        let points = [
            DailyInsightPoint(
                chatUsername: "wxid_peer", day: "2026-08-01", headline: "一起推进",
                topics: ["排期"], decisions: ["本周给"], waitingCount: 0,
                overallMood: "轻松", messageCount: 10, myMessageCount: 5, insight: "互动密"
            ),
            DailyInsightPoint(
                chatUsername: "wxid_peer", day: "2026-08-10", headline: "还在等",
                topics: ["排期"], decisions: [], waitingCount: 1,
                overallMood: "正式", messageCount: 8, myMessageCount: 3, insight: "开始等"
            ),
            DailyInsightPoint(
                chatUsername: "wxid_peer", day: "2026-08-20", headline: "对方连发未回",
                topics: ["排期"], decisions: [], waitingCount: 3,
                overallMood: "紧张", messageCount: 12, myMessageCount: 1, insight: "单向"
            )
        ]
        let now = day("2026-09-01")
        let snap = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_peer",
            points: points,
            now: now,
            windowDays: 30
        )
        XCTAssertEqual(snap.attitudeTrend, RelationshipRadarKind.attitudeCooling)
        XCTAssertEqual(snap.relationshipTrend, RelationshipRadarKind.trendDeteriorating)
        XCTAssertGreaterThanOrEqual(snap.silenceDays, 10)
        XCTAssertEqual(snap.moodShift, "轻松 → 紧张")
        XCTAssertFalse(snap.toneChanges.isEmpty)
        XCTAssertFalse(snap.darkSignals.isEmpty)
        XCTAssertFalse(snap.evidenceHashes.isEmpty)
    }

    func testRadarDoesNotInventAttitudeFromASingleDay() {
        let snap = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_peer",
            points: [
                DailyInsightPoint(
                    chatUsername: "wxid_peer", day: "2026-09-01", headline: "今天只聊了一句",
                    topics: ["问候"], decisions: [], waitingCount: 0,
                    overallMood: "正常", messageCount: 2, myMessageCount: 1, insight: "信息少"
                )
            ],
            now: day("2026-09-01"),
            windowDays: 30
        )
        XCTAssertEqual(snap.attitudeTrend, RelationshipRadarKind.attitudeUnknown)
        XCTAssertNil(snap.moodShift)
    }

    func testRadarRedactsPhoneNumbersInStoredSummary() {
        let snap = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_peer",
            points: [
                DailyInsightPoint(
                    chatUsername: "wxid_peer", day: "2026-08-01", headline: "打 13800138000",
                    topics: ["电话"], decisions: [], waitingCount: 0,
                    overallMood: "正常", messageCount: 4, myMessageCount: 2, insight: "留了手机"
                ),
                DailyInsightPoint(
                    chatUsername: "wxid_peer", day: "2026-08-20", headline: "还是那个号 13800138000",
                    topics: ["电话"], decisions: [], waitingCount: 2,
                    overallMood: "焦虑", messageCount: 6, myMessageCount: 1, insight: "又催"
                )
            ],
            now: day("2026-09-01"),
            windowDays: 30
        )
        XCTAssertFalse(snap.summary.contains("13800138000"))
        XCTAssertFalse(snap.moodShift?.contains("13800138000") ?? false)
    }

    func testStoreRoundTripAndBriefingLines() throws {
        let path = NSTemporaryDirectory() + "hud_radar_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let point = DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-01", headline: "推进",
            topics: ["排期"], decisions: ["周五给"], waitingCount: 0,
            overallMood: "正式", messageCount: 5, myMessageCount: 2, insight: "ok"
        )
        try store.upsertDailyInsightPoint(point)
        XCTAssertEqual(store.loadDailyInsightPoints(chatUsername: "wxid_peer").first?.topics, ["排期"])

        let snap = try RelationshipRadarService.refresh(
            store: store,
            chatUsername: "wxid_peer",
            now: day("2026-08-01")
        )
        XCTAssertEqual(store.loadRelationshipRadarSnapshot(chatUsername: "wxid_peer")?.summary, snap.summary)
        let lines = RelationshipRadarService.briefingSummaries(from: [snap])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("wxid_peer"))
    }

    func testPointFromChatInsightUsesFactsOnly() {
        let result = ChatInsightResult(
            headline: "张三在等排期",
            topics: [TopicInsight(name: "排期", messageCount: 2, participantCount: 2, summary: "问进度", status: "讨论中", myInvolvement: nil, crossChats: nil)],
            decisions: ["周五给"],
            actionItems: [],
            mentionsMe: 1,
            waitingForMe: [WaitingItem(source: "张三", what: "排期", waitingHours: 2)],
            myCommitments: ["周五给"],
            needsMyAttention: true,
            overallMood: "正式",
            signalNoiseRatio: 0.7,
            decisionEfficiency: "正常",
            importanceToMe: ImportanceLevel(level: "中", reason: "等"),
            crossChatTopics: nil,
            insight: "对方在等",
            suggestion: "回进度"
        )
        let point = RelationshipRadarService.point(
            from: result,
            chatUsername: "wxid_peer",
            day: "2026-09-01",
            messageCount: 4,
            myMessageCount: 1
        )
        XCTAssertEqual(point.topics, ["排期"])
        XCTAssertEqual(point.waitingCount, 1)
        XCTAssertEqual(point.decisions, ["周五给"])
    }

    private func day(_ value: String) -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}
