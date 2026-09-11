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

    // MARK: - Weekday deadlines
    //
    // The prompt's own example label is "本周五前", and weekday phrasing is the
    // most common work-deadline form in Chinese. The resolver used to handle
    // only 今天/明天/后天, absolute dates and clock times, so every weekday
    // deadline resolved to nil and the commitment was stored with no due date.
    // The anchor below (2026-09-08) is a Tuesday, which makes each expectation
    // readable: this week's Friday is 09-11, next week's Wednesday is 09-16.

    func testThisWeekWeekdayResolvesToThatWeek() throws {
        for (token, day) in [("本周五", 11), ("这周五", 11), ("本周一", 7), ("本周二", 8)] {
            let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
                extracted: token, messageDate: messageDate, calendar: calendar
            ), token)
            XCTAssertEqual(calendar.dateComponents([.month, .day], from: deadline),
                           DateComponents(month: 9, day: day), token)
        }
    }

    func testNextWeekWeekdayResolvesToFollowingWeek() throws {
        let cases = [("下周三", 16), ("下周一", 14), ("下周日", 20), ("下星期天", 20)]
        for (token, day) in cases {
            let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
                extracted: token, messageDate: messageDate, calendar: calendar
            ), token)
            XCTAssertEqual(calendar.dateComponents([.month, .day], from: deadline),
                           DateComponents(month: 9, day: day), token)
        }
    }

    func testBareWeekdayMeansTheUpcomingOne() throws {
        // Tuesday anchor: 周五 is this week, 周一 already passed so it means next week.
        for (token, day) in [("周五", 11), ("星期三", 9), ("周日", 13), ("周一", 14), ("周二", 8)] {
            let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
                extracted: token, messageDate: messageDate, calendar: calendar
            ), token)
            XCTAssertEqual(calendar.dateComponents([.month, .day], from: deadline),
                           DateComponents(month: 9, day: day), token)
        }
    }

    func testWeekdayDeadlinesDefaultToEndOfThatDay() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "本周五前", messageDate: messageDate, calendar: calendar
        ))
        XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .minute], from: deadline),
                       DateComponents(month: 9, day: 11, hour: 23, minute: 59))
    }

    func testWeekdayCombinedWithTimeOfDay() throws {
        let cases = [
            ("下周三下午3点", DateComponents(month: 9, day: 16, hour: 15, minute: 0)),
            ("周五 09:30", DateComponents(month: 9, day: 11, hour: 9, minute: 30)),
            // A meridiem with no clock time ("中午") is genuinely ambiguous, so
            // the day resolves to its end — a deadline the user cannot miss.
            ("本周四中午", DateComponents(month: 9, day: 10, hour: 23, minute: 59)),
        ]
        for (token, expected) in cases {
            let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
                extracted: token, messageDate: messageDate, calendar: calendar
            ), token)
            XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .minute], from: deadline),
                           expected, token)
        }
    }

    func testWeekdayFromHumanLabelWhenExtractedIsVague() throws {
        let deadline = try XCTUnwrap(CommitmentDeadlineResolver.resolve(
            extracted: "vague_soon", label: "本周五前", messageDate: messageDate, calendar: calendar
        ))
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: deadline),
                       DateComponents(month: 9, day: 11))
    }

    func testWeekdayMixedWithOtherDateSignalsStaysAmbiguous() {
        for token in ["明天或周五", "本周五和 2026-09-20", "下周三/明天"] {
            XCTAssertNil(CommitmentDeadlineResolver.resolve(
                extracted: token, messageDate: messageDate, calendar: calendar
            ), token)
        }
    }

    func testLastWeekWeekdayIsNotTreatedAsUpcoming() {
        // A deadline in the past must not silently become next week's.
        let deadline = CommitmentDeadlineResolver.resolve(
            extracted: "上周五", messageDate: messageDate, calendar: calendar
        )
        guard let deadline else { return }  // acceptable: refused outright
        XCTAssertLessThan(deadline, messageDate, "上周五 must not resolve into the future")
    }
}
