import XCTest
@testable import WeChatHUD

final class CommitmentDeadlineResolverTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var messageDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 9, minute: 30))!
    }

    func testTodayTimeUsesMessageDateAnchor() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "今天17:00",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 8, hour: 17, minute: 0))
    }

    func testTomorrowAfternoonHalfHourUsesMessageDateAnchor() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "明天下午5点半",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 9, hour: 17, minute: 30))
    }

    func testTomorrowWithoutTimeDefaultsToEndOfTomorrow() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "tomorrow",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 9, hour: 23, minute: 59, second: 59))
    }

    func testExplicitDateWithAndWithoutTime() throws {
        let timed = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "2026-09-10 08:15",
            messageDate: messageDate,
            calendar: calendar
        ))
        let dateOnly = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "2026-09-10",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timed),
                       DateComponents(year: 2026, month: 9, day: 10, hour: 8, minute: 15))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dateOnly),
                       DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 59, second: 59))
    }

    func testTimeWithoutDateStaysOnMessageDayEvenWhenAlreadyPast() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "17:00前",
            messageDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 18))!,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 8, hour: 17, minute: 0))
    }

    func testSourceTextCanSupplyExplicitTimeWhenExtractedIsDescriptive() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "具体描述",
            sourceText: "我今天17:00前把清单发给你",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 8, hour: 17, minute: 0))
    }

    func testExtractedDeadlineWinsOverConflictingSourceText() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "今天17:00",
            sourceText: "明天林晓发另一项动作",
            messageDate: messageDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline),
                       DateComponents(year: 2026, month: 9, day: 8, hour: 17, minute: 0))
    }

    func testConflictingDatesInSourceFallbackRemainNil() {
        XCTAssertNil(CommitmentDeadlineResolver.resolve(
            extracted: "具体描述",
            sourceText: "我今天17:00前发清单，明天林晓再发另一项动作",
            messageDate: messageDate,
            calendar: calendar
        ))
    }

    func testInvalidCalendarDateRemainsNil() {
        XCTAssertNil(CommitmentDeadlineResolver.resolve(
            extracted: "2026-02-30 10:00",
            messageDate: messageDate,
            calendar: calendar
        ))
    }

    func testThreeDigitHourDoesNotMatchAsTwoDigitTime() {
        XCTAssertNil(CommitmentDeadlineResolver.resolve(
            extracted: "今天123:00",
            messageDate: messageDate,
            calendar: calendar
        ))
    }

    func testRelativeTwoHourDeadlineRemainsSupported() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "+2h",
            messageDate: messageDate,
            calendar: calendar
        ))
        XCTAssertEqual(deadline, messageDate.addingTimeInterval(2 * 3_600))
    }

    func testAmbiguousDeadlineTokensRemainNil() {
        for token in ["vague_soon", "inherit", "none", "尽快"] {
            XCTAssertNil(CommitmentDeadlineResolver.resolve(
                extracted: token,
                messageDate: messageDate,
                calendar: calendar
            ), token)
        }
    }

    func testInvalidTimeRemainsNil() {
        XCTAssertNil(CommitmentDeadlineResolver.resolve(
            extracted: "今天24:00",
            messageDate: messageDate,
            calendar: calendar
        ))
    }
}
