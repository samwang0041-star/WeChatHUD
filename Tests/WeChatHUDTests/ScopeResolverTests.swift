import Testing
import Foundation
@testable import WeChatHUD

@Suite("ScopeResolver")
struct ScopeResolverTests {

    @Test("This week range starts Monday 00:00 in current TZ")
    func thisWeekStartsMonday() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        // 2026-04-22 is a Wednesday
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14))!
        let range = ScopeResolver.range(.thisWeek, anchor: now, calendar: cal)
        let startComps = cal.dateComponents([.year, .month, .day, .weekday], from: range.start)
        #expect(startComps.weekday == 2)  // Monday
        #expect(startComps.day == 20)     // April 20, 2026
    }

    @Test("Custom range respects exact bounds")
    func customRange() {
        let s = Date(timeIntervalSince1970: 1000)
        let e = Date(timeIntervalSince1970: 5000)
        let r = ScopeResolver.range(.custom(start: s, end: e))
        #expect(r.start == s)
        #expect(r.end == e)
    }

    @Test("Since-last-retrospective uses provided lastRunEnd")
    func sinceLastRetro() {
        let lastEnd = Date(timeIntervalSinceNow: -3 * 86400)
        let r = ScopeResolver.range(.sinceLastRetrospective(lastRunEnd: lastEnd))
        #expect(r.start == lastEnd)
        #expect(r.end.timeIntervalSinceNow >= -1)  // ≈ now
    }

    @Test("First-time use (no last run) defaults to this-week behavior")
    func firstTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14))!
        let r = ScopeResolver.range(.sinceLastRetrospective(lastRunEnd: nil), anchor: now, calendar: cal)
        let startDay = cal.dateComponents([.day], from: r.start)
        #expect(startDay.day == 20)  // Monday of that week
    }

    @Test("Last week range covers Mon..Sun of previous week")
    func lastWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14))!
        let r = ScopeResolver.range(.lastWeek, anchor: now, calendar: cal)
        let startDay = cal.dateComponents([.day], from: r.start)
        let endDay = cal.dateComponents([.day], from: r.end)
        #expect(startDay.day == 13)  // Mon Apr 13
        #expect(endDay.day == 19)    // Sun Apr 19
    }

    @Test("Today starts at 00:00")
    func today() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 14, minute: 30))!
        let r = ScopeResolver.range(.today, anchor: now, calendar: cal)
        let startComps = cal.dateComponents([.hour, .minute, .day], from: r.start)
        #expect(startComps.hour == 0)
        #expect(startComps.minute == 0)
        #expect(startComps.day == 22)
    }

    @Test("Filter drops candidates with zero messages in range")
    func filterEmpty() {
        let candidates = [
            ScopeCandidate(chatUsername: "wxid_a", chatName: "A", isGroup: true,
                          msgCountInRange: 50, myMsgCountInRange: 5),
            ScopeCandidate(chatUsername: "wxid_b", chatName: "B", isGroup: true,
                          msgCountInRange: 0, myMsgCountInRange: 0),
            ScopeCandidate(chatUsername: "wxid_c", chatName: "C", isGroup: false,
                          msgCountInRange: 10, myMsgCountInRange: 2),
        ]
        let filtered = ScopeResolver.filter(candidates: candidates, dropEmpty: true)
        #expect(filtered.count == 2)
        #expect(filtered.map(\.chatUsername) == ["wxid_a", "wxid_c"])
    }

    @Test("Filter keeps all when dropEmpty is false")
    func filterKeepAll() {
        let candidates = [
            ScopeCandidate(chatUsername: "x", chatName: "x", isGroup: false,
                          msgCountInRange: 0, myMsgCountInRange: 0),
        ]
        #expect(ScopeResolver.filter(candidates: candidates, dropEmpty: false).count == 1)
    }
}
