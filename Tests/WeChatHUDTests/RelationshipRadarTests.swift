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

    func testRadarDoesNotCrashWhenEveryDayHasEmptyMood() {
        let snap = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_peer",
            points: [
                DailyInsightPoint(
                    chatUsername: "wxid_peer", day: "2026-08-01", headline: "无语气",
                    topics: ["排期"], decisions: [], waitingCount: 0,
                    overallMood: "", messageCount: 4, myMessageCount: 2, insight: "空"
                ),
                DailyInsightPoint(
                    chatUsername: "wxid_peer", day: "2026-08-20", headline: "还是没有语气",
                    topics: ["排期"], decisions: [], waitingCount: 1,
                    overallMood: "", messageCount: 5, myMessageCount: 1, insight: "空"
                )
            ],
            now: day("2026-09-01"),
            windowDays: 30
        )
        XCTAssertTrue(snap.toneChanges.isEmpty)
        XCTAssertNil(snap.moodShift)
        XCTAssertFalse(snap.summary.isEmpty)
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

    func testRefreshAllSkipsWhenInsideThrottleWindow() throws {
        let path = NSTemporaryDirectory() + "hud_radar_throttle_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-01", headline: "推进",
            topics: ["排期"], decisions: [], waitingCount: 0,
            overallMood: "正式", messageCount: 5, myMessageCount: 2, insight: "ok"
        ))
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-20", headline: "催",
            topics: ["排期"], decisions: [], waitingCount: 2,
            overallMood: "紧张", messageCount: 8, myMessageCount: 1, insight: "等"
        ))
        let first = try RelationshipRadarService.refreshAll(
            store: store, now: day("2026-09-01"), minInterval: 60, force: true
        )
        XCTAssertEqual(first, 1)
        let skipped = try RelationshipRadarService.refreshAll(
            store: store, now: day("2026-09-01").addingTimeInterval(10), minInterval: 60
        )
        XCTAssertEqual(skipped, 0)
        let forced = try RelationshipRadarService.refreshAll(
            store: store, now: day("2026-09-01").addingTimeInterval(10), minInterval: 60, force: true
        )
        XCTAssertEqual(forced, 1)
    }

    func testRefreshAllUpdatesSilenceFromWallClock() throws {
        let path = NSTemporaryDirectory() + "hud_radar_silence_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-01", headline: "推进",
            topics: ["排期"], decisions: [], waitingCount: 0,
            overallMood: "正式", messageCount: 5, myMessageCount: 2, insight: "ok"
        ))
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-20", headline: "催",
            topics: ["排期"], decisions: [], waitingCount: 2,
            overallMood: "紧张", messageCount: 8, myMessageCount: 1, insight: "等"
        ))
        _ = try RelationshipRadarService.refreshAll(store: store, now: day("2026-08-21"), force: true)
        XCTAssertEqual(store.loadRelationshipRadarSnapshot(chatUsername: "wxid_peer")?.silenceDays, 1)
        _ = try RelationshipRadarService.refreshAll(store: store, now: day("2026-09-01"), force: true)
        XCTAssertGreaterThanOrEqual(store.loadRelationshipRadarSnapshot(chatUsername: "wxid_peer")?.silenceDays ?? 0, 10)
    }

    func testRankedPutsCoolingAndSilenceFirst() {
        let cooling = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_cool",
            points: [
                DailyInsightPoint(chatUsername: "wxid_cool", day: "2026-08-01", headline: "a", topics: ["x"], decisions: [], waitingCount: 0, overallMood: "轻松", messageCount: 8, myMessageCount: 4, insight: "a"),
                DailyInsightPoint(chatUsername: "wxid_cool", day: "2026-08-20", headline: "b", topics: ["x"], decisions: [], waitingCount: 3, overallMood: "紧张", messageCount: 10, myMessageCount: 1, insight: "b")
            ],
            now: day("2026-08-21")
        )
        let quiet = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_quiet",
            points: [
                DailyInsightPoint(chatUsername: "wxid_quiet", day: "2026-08-01", headline: "a", topics: ["x"], decisions: [], waitingCount: 0, overallMood: "正常", messageCount: 4, myMessageCount: 2, insight: "a"),
                DailyInsightPoint(chatUsername: "wxid_quiet", day: "2026-08-02", headline: "b", topics: ["x"], decisions: [], waitingCount: 0, overallMood: "正常", messageCount: 4, myMessageCount: 2, insight: "b")
            ],
            now: day("2026-09-01")
        )
        let warming = RelationshipRadarService.buildSnapshot(
            chatUsername: "wxid_warm",
            points: [
                DailyInsightPoint(chatUsername: "wxid_warm", day: "2026-08-01", headline: "a", topics: ["x"], decisions: [], waitingCount: 3, overallMood: "紧张", messageCount: 10, myMessageCount: 1, insight: "a"),
                DailyInsightPoint(chatUsername: "wxid_warm", day: "2026-08-20", headline: "b", topics: ["x"], decisions: [], waitingCount: 0, overallMood: "轻松", messageCount: 8, myMessageCount: 5, insight: "b")
            ],
            now: day("2026-08-21")
        )
        let ranked = RelationshipRadarService.ranked([warming, quiet, cooling])
        XCTAssertEqual(ranked.map(\.chatUsername), ["wxid_cool", "wxid_quiet", "wxid_warm"])
        XCTAssertEqual(RelationshipRadarService.trendLabel(cooling.relationshipTrend), "转淡")
        XCTAssertEqual(SettingsView.Tab.relationshipRadar.label, "关系雷达")
        XCTAssertTrue(SettingsView.Tab.relationshipRadar.isReview)
    }

    @MainActor
    func testScanTickRefreshGoesThroughChatMonitorOffMainHop() async throws {
        let root = NSTemporaryDirectory() + "hud_radar_scan_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: root)
        }
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-01", headline: "推进",
            topics: ["排期"], decisions: [], waitingCount: 0,
            overallMood: "正式", messageCount: 5, myMessageCount: 2, insight: "ok"
        ))
        try store.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_peer", day: "2026-08-20", headline: "催",
            topics: ["排期"], decisions: [], waitingCount: 2,
            overallMood: "紧张", messageCount: 8, myMessageCount: 1, insight: "等"
        ))
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        await monitor.refreshRelationshipRadarAfterScan(now: day("2026-09-01"))
        XCTAssertGreaterThanOrEqual(store.loadRelationshipRadarSnapshot(chatUsername: "wxid_peer")?.silenceDays ?? 0, 10)
        XCTAssertFalse(store.loadRelationshipRadarSnapshot(chatUsername: "wxid_peer")?.summary.contains("13800138000") ?? false)
    }

    private func day(_ value: String) -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}
