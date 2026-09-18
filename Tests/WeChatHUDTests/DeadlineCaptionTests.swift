import XCTest
@testable import WeChatHUD

/// 「本地资料 → 记录回溯」 handed every deadline to `MessageInfo.formatRelative`,
/// which is past-only: `diff = now - ts` and `diff < 60` returns 刚刚, so a
/// negative diff — tomorrow, next week — also returned 刚刚 and the row read
/// 「截止 刚刚」.
final class DeadlineCaptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFutureDeadlineNeverSaysJustNow() {
        for seconds in [30, 300, 3_600, 86_400, 604_800] {
            let caption = CommitmentPresentation.deadlineCaption(
                now.addingTimeInterval(TimeInterval(seconds)), now: now)
            XCTAssertFalse(caption.contains("刚刚"), "\(seconds)s ahead read 「\(caption)」")
            XCTAssertTrue(caption.hasPrefix("截止"), "\(seconds)s ahead read 「\(caption)」")
        }
    }

    func testPastDeadlineReadsOverdue() {
        XCTAssertEqual(
            CommitmentPresentation.deadlineCaption(now.addingTimeInterval(-600), now: now),
            "已到期")
    }

    /// Same-day deadlines carry a clock time, cross-day ones carry the date —
    /// the same shape the 承诺 page already uses.
    func testFutureDeadlineKeepsTheAbsoluteTimeShape() {
        let sameDay = CommitmentPresentation.deadlineCaption(now.addingTimeInterval(300), now: now)
        let nextWeek = CommitmentPresentation.deadlineCaption(now.addingTimeInterval(604_800), now: now)
        XCTAssertTrue(sameDay.hasPrefix("截止 "), sameDay)
        XCTAssertFalse(sameDay.contains("月"), "same day needs only the clock time: \(sameDay)")
        XCTAssertTrue(nextWeek.contains("月"), "a cross-day deadline needs the date: \(nextWeek)")
    }
}
