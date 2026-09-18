import XCTest
@testable import WeChatHUD

/// The briefing's freshness window. `GlobalBriefing.date` is the model's
/// free-text 「日期」; the check used to parse it as an ISO8601 timestamp,
/// fail, fall back to `.distantPast`, and conclude that every briefing was
/// infinitely old — so the full AI batch re-ran on every scan.
final class BriefingFreshnessTests: XCTestCase {

    private let ttl: TimeInterval = 1800

    func testAFreshBriefingSkipsTheRefresh() {
        XCTAssertTrue(InsightCoordinator.shouldSkipBriefingRefresh(
            force: false, briefing: briefing(date: "2026-09-18"),
            generatedAt: date(minutesAgo: 10), now: now, ttl: ttl
        ))
    }

    func testABriefingPastTheWindowRegenerates() {
        XCTAssertFalse(InsightCoordinator.shouldSkipBriefingRefresh(
            force: false, briefing: briefing(date: "2026-09-18"),
            generatedAt: date(minutesAgo: 31), now: now, ttl: ttl
        ))
    }

    func testForceIgnoresFreshness() {
        XCTAssertTrue(InsightCoordinator.shouldSkipBriefingRefresh(
            force: false, briefing: briefing(date: "2026-09-18"),
            generatedAt: date(minutesAgo: 1), now: now, ttl: ttl
        ))
        XCTAssertFalse(InsightCoordinator.shouldSkipBriefingRefresh(
            force: true, briefing: briefing(date: "2026-09-18"),
            generatedAt: date(minutesAgo: 1), now: now, ttl: ttl
        ))
    }

    func testNoBriefingYetAlwaysGenerates() {
        XCTAssertFalse(InsightCoordinator.shouldSkipBriefingRefresh(
            force: false, briefing: nil, generatedAt: date(minutesAgo: 1), now: now, ttl: ttl
        ))
    }

    /// A briefing with no recorded generation time is expired, not fresh — and
    /// crucially it must not be judged by the model's own date string.
    func testUnknownGenerationTimeRegenerates() {
        XCTAssertFalse(InsightCoordinator.shouldSkipBriefingRefresh(
            force: false, briefing: briefing(date: "2026-09-18"),
            generatedAt: nil, now: now, ttl: ttl
        ))
    }

    /// The guard has to be *fed* the locally recorded time. Testing the pure
    /// decision alone would still pass if the call site went back to parsing
    /// `briefing.date`, which is exactly how the window became inert.
    func testRegenerationGuardIsFedTheLocalClockNotTheModelsDate() throws {
        let source = try readSource("Services/Insight/InsightCoordinator.swift")
        let guardCall = window(of: source, "shouldSkipBriefingRefresh(", after: "func loadInsight")
        XCTAssertTrue(guardCall.contains("generatedAt: briefingGeneratedAt"),
                      "loadInsight must compare against the recorded generation time, got: \(guardCall)")
        XCTAssertFalse(guardCall.contains(".date"),
                       "the freshness guard must not read the model's date field, got: \(guardCall)")
        XCTAssertTrue(source.contains("briefingGeneratedAt = briefing == nil ? nil : now()"),
                      "generation time must be recorded when a briefing is assigned")
        XCTAssertFalse(source.contains("date(from: briefing.date"),
                       "the model's free-text date must not be parsed as a timestamp")
    }

    /// The regression itself: the model returns a date-only 「2026-09-18」 (or
    /// prose, or an empty string), which is not an ISO8601 timestamp. Freshness
    /// must still come out right, because it never looks at that field.
    func testFreshnessDoesNotDependOnTheModelsDateText() {
        for modelText in ["2026-09-18", "2026年9月18日", "今天", "", "2026-09-18T16:38:01Z"] {
            XCTAssertTrue(
                InsightCoordinator.shouldSkipBriefingRefresh(
                    force: false, briefing: briefing(date: modelText),
                    generatedAt: date(minutesAgo: 5), now: now, ttl: ttl
                ),
                "model date text \(modelText) must not affect the window"
            )
        }
    }

    // MARK: - The card's freshness label

    func testCaptionReportsOurOwnGenerationTime() {
        XCTAssertEqual(
            InsightBriefingCaption.text(generatedAt: date(secondsAgo: 20), now: now),
            "AI 摘要 · 刚刚更新"
        )
        XCTAssertEqual(
            InsightBriefingCaption.text(generatedAt: date(minutesAgo: 12), now: now),
            "AI 摘要 · 12 分钟前更新"
        )
        XCTAssertEqual(
            InsightBriefingCaption.text(generatedAt: date(minutesAgo: 200), now: now),
            "AI 摘要 · 今天 11:58 更新"
        )
        // Nothing to claim about freshness.
        XCTAssertEqual(InsightBriefingCaption.text(generatedAt: nil, now: now), "AI 摘要")
    }

    /// The card must not print the model's 「日期」 as a timestamp again.
    func testHeroDoesNotRenderTheModelsDateField() throws {
        let hero = try readSource("Views/Analytics/InsightHeroSection.swift")
        // Prose is allowed to name the field it avoids; code is not.
        let code = hero.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("briefing.date"))
    }

    // MARK: - Helpers

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/\(relativePath)"),
            encoding: .utf8
        )
    }

    /// A window of source following the first `needle` at or after `anchor`.
    private func window(of source: String, _ needle: String, after anchor: String, length: Int = 260) -> String {
        guard let a = source.range(of: anchor),
              let found = source.range(of: needle, range: a.upperBound..<source.endIndex)
        else { return "" }
        let tail = source[found.upperBound...]
        let end = tail.index(tail.startIndex, offsetBy: length, limitedBy: tail.endIndex) ?? tail.endIndex
        return String(tail[..<end])
    }

    private let now = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 18, hour: 15, minute: 18)
    )!

    private func date(minutesAgo: Int) -> Date {
        now.addingTimeInterval(-Double(minutesAgo * 60))
    }

    private func date(secondsAgo: Int) -> Date {
        now.addingTimeInterval(-Double(secondsAgo))
    }

    private func briefing(date: String) -> GlobalBriefing {
        GlobalBriefing(
            date: date,
            actionRequired: [],
            headline: "有事项等待确认",
            stats: BriefingStats(
                totalMessages: 10, myMessages: 3, activeGroups: 1,
                totalGroups: 2, activePrivateChats: 1, workRatio: 0.5
            ),
            crossTopics: [],
            darkSignals: DarkSignals(headline: nil),
            overallMood: "推进中",
            blindSpots: [],
            topSuggestion: "先回项目群"
        )
    }
}
