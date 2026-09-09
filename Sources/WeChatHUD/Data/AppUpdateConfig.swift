import Foundation

/// Device-level update preferences. Stored under the `update` settings key.
struct AppUpdateConfig: Codable, Equatable, Sendable {
    static let settingKey = "update"
    static let defaultRepository = "samwang0041-star/WeChatHUD"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    var autoCheckEnabled: Bool = true
    var autoInstallEnabled: Bool = false
    /// ISO-8601 timestamp of the last successful GitHub check.
    var lastCheckAt: String?
    var githubToken: String = ""
    var repository: String = AppUpdateConfig.defaultRepository
    /// Survives relaunch so a found update is not forgotten for 24 hours.
    var pendingOffer: AppUpdateOffer?

    var lastCheckDate: Date? {
        guard let lastCheckAt else { return nil }
        return ISO8601DateFormatter().date(from: lastCheckAt)
    }

    mutating func markChecked(at date: Date = Date()) {
        lastCheckAt = ISO8601DateFormatter().string(from: date)
    }
}

enum AppUpdatePolicy {
    /// Launch / idle checks wait a full interval unless the user asked to check now.
    static func shouldCheck(
        lastCheck: Date?,
        now: Date,
        interval: TimeInterval = AppUpdateConfig.checkInterval,
        hasPendingOffer: Bool = false
    ) -> Bool {
        if hasPendingOffer { return true }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static func normalizedRepository(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              repo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return "\(owner)/\(repo)"
    }
}
