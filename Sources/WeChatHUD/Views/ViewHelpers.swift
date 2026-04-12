import SwiftUI

// MARK: - Shared view utility functions

/// Human-readable relative time string for a given date.
/// Used across multiple rows and views in the HUD.
func relativeTime(_ date: Date) -> String {
    let diff = Int(Date().timeIntervalSince(date))
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(diff / 60)分前" }
    if diff < 86400 { return "\(diff / 3600)时前" }
    return "\(diff / 86400)天前"
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
