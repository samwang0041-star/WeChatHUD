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

    /// Current escalation tier for each VIP chat that has something
    /// outstanding. Keyed by chatUsername. Cleared when the chat is
    /// no longer overdue (user replied / dismissed / snoozed).
    ///
    /// UI consumers (menu bar badge, compact-pill pulse, top banner)
    /// read this to decide what to draw. Updated on every `evaluate`.
    private(set) var vipAlertTiers: [String: VIPAlertTier] = [:]

    /// Tracks the highest tier we've already *pushed a system
    /// notification for* per VIP chat. Prevents re-alerting at the
    /// same tier on every 10s scan; only advances (t1→t2→…) fire new
    /// notifications.
    private var lastPushedTier: [String: VIPAlertTier] = [:]

    /// Fires whenever `vipAlertTiers` changes. ChatMonitor wires this
    /// to publish via its own `@Published` so SwiftUI views can
    /// observe. Callback form avoids making the engine an
    /// `ObservableObject` and keeps nested-observation complexity out
    /// of the view tree.
    var onTiersChanged: (([String: VIPAlertTier]) -> Void)?

    /// Fires once per tier-advance with (chatName, tier) so UI can
    /// show a transient banner (e.g. at T3: "张三已等你 2 小时"). The
    /// engine's internal cache ensures this is NOT called repeatedly
    /// for the same tier.
    var onTierAdvanced: ((_ chatName: String, _ tier: VIPAlertTier) -> Void)?

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

        // Rule 1: VIP message overdue — with escalation tiers.
        var newTiers: [String: VIPAlertTier] = [:]
        for item in unreadItems where item.isVIP {
            let overdueMinutes = Int(Date().timeIntervalSince(item.timestamp) / 60)
            let tier = VIPAlertTier.compute(overdueMinutes: overdueMinutes)
            guard tier != .none else { continue }
            newTiers[item.chatUsername] = tier

            let previousTier = lastPushedTier[item.chatUsername] ?? .none
            if tier > previousTier {
                lastPushedTier[item.chatUsername] = tier
                pushEscalationAlert(item: item, tier: tier)
                onTierAdvanced?(item.senderName, tier)
            }
        }

        // Clean escalation state for chats no longer in the VIP overdue
        // set — user replied / dismissed / snoozed, so next time this
        // chat enters overdue we start fresh at T1 instead of silently
        // skipping straight to the last-pushed tier.
        let resolved = Set(lastPushedTier.keys).subtracting(newTiers.keys)
        for user in resolved { lastPushedTier.removeValue(forKey: user) }

        if newTiers != vipAlertTiers {
            vipAlertTiers = newTiers
            onTiersChanged?(newTiers)
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

    /// Push a system notification for a VIP overdue item at the given
    /// tier. T2 is visual-only (no audio / OS banner) — it relies on
    /// the menu-bar badge + compact-pill pulse driven by
    /// `vipAlertTiers`. The others produce a real OS notification
    /// with escalating language.
    private func pushEscalationAlert(item: UnreadItem, tier: VIPAlertTier) {
        let (title, body): (String, String)
        switch tier {
        case .t1:
            title = "VIP 消息超时"
            body = "\(item.senderName) 的消息已超时未回复"
        case .t2:
            // Visual-only. Skip the OS notification — the pill pulse
            // and menu-bar badge are enough. A silent notification
            // still bumps the system Notification Center list which
            // we don't want at this tier.
            return
        case .t3:
            title = "VIP 等你 2 小时了"
            body = "\(item.senderName): \(item.preview)"
        case .t4:
            title = "VIP 等你超过 4 小时"
            body = "\(item.senderName) 的消息一直没回 — 要不要处理一下？"
        case .none:
            return
        }
        pushAlert(
            title: title,
            body: body,
            identifier: "vip-\(item.chatUsername)-\(tier.rawValue)"
        )
    }

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
