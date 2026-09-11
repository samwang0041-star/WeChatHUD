import XCTest
@testable import WeChatHUD

/// The global limiter must hold under concurrency.
///
/// `acquire` used to sleep between reading the window and appending to it, so
/// every caller that arrived during that suspension saw an empty window: N
/// concurrent callers all passed the check and the limit did nothing.
final class AIRateLimiterTests: XCTestCase {

    func testWaitTimeAdmitsUpToTheLimitThenReportsAWait() {
        var timestamps: [Date] = []
        let now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<4 {
            XCTAssertEqual(AIRateLimiter.waitTime(now: now, timestamps: &timestamps), 0)
        }
        XCTAssertEqual(timestamps.count, 4)
        XCTAssertGreaterThan(
            AIRateLimiter.waitTime(now: now, timestamps: &timestamps), 0,
            "the fifth call in the same second must wait instead of being admitted"
        )
        XCTAssertEqual(timestamps.count, 4, "a refused call must not be recorded")
    }

    func testWindowSlidesAfterOneSecond() {
        var timestamps: [Date] = []
        let start = Date(timeIntervalSince1970: 2_000)
        for _ in 0..<4 {
            _ = AIRateLimiter.waitTime(now: start, timestamps: &timestamps)
        }
        XCTAssertEqual(AIRateLimiter.waitTime(now: start.addingTimeInterval(1.01), timestamps: &timestamps), 0)
    }

    func testConcurrentAcquiresRespectTheLimit() async {
        let limiter = AIRateLimiter()
        let started = Date()

        await withTaskGroup(of: Void.self) { group in
            // 16 calls at 4 per second cannot finish in under two windows.
            // The old implementation slept *after* reading the window and then
            // appended unconditionally on wake, so a whole burst was admitted in
            // roughly one window (~1s) instead of being spread over four.
            for _ in 0..<16 {
                group.addTask { await limiter.acquire() }
            }
        }

        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(started), 2.0,
            "a 16-call burst was admitted faster than the 4-per-second limit allows"
        )
    }
}
