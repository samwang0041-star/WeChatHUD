import Foundation
import UserNotifications

typealias ProactiveAlertNotificationSender = (
    _ title: String,
    _ body: String,
    _ identifier: String,
    _ completion: @escaping @Sendable (Error?) -> Void
) -> Void

/// Rule-based proactive alert engine. Evaluates conditions after each scan
/// and pushes macOS notifications for critical signals.
///
/// Rate limited to maxAlertsPerHour to prevent notification fatigue.
@MainActor
final class ProactiveAlertEngine {
    private let store: HUDStore
    private let now: () -> Date
    private let sendNotification: ProactiveAlertNotificationSender
    private var alertHistory: [Date] = []
    private let maxAlertsPerHour = 5
    /// Per-identifier dedup — prevents the same alert (e.g. commitment
    /// deadline, P0 debt) from firing on every 10s scan and burning
    /// through the hourly budget. Each identifier fires at most once
    /// per hour.
    /// The timestamp is the successful delivery submission time, so an
    /// identifier becomes eligible again after one hour.
    private var pushedIdentifiers: [String: Date] = [:]
    /// Notification submissions are asynchronous. Keep an identifier
    /// reserved until its completion arrives so two scans cannot enqueue
    /// the same identifier concurrently.
    private var inFlightIdentifiers: Set<String> = []

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

    init(store: HUDStore) {
        self.store = store
        self.now = Date.init
        self.sendNotification = Self.systemNotificationSender
        requestNotificationPermission()
    }

    /// Injectable initializer for deterministic rule tests. The production
    /// initializer above keeps the existing notification-permission behavior.
    init(
        store: HUDStore,
        now: @escaping () -> Date,
        sendNotification: @escaping ProactiveAlertNotificationSender
    ) {
        self.store = store
        self.now = now
        self.sendNotification = sendNotification
    }

    /// Evaluate all rules against current state. Called after each scan.
    /// `activeConversations` are chats the user replied inside within the
    /// last `ScanEngine.activeConversationWindow` seconds — a live
    /// exchange. Their items keep flowing into the inbox, but OS-level
    /// interruptions (VIP escalation, burst) would be noise: the user is
    /// literally watching that chat. Replied items are likewise never
    /// alertable — you already answered them.
    func evaluate(
        unreadItems: [UnreadItem],
        replyDebtItems: [ReplyDebtItem],
        commitments: [Commitment],
        recentNotifications: [HUDNotification],
        activeConversations: Set<String> = []
    ) {
        let evaluationNow = now()
        pruneExpiredState(at: evaluationNow)
        let alertable = unreadItems.filter {
            !$0.replied && !activeConversations.contains($0.chatUsername)
        }

        // Rule 1: VIP message overdue — with escalation tiers.
        var newTiers: [String: VIPAlertTier] = [:]
        for item in alertable where item.isVIP {
            let overdueMinutes = Int(evaluationNow.timeIntervalSince(item.timestamp) / 60)
            let tier = VIPAlertTier.compute(overdueMinutes: overdueMinutes)
            guard tier != .none else { continue }
            newTiers[item.chatUsername] = tier

            let previousTier = lastPushedTier[item.chatUsername] ?? .none
            if tier > previousTier {
                pushEscalationAlert(item: item, tier: tier)
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

        // Rule 2: Pending deadlines and overdue commitments. Include elapsed
        // deadlines even before the asynchronous tracker persists .overdue.
        // Distinct phases let the deadline alert follow a recent heads-up;
        // the normal in-flight dedup and hourly budget still prevent flooding.
        evaluateCommitmentDeadlines(commitments: commitments, at: evaluationNow)

        // Rule 3: Burst messages (3+ unanswered from the same person)
        var senderCounts: [String: Int] = [:]
        for item in alertable {
            senderCounts[item.senderName, default: 0] += 1
        }
        for (sender, count) in senderCounts where count >= 3 {
            pushAlert(
                title: "连续消息",
                body: "\(sender) 连续发了 \(count) 条消息",
                identifier: "burst-\(sender)"
            )
        }

        // Rule 4: High-priority reply debt. The scorer already clears
        // debt once you reply; `activeConversations` additionally covers
        // the "you're mid-exchange right now" case the scorer can't see.
        if let p0 = replyDebtItems.first, p0.priority == .p0,
           !activeConversations.contains(p0.chatUsername) {
            let minutes = Int(evaluationNow.timeIntervalSince(p0.timestamp) / 60)
            if minutes > 30 {
                pushAlert(
                    title: "紧急待回复",
                    body: "\(p0.chatName): \(p0.preview)",
                    identifier: "p0-debt-\(p0.chatUsername)"
                )
            }
        }
    }

    /// Evaluate only durable commitment deadlines. This is intentionally
    /// separate from the full scan evaluation so the safety timer can keep
    /// reminders alive while WeChat is closed or its database is unavailable.
    /// The caller should load commitments directly from HUDStore, rather than
    /// using a potentially stale published UI snapshot.
    func evaluateCommitmentDeadlines(commitments: [Commitment], at date: Date? = nil) {
        let evaluationNow = date ?? now()
        pruneExpiredState(at: evaluationNow)
        for c in commitments where c.status == .pending || c.status == .overdue {
            guard let deadline = c.deadlineAt else { continue }
            let remaining = deadline.timeIntervalSince(evaluationNow)
            if remaining <= 0 {
                pushAlert(
                    title: "承诺已到期",
                    body: "\(c.content) → \(c.commitTo)",
                    identifier: "commitment-overdue-\(c.msgUID)"
                )
            } else if remaining < 3600 {
                pushAlert(
                    title: "承诺即将到期",
                    body: "\(c.content) → \(c.commitTo)",
                    identifier: "commitment-\(c.msgUID)"
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
            lastPushedTier[item.chatUsername] = max(lastPushedTier[item.chatUsername] ?? .none, tier)
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
        _ = pushAlert(
            title: title,
            body: body,
            identifier: "vip-\(item.chatUsername)-\(tier.rawValue)",
            onSuccess: { [weak self] in
                guard let self else { return }
                // If the item was resolved while the OS request was in
                // flight, leave the cleared state alone. A later re-entry
                // can start a fresh alert cycle.
                guard let currentTier = self.vipAlertTiers[item.chatUsername],
                      currentTier >= tier else { return }
                guard tier > (self.lastPushedTier[item.chatUsername] ?? .none) else { return }
                self.lastPushedTier[item.chatUsername] = tier
            }
        )
    }

    /// Push a macOS notification when a VIP contact speaks inside a
    /// whitelisted group chat (not their private thread). Coalesces
    /// multiple messages in the same scan batch into one notification
    /// per (vipUsername, groupUsername) pair so the user sees
    /// "VIP 张三 在群里说话了 · [产品群] 看看这个" once, not three times.
    ///
    /// `messageCount` > 1 appends a "发了 N 条" suffix to the title.
    /// Identifier is scoped to (vip, group) and reused across tiers,
    /// which also lets the OS suppress duplicate delivery.
    func pushCrossGroupVIPAlert(
        vipName: String,
        vipUsername: String,
        groupName: String,
        groupUsername: String,
        preview: String,
        messageCount: Int
    ) {
        let title: String
        if messageCount > 1 {
            title = "VIP \(vipName) 在群里发了 \(messageCount) 条消息"
        } else {
            title = "VIP \(vipName) 在群里说话了"
        }
        let trimmedPreview = String(preview.prefix(80))
        let body = "[\(groupName)] \(trimmedPreview)"
        pushAlert(
            title: title,
            body: body,
            identifier: "cross-vip-\(vipUsername)-\(groupUsername)"
        )
    }

    @discardableResult
    private func pushAlert(
        title: String,
        body: String,
        identifier: String,
        onSuccess: (() -> Void)? = nil
    ) -> Bool {
        let submissionNow = now()
        pruneExpiredState(at: submissionNow)
        guard alertHistory.count + inFlightIdentifiers.count < maxAlertsPerHour else { return false }
        guard pushedIdentifiers[identifier] == nil else { return false }
        guard inFlightIdentifiers.insert(identifier).inserted else { return false }

        sendNotification(title, body, identifier) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.inFlightIdentifiers.remove(identifier) != nil else { return }
                guard error == nil else {
                    // Failed submissions do not consume the hourly budget or
                    // identifier dedup window. The next evaluation can retry.
                    if let error {
                        print("[WCHUD] Alert push failed: \(error)")
                    }
                    return
                }

                let deliveredAt = self.now()
                self.pruneExpiredState(at: deliveredAt)
                self.alertHistory.append(deliveredAt)
                self.pushedIdentifiers[identifier] = deliveredAt
                onSuccess?()
            }
        }
        return true
    }

    private func pruneExpiredState(at date: Date) {
        let cutoff = date.addingTimeInterval(-3600)
        alertHistory.removeAll { $0 <= cutoff }
        pushedIdentifiers = pushedIdentifiers.filter { $0.value > cutoff }
    }

    private static let systemNotificationSender: ProactiveAlertNotificationSender = {
        title, body, identifier, completion in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[WCHUD] Notification permission error: \(error)")
            }
        }
    }
}
