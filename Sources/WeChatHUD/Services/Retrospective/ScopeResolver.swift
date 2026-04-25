import Foundation

/// Time-range modes the user can pick in the 复盘 tab (Spec §3.1).
enum ScopeMode: Sendable {
    case sinceLastRetrospective(lastRunEnd: Date?)
    case today
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case custom(start: Date, end: Date)
}

struct DateRange: Sendable {
    let start: Date
    let end: Date
}

extension DateRange: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(start.timeIntervalSince1970)
        hasher.combine(end.timeIntervalSince1970)
    }
    static func == (lhs: DateRange, rhs: DateRange) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }
}

/// One whitelist entry that has at least one message in the resolved
/// range. Fed to GroupScreener for AI screening of work-relevant groups
/// (private chats are always included).
struct ScopeCandidate: Sendable {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let msgCountInRange: Int
    let myMsgCountInRange: Int
}

/// Pure-function scope resolver (Spec §3.1, §6.2 step 1).
enum ScopeResolver {

    /// Translates a user's mode pick into an absolute [start, end] window.
    static func range(_ mode: ScopeMode, anchor: Date = Date(), calendar: Calendar = .current) -> DateRange {
        switch mode {
        case .custom(let s, let e):
            return DateRange(start: s, end: e)
        case .sinceLastRetrospective(let lastEnd):
            if let lastEnd { return DateRange(start: lastEnd, end: anchor) }
            // First-time use → behave like thisWeek
            return range(.thisWeek, anchor: anchor, calendar: calendar)
        case .today:
            return DateRange(start: calendar.startOfDay(for: anchor), end: anchor)
        case .thisWeek:
            return DateRange(start: startOfWeek(anchor, calendar: calendar), end: anchor)
        case .lastWeek:
            let thisStart = startOfWeek(anchor, calendar: calendar)
            let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisStart)!
            let lastEnd = calendar.date(byAdding: .second, value: -1, to: thisStart)!
            return DateRange(start: lastStart, end: lastEnd)
        case .thisMonth:
            let comp = calendar.dateComponents([.year, .month], from: anchor)
            let start = calendar.date(from: comp)!
            return DateRange(start: start, end: anchor)
        case .lastMonth:
            let comp = calendar.dateComponents([.year, .month], from: anchor)
            let thisStart = calendar.date(from: comp)!
            let lastStart = calendar.date(byAdding: .month, value: -1, to: thisStart)!
            let lastEnd = calendar.date(byAdding: .second, value: -1, to: thisStart)!
            return DateRange(start: lastStart, end: lastEnd)
        }
    }

    /// Drops candidates with no messages in range.
    static func filter(candidates: [ScopeCandidate], dropEmpty: Bool = true) -> [ScopeCandidate] {
        if dropEmpty {
            return candidates.filter { $0.msgCountInRange > 0 }
        }
        return candidates
    }

    private static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2  // Monday — matches Chinese workweek convention
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }
}
