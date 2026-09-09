import Foundation
import XCTest
@testable import WeChatHUD

/// Opt-in live acceptance for historical daily-report semantics.
///
/// The test reads the saved provider configuration but uses only a temporary
/// HUDStore and fictional source-day data. It never opens WeChat data or sends
/// a message. By default it skips before reading credentials.
final class LiveHistoricalReportAcceptanceTests: XCTestCase {
    private var store: HUDStore!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechathud-live-historical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        store = HUDStore(dbPath: temporaryDirectory.appendingPathComponent("hud.sqlite3").path)
        try store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    func testHistoricalPromptResourceDoesNotRequestNextDayPlan() throws {
        let sourceDay = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        let generatedDay = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 8)))
        let report = DailyReport(
            date: sourceDay,
            dateRange: (sourceDay, generatedDay),
            generatedAt: generatedDay,
            metrics: DailyReportMetrics(
                unreadMessageCount: 0, pendingTodoCount: 0, pendingAskCount: 0,
                pendingCommitmentCount: 0, overdueCommitmentCount: 0, replyDebtCount: 0,
                recalledMessageCount: 0, highlightCount: 1, analyzedChatCount: 1
            ),
            highlights: [DailyReportHighlight(
                summary: "林晓提交风险清单，我确认已收到",
                category: .progress,
                sourceChatName: "项目协作群（合成历史）",
                sourceChatUsername: "synthetic-history-group",
                date: sourceDay,
                confidence: 1,
                quotedSnippet: "林晓提交风险清单，我确认已收到"
            )],
            actions: [], risks: [], pendingAsks: [],
            narrative: nil, tomorrowFocus: nil, wechatDraft: nil
        )
        let template = try PromptLoader().load(version: "daily_report_v1")
        let prompt = AIDailyReportGenerator(aiService: AIService(config: AIConfig()), store: HUDStore(dbPath: ":memory:"))
            .formatPrompt(template: template, report: report)
        XCTAssertFalse(prompt.contains("明日计划"))
        XCTAssertTrue(prompt.contains("不写后续计划"))
    }

    func testHistoricalDailyReportUsesSelectedDateAndRetainsDeliverable() async throws {
        guard ProcessInfo.processInfo.environment["WCHUD_LIVE_COMPANION_AI"] == "1" else {
            throw XCTSkip("opt-in only: set WCHUD_LIVE_COMPANION_AI=1 to call the configured provider")
        }

        let config = try loadConfiguredAI()
        guard config.provider.providerID.lowercased().contains("deepseek"),
              config.provider.model.lowercased().contains("flash"),
              !config.provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("saved DeepSeek flash configuration is absent or incomplete")
        }
        try store.setSettingJSON("ai", value: config)

        var calendar = Calendar.current
        calendar.timeZone = .current
        let selectedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        let generatedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 8)))
        let report = DailyReport(
            date: selectedDay,
            dateRange: (selectedDay, generatedDay),
            generatedAt: generatedDay.addingTimeInterval(9 * 60 * 60),
            metrics: DailyReportMetrics(
                unreadMessageCount: 0,
                pendingTodoCount: 0,
                pendingAskCount: 0,
                pendingCommitmentCount: 0,
                overdueCommitmentCount: 0,
                replyDebtCount: 0,
                recalledMessageCount: 0,
                highlightCount: 1,
                analyzedChatCount: 1
            ),
            highlights: [DailyReportHighlight(
                summary: "林晓提交风险清单，我确认已收到",
                category: .progress,
                sourceChatName: "项目协作群（合成历史）",
                sourceChatUsername: "synthetic-history-group",
                date: selectedDay.addingTimeInterval(10 * 60 * 60),
                confidence: 0.96,
                quotedSnippet: "林晓提交风险清单，我确认已收到",
                involved: ["林晓"]
            )],
            actions: [],
            risks: [],
            pendingAsks: [],
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )

        let enriched = await AIDailyReportGenerator(
            aiService: AIService(config: config),
            store: store
        ).enrich(report)

        let draft = enriched.wechatDraft ?? ""
        // Persist sanitized output before assertions so a failed live response
        // remains inspectable without exposing provider credentials or errors.
        writeEvidence(
            provider: config.provider.providerID,
            model: config.provider.model,
            status: enriched.status.rawValue,
            narrative: enriched.narrative ?? "",
            tomorrowFocus: enriched.tomorrowFocus ?? "",
            draft: draft
        )
        XCTAssertEqual(enriched.status, .aiEnhanced)
        XCTAssertEqual(enriched.date, selectedDay)
        XCTAssertNotNil(enriched.narrative)
        XCTAssertNotNil(enriched.wechatDraft)
        XCTAssertTrue(draft.contains("风险清单"), "draft must retain the concrete source-day deliverable")
        XCTAssertTrue((enriched.narrative ?? "").contains("我") || draft.contains("我"), "output must retain who confirmed receipt")
        XCTAssertFalse(draft.contains("明日计划"), "historical draft must not invent a next-day plan")
        XCTAssertTrue(
            draft.contains("2026-09-07") || draft.contains("2026年9月7日") || draft.contains("9月7日"),
            "draft must refer to the selected historical date"
        )

    }

    private func loadConfiguredAI() throws -> AIConfig {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".wechat-hud/device-settings.json")
        let device = try DeviceSettingsStore(path: path)
        guard let raw = device.get("ai"), let data = raw.data(using: .utf8) else {
            throw NSError(domain: "LiveHistoricalReportAcceptanceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing device AI settings"])
        }
        var config = try JSONDecoder().decode(AIConfig.self, from: data)
        config.migrateIfNeeded()
        return config
    }

    private func writeEvidence(provider: String, model: String, status: String, narrative: String, tomorrowFocus: String, draft: String) {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/qa/2026-09-08/synthetic-historical-ai.md")
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let text = """
        # Synthetic historical daily-report AI acceptance

        This file contains only synthetic output and provider/model metadata. No API key, endpoint, WeChat row, contact data, or message delivery is included.

        - Provider: `\(provider)`
        - Model: `\(model)`
        - Enriched status: `\(status)`
        - Evidence generated at: `\(generatedAt)`

        ## Generated synthetic output

        - narrative: \(narrative.replacingOccurrences(of: "\n", with: " "))
        - tomorrow_focus: \(tomorrowFocus.replacingOccurrences(of: "\n", with: " "))
        - wechat_draft: \(draft.replacingOccurrences(of: "\n", with: " "))
        """
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("could not write synthetic historical evidence: \(error.localizedDescription)")
        }
    }
}
