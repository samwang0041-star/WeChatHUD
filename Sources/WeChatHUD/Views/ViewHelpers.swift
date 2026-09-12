import SwiftUI

// MARK: - Shared view utility functions

/// The product's one relative-time vocabulary.
///
/// Timestamps used to be spelled three ways — a compact 9-minute form in
/// rows, a suffixed sync stamp in the island header, a spaced form in the
/// banner — which read as three
/// different clocks in one panel. Formatting lives here only; callers add
/// their own suffix instead of re-deriving the numbers.
enum RelativeTimeFormatter {
    /// "刚刚" / "9 分钟前" / "3 小时前" / "2 天前".
    static func relativeLabel(_ date: Date, now: Date = Date()) -> String {
        let diff = Int(now.timeIntervalSince(date))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60) 分钟前" }
        if diff < 86400 { return "\(diff / 3600) 小时前" }
        return "\(diff / 86400) 天前"
    }

    /// Same vocabulary with a caller-owned suffix, e.g. a fresh "同步"
    /// stamp or a "9 分钟前" one.
    static func relativeLabel(_ date: Date, suffix: String, now: Date = Date()) -> String {
        let label = relativeLabel(date, now: now)
        return label == "刚刚" ? "刚刚\(suffix)" : "\(label)\(suffix)"
    }
}

/// Human-readable relative time string for a given date.
/// Used across multiple rows and views in the HUD.
func relativeTime(_ date: Date) -> String {
    RelativeTimeFormatter.relativeLabel(date)
}

/// Compute a unix timestamp for snooze-until operations.
/// `hour` is a 24-h clock value. `nextDay` forces the result to tomorrow;
/// if `nextDay` is false and the target hour has already passed today,
/// it automatically rolls over to tomorrow.
func snoozeTarget(hour: Int, nextDay: Bool) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = hour
    comps.minute = 0
    comps.second = 0
    guard var target = cal.date(from: comps) else {
        return Int(Date().timeIntervalSince1970) + 3600
    }
    if nextDay || target <= Date() {
        target = cal.date(byAdding: .day, value: 1, to: target) ?? target
    }
    return Int(target.timeIntervalSince1970)
}
