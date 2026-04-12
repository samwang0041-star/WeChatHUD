import Foundation
import UserNotifications

/// Rule-based proactive alert engine. Evaluates conditions after each scan
/// and pushes macOS notifications for critical signals.
///
/// Rate limited to maxAlertsPerHour to prevent notification fatigue.
@MainActor
final class ProactiveAlertEngine {
    private let store: HUDStore
    private var alertHistory: [Date] = []
    private let maxAlertsPerHour = 5

    init(store: HUDStore) {
        self.store = store
        requestNotificationPermission()
    }

    /// Evaluate all rules against current state. Called after each scan.
    func evaluate(
        unreadItems: [UnreadItem],
        replyDebtItems: [ReplyDebtItem],
        commitments: [Commitment],
        recentNotifications: [HUDNotification]
    ) {
        // Prune old alert history
        let oneHourAgo = Date(timeIntervalSinceNow: -3600)
        alertHistory.removeAll { $0 < oneHourAgo }

        // Rule 1: VIP message overdue
        for item in unreadItems where item.isVIP && item.status == .overdue {
            pushAlert(
                title: "VIP 消息超时",
                body: "\(item.senderName) 的消息已超时未回复",
                identifier: "vip-overdue-\(item.chatUsername)"
            )
        }

        // Rule 2: Commitment deadline approaching (< 1 hour)
        for c in commitments where c.status == .pending {
            if let deadline = c.deadlineAt {
                let remaining = deadline.timeIntervalSince(Date())
                if remaining > 0 && remaining < 3600 {
                    pushAlert(
                        title: "承诺即将到期",
                        body: "\(c.content) → \(c.commitTo)",
                        identifier: "commitment-\(c.msgUID)"
                    )
                }
            }
        }

        // Rule 3: Burst messages (3+ from same person in unread)
        var senderCounts: [String: Int] = [:]
        for item in unreadItems {
            senderCounts[item.senderName, default: 0] += 1
        }
        for (sender, count) in senderCounts where count >= 3 {
            pushAlert(
                title: "连续消息",
                body: "\(sender) 连续发了 \(count) 条消息",
                identifier: "burst-\(sender)"
            )
        }

        // Rule 4: High-priority reply debt
        if let p0 = replyDebtItems.first, p0.priority == .p0 {
            let minutes = Int(Date().timeIntervalSince(p0.timestamp) / 60)
            if minutes > 30 {
                pushAlert(
                    title: "紧急待回复",
                    body: "\(p0.chatName): \(p0.preview)",
                    identifier: "p0-debt-\(p0.chatUsername)"
                )
            }
        }
    }

    // MARK: - Private

    private func pushAlert(title: String, body: String, identifier: String) {
        guard alertHistory.count < maxAlertsPerHour else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[WCHUD] Alert push failed: \(error)")
            }
        }
        alertHistory.append(Date())
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[WCHUD] Notification permission error: \(error)")
            }
        }
    }
}
