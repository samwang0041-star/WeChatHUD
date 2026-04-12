import XCTest
@testable import WeChatHUD

final class ReplyTimingTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        let tmp = NSTemporaryDirectory() + "test_timing_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close() }

    // MARK: - DelayDistribution

    func testDelayDistributionRandomDelay() {
        let dist = ReplyTimingProfile.DelayDistribution(p25: 30, p50: 60, p75: 180, count: 10)
        for _ in 0..<50 {
            let delay = dist.randomDelay()
            XCTAssertGreaterThanOrEqual(delay, 5) // minimum 5s
            XCTAssertLessThanOrEqual(delay, 200)  // should be within P25-P75 range
        }
    }

    func testDelayDistributionZeroCountFallback() {
        let dist = ReplyTimingProfile.DelayDistribution.zero
        let delay = dist.randomDelay()
        XCTAssertEqual(delay, 30) // fallback for no data
    }

    // MARK: - MessageUrgency

    func testUrgencyHighForQuestionMark() {
        XCTAssertEqual(MessageUrgency.detect(from: "你在吗？"), .high)
        XCTAssertEqual(MessageUrgency.detect(from: "能帮个忙吗?"), .high)
    }

    func testUrgencyHighForUrgentKeywords() {
        XCTAssertEqual(MessageUrgency.detect(from: "急！快看"), .high)
        XCTAssertEqual(MessageUrgency.detect(from: "在吗"), .high)
        XCTAssertEqual(MessageUrgency.detect(from: "赶紧回复我"), .high)
    }

    func testUrgencyNormalForRegularMessage() {
        XCTAssertEqual(MessageUrgency.detect(from: "今天天气不错"), .normal)
        XCTAssertEqual(MessageUrgency.detect(from: "昨天看的电影还可以"), .normal)
    }

    func testUrgencyLowForShortMessages() {
        XCTAssertEqual(MessageUrgency.detect(from: "嗯"), .low)
        XCTAssertEqual(MessageUrgency.detect(from: "好"), .low)
    }

    func testUrgencyDelayMultipliers() {
        XCTAssertLessThan(MessageUrgency.high.delayMultiplier, 1.0)
        XCTAssertEqual(MessageUrgency.normal.delayMultiplier, 1.0)
        XCTAssertGreaterThan(MessageUrgency.low.delayMultiplier, 1.0)
    }

    // MARK: - TimePeriod

    func testTimePeriodWorkHours() {
        // Wed 2026-04-08 10:00 CST → workHours
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 8
        components.hour = 10; components.minute = 0
        let date = cal.date(from: components)!
        let unix = Int(date.timeIntervalSince1970)
        XCTAssertEqual(StyleProfiler.timePeriod(unixTime: unix), .workHours)
    }

    func testTimePeriodEvening() {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 8  // Wednesday
        components.hour = 20; components.minute = 0
        let date = cal.date(from: components)!
        XCTAssertEqual(StyleProfiler.timePeriod(unixTime: Int(date.timeIntervalSince1970)), .evening)
    }

    func testTimePeriodLateNight() {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 8
        components.hour = 2; components.minute = 0
        let date = cal.date(from: components)!
        XCTAssertEqual(StyleProfiler.timePeriod(unixTime: Int(date.timeIntervalSince1970)), .lateNight)
    }

    func testTimePeriodWeekend() {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 11  // Saturday
        components.hour = 14; components.minute = 0
        let date = cal.date(from: components)!
        XCTAssertEqual(StyleProfiler.timePeriod(unixTime: Int(date.timeIntervalSince1970)), .weekend)
    }

    // MARK: - HUDStore Timing Profile CRUD

    func testUpsertAndLoadTimingProfile() throws {
        let profile = ReplyTimingProfile(
            chatUsername: "wxid_test",
            workHours: .init(p25: 30, p50: 60, p75: 120, count: 20),
            evening: .init(p25: 15, p50: 30, p75: 60, count: 15),
            weekend: .init(p25: 45, p50: 90, p75: 300, count: 10),
            lateNight: .zero,
            silentAtNight: true,
            lateNightReplyRate: 0.1,
            sampleCount: 45,
            lastUpdated: Date()
        )
        try store.upsertReplyTimingProfile(profile)

        let loaded = store.loadReplyTimingProfile(chatUsername: "wxid_test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.workHours.p50, 60)
        XCTAssertEqual(loaded?.evening.p25, 15)
        XCTAssertEqual(loaded?.weekend.p75, 300)
        XCTAssertTrue(loaded?.silentAtNight ?? false)
        XCTAssertEqual(loaded?.sampleCount, 45)
    }

    func testLoadReturnsNilForMissing() {
        XCTAssertNil(store.loadReplyTimingProfile(chatUsername: "nonexistent"))
    }

    func testUpsertUpdatesExisting() throws {
        try store.upsertReplyTimingProfile(ReplyTimingProfile(
            chatUsername: "c1",
            workHours: .init(p25: 10, p50: 20, p75: 30, count: 5),
            evening: .zero, weekend: .zero, lateNight: .zero,
            silentAtNight: false, lateNightReplyRate: 0.8,
            sampleCount: 5, lastUpdated: Date()
        ))
        try store.upsertReplyTimingProfile(ReplyTimingProfile(
            chatUsername: "c1",
            workHours: .init(p25: 100, p50: 200, p75: 300, count: 50),
            evening: .zero, weekend: .zero, lateNight: .zero,
            silentAtNight: true, lateNightReplyRate: 0.05,
            sampleCount: 50, lastUpdated: Date()
        ))

        let loaded = store.loadReplyTimingProfile(chatUsername: "c1")
        XCTAssertEqual(loaded?.workHours.p50, 200)
        XCTAssertTrue(loaded?.silentAtNight ?? false)
        XCTAssertEqual(loaded?.sampleCount, 50)
    }
}
