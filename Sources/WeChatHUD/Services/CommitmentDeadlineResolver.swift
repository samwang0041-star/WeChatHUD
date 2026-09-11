import Foundation

/// Resolves the human-facing deadline vocabulary emitted by the commitment
/// prompt. This is intentionally separate from `MessageHelpers.resolveDeadline`:
/// classifier relative values such as `+2h` have different semantics.
enum CommitmentDeadlineResolver {
    private enum FieldResult {
        case none
        case resolved(Date)
        case invalid
    }

    /// Resolve a deadline using `messageDate` as the only temporal anchor.
    ///
    /// Supported forms include `今天17:00`, `明天下午5点半`, `后天 09:30`,
    /// `下周三`, `本周五前`, `周五 09:30`, `2026-09-08 17:00`, and the
    /// conservative `tomorrow` token. A date without a time resolves to that
    /// date's end (23:59:59 in `calendar`). A time without a date stays on the
    /// message's calendar day, even when that time has already passed; the
    /// resolver never silently moves it to the next day. `vague_soon`,
    /// `inherit`, and `none` remain unresolved.
    static func resolve(
        extracted: String,
        label: String = "",
        sourceText: String = "",
        messageDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        // Keep the model's extracted value and human-facing label independent.
        // A source message can mention another person's date, so it is only a
        // fallback after both structured fields fail to provide a clear signal.
        switch resolveField(extracted, messageDate: messageDate, calendar: calendar) {
        case .resolved(let date): return date
        case .invalid: return nil
        case .none: break
        }
        switch resolveField(label, messageDate: messageDate, calendar: calendar) {
        case .resolved(let date): return date
        case .invalid: return nil
        case .none: break
        }
        if case .resolved(let date) = resolveField(sourceText, messageDate: messageDate, calendar: calendar) {
            return date
        }
        return nil
    }

    private static func resolveField(
        _ rawText: String,
        messageDate: Date,
        calendar: Calendar
    ) -> FieldResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()
        let vagueTokens = Set(["", "none", "vague_soon", "inherit"])
        guard !vagueTokens.contains(normalized) else { return .none }

        if let relative = relativeDeadline(normalized) {
            return .resolved(messageDate.addingTimeInterval(relative))
        }

        let dateSignals = dateSignals(in: text, messageDate: messageDate, calendar: calendar)
        guard !dateSignals.isAmbiguous else { return .invalid }

        let dayBase: Date
        let dayOffset: Int
        let hasDateSignal: Bool
        if let explicit = dateSignals.absoluteDate {
            dayBase = explicit
            dayOffset = 0
            hasDateSignal = true
        } else if dateSignals.dayOffset == 1 {
            dayBase = messageDate
            dayOffset = 1
            hasDateSignal = true
        } else if dateSignals.dayOffset == 2 {
            dayBase = messageDate
            dayOffset = 2
            hasDateSignal = true
        } else if dateSignals.dayOffset == 0 {
            dayBase = messageDate
            dayOffset = 0
            hasDateSignal = true
        } else {
            dayBase = messageDate
            dayOffset = 0
            hasDateSignal = false
        }

        let targetDay: Date
        if dayOffset == 0 {
            targetDay = dayBase
        } else {
            guard let shifted = calendar.date(byAdding: .day, value: dayOffset, to: dayBase) else { return .invalid }
            targetDay = shifted
        }

        let time = timeOfDay(in: text)
        // A date token plus malformed time syntax (for example, 24:00) must
        // stay unresolved instead of degrading to that date's end of day.
        if time == nil && hasTimeSyntax(in: text) { return .invalid }
        guard hasDateSignal || time != nil else { return .none }
        if let time {
            var components = calendar.dateComponents([.year, .month, .day], from: targetDay)
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            guard let date = calendar.date(from: components) else { return .invalid }
            return .resolved(date)
        }

        // Date-only deadlines intentionally use the end of that calendar day.
        guard let date = endOfDay(targetDay, calendar: calendar) else { return .invalid }
        return .resolved(date)
    }

    private struct DateSignals {
        let absoluteDate: Date?
        let dayOffset: Int?
        let isAmbiguous: Bool
    }

    private static func dateSignals(in text: String, messageDate: Date, calendar: Calendar) -> DateSignals {
        let pattern = #"(?<!\d)(\d{4})\s*(?:-|/|年)\s*(\d{1,2})\s*(?:-|/|月)\s*(\d{1,2})\s*日?"#
        let absoluteDates = allMatches(pattern: pattern, in: text).compactMap { match -> Date? in
            guard match.count == 4,
                  let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]) else {
                return nil
            }
            return makeValidatedDate(year: year, month: month, day: day, calendar: calendar)
        }
        let hasMalformedAbsoluteDate = allMatches(pattern: pattern, in: text).count != absoluteDates.count

        var dayOffsets: [Int] = []
        if text.range(of: "后天") != nil { dayOffsets.append(2) }
        if text.range(of: "明天") != nil || text.range(of: "明日") != nil || text.range(of: "tomorrow", options: .caseInsensitive) != nil {
            dayOffsets.append(1)
        }
        if text.range(of: "今天") != nil || text.range(of: "今日") != nil {
            dayOffsets.append(0)
        }

        // Weekday names resolve to a concrete day, so they join the absolute
        // candidates and take part in the same conflict checks: "明天或周五"
        // names two days and must stay ambiguous rather than pick one.
        var dayCandidates = absoluteDates
        if let weekday = weekdayTarget(in: text, messageDate: messageDate, calendar: calendar) {
            dayCandidates.append(weekday)
        }

        let dayConflict = Set(dayOffsets).count > 1
        let mixedAbsoluteAndRelative = !dayCandidates.isEmpty && !dayOffsets.isEmpty
        let absoluteConflict = Set(dayCandidates.map { calendar.dateComponents([.year, .month, .day], from: $0) }).count > 1
        return DateSignals(
            absoluteDate: dayCandidates.first,
            dayOffset: dayOffsets.first,
            isAmbiguous: hasMalformedAbsoluteDate || absoluteConflict || dayConflict || mixedAbsoluteAndRelative
        )
    }

    /// Chinese weekday reference → the calendar day it names.
    ///
    /// Weekday phrasing is the most common work-deadline form in Chinese, and
    /// the commitment prompt's own example label is `本周五前`. Without this
    /// every weekday deadline resolved to nothing — and worse, text that also
    /// carried a clock time (`下周三下午3点`) resolved to *today* at that time,
    /// because the weekday token was ignored and only the time matched. A
    /// missing due date is a gap; a confidently wrong one is a bug.
    ///
    /// `本`/`这` pins the day to the message's own week, `下` to the following
    /// one, `上` to the previous one. A bare weekday means the upcoming
    /// occurrence: "周五" said on a Saturday is the coming Friday, not the one
    /// that has just passed.
    private static func weekdayTarget(in text: String, messageDate: Date, calendar: Calendar) -> Date? {
        let pattern = #"(下下周|下下星期|下下礼拜|上周|上星期|上礼拜|本周|本星期|这周|这星期|下周|下星期|下礼拜|周|星期|礼拜)\s*([一二三四五六日天])"#
        guard let match = firstMatch(pattern: pattern, in: text), match.count == 3,
              let weekday = weekdayNumber(match[2]) else { return nil }

        let qualifier = match[1]
        let isBare = !["下下周", "下下星期", "下下礼拜", "上周", "上星期", "上礼拜",
                       "本周", "本星期", "这周", "这星期", "下周", "下星期", "下礼拜"].contains(qualifier)
        let weekOffset: Int
        switch qualifier {
        case "下下周", "下下星期", "下下礼拜": weekOffset = 2
        case "下周", "下星期", "下礼拜": weekOffset = 1
        case "上周", "上星期", "上礼拜": weekOffset = -1
        default: weekOffset = 0
        }

        let messageDay = calendar.startOfDay(for: messageDate)
        // Chinese weeks run Monday-first regardless of the locale's
        // `firstWeekday`; `Calendar.weekday` is Sunday == 1.
        let daysSinceMonday = (calendar.component(.weekday, from: messageDay) + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: messageDay),
              let named = calendar.date(byAdding: .day, value: weekOffset * 7 + (weekday - 1), to: weekStart) else {
            return nil
        }
        // Comparing start-of-day values keeps "has this day already gone by"
        // unambiguous; `named == messageDay` is today, and stays today.
        if isBare, named < messageDay {
            return calendar.date(byAdding: .day, value: 7, to: named)
        }
        return named
    }

    private static func weekdayNumber(_ token: String) -> Int? {
        switch token {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日", "天": return 7
        default: return nil
        }
    }

    private static func makeValidatedDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func timeOfDay(in text: String) -> (hour: Int, minute: Int)? {
        // Requires a colon or Chinese hour marker, so the month/day portion
        // of a date-only value cannot be mistaken for a time.
        let pattern = #"(?<!\d)(?:(上午|下午|中午|晚上|早上|凌晨)\s*)?(\d{1,2})\s*(?:(?:[:：]\s*(\d{1,2}))|(?:(?:点|时)\s*(半|\d{1,2}分?)?))(?!\d)"#
        guard let match = firstMatch(pattern: pattern, in: text), match.count == 5,
              let rawHour = Int(match[2]), rawHour <= 23 else { return nil }

        var hour = rawHour
        let meridiem = match[1]
        if meridiem == "下午" || meridiem == "晚上" {
            if hour < 12 { hour += 12 }
        } else if meridiem == "中午" {
            if hour < 11 { hour += 12 }
        } else if meridiem == "凌晨" {
            if hour == 12 { hour = 0 }
        }

        let minute: Int
        if !match[3].isEmpty {
            guard let parsed = Int(match[3]), parsed <= 59 else { return nil }
            minute = parsed
        } else if match[4] == "半" {
            minute = 30
        } else if !match[4].isEmpty {
            let digits = match[4].filter(\.isNumber)
            guard let parsed = Int(digits), parsed <= 59 else { return nil }
            minute = parsed
        } else {
            minute = 0
        }
        return (hour, minute)
    }

    private static func hasTimeSyntax(in text: String) -> Bool {
        let pattern = #"(?<!\d)\d+\s*(?:[:：]\s*\d+|(?:点|时))(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Ceiling on a relative offset, a little over a year. The vocabulary the
    /// prompt teaches is `+3d` / `+2w`; a larger number is the model emitting
    /// noise, and rejecting it keeps the commitment unresolved rather than
    /// giving it a fabricated date.
    private static let maxRelativeDeadline: TimeInterval = 400 * 86_400

    private static func relativeDeadline(_ text: String) -> TimeInterval? {
        guard text.hasPrefix("+"), text.count >= 3 else { return nil }
        let numberPart = text.dropFirst().dropLast()
        // `isFinite` is load-bearing: `Double("1e400")` is `+∞`, which
        // survives `addingTimeInterval` into a `Date` whose
        // `timeIntervalSince1970` traps `Int(_:)` at the storage layer.
        guard let number = Double(numberPart), number.isFinite, number > 0 else { return nil }
        let scale: TimeInterval
        switch text.last {
        case "m": scale = 60
        case "h": scale = 3_600
        case "d": scale = 86_400
        case "w": scale = 604_800
        default: return nil
        }
        let interval = number * scale
        guard interval <= maxRelativeDeadline else { return nil }
        return interval
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-1)
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func allMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
                return String(text[swiftRange])
            }
        }
    }
}
