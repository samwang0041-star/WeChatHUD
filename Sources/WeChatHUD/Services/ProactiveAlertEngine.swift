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
    /// Quiet period for an unresolved commitment that is already past its
    /// deadline. The condition stays true until the user resolves it, so the
    /// default one-hour window re-fired the same "承诺已到期" all night and
    /// consumed the shared budget the P0/VIP rules need for new signals.
    static let overdueCommitmentCooldown: TimeInterval = 24 * 3600

    /// Per-identifier dedup — prevents the same alert (e.g. commitment
    /// deadline, P0 debt) from firing on every 10s scan and burning
    /// through the hourly budget. Each identifier carries its own window
    /// (`overdueCommitmentCooldown` for already-overdue commitments, one hour
    /// for everything else).
    /// The timestamp is the successful delivery submission time, so an
    /// identifier becomes eligible again once its window elapses.
    private struct DedupEntry {
        let pushedAt: Date
        let window: TimeInterval
    }
    private var pushedIdentifiers: [String: DedupEntry] = [:]
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
            let waitingMinutes = Int(evaluationNow.timeIntervalSince(item.timestamp) / 60)
            let tier = VIPAlertTier.compute(waitingMinutes: waitingMinutes)
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

        // Rule 3: Burst messages (3+ unanswered from the same person).
        //
        // Bucket by `senderUsername`, not by `senderName`: a display name is
        // not an identity. Two different people who both show up as "小王"
        // (a common nickname, or a stale contact note) would otherwise have
        // their unrelated messages counted into one bucket, and both would
        // share the single dedup slot `burst-小王` — so one conversation's
        // alert would suppress the other's, while the merged count could
        // cross the 3-message threshold with no single person having sent 3.
        // Rows without a username (system/unread summaries) fall back to the
        // display name so they still bucket somewhere.
        //
        // Counting what each row *stands for*, not the rows themselves, is what
        // makes this reachable at all: a private chat folds its unanswered tail
        // into a single row, so the old `+= 1` meant the rule could only ever
        // fire for group members — a colleague firing off five DMs produced one.
        var senderCounts: [String: Int] = [:]
        var senderFloors: [String: Bool] = [:]
        var displayNames: [String: String] = [:]
        for item in alertable {
            let key = Self.burstBucketKey(senderUsername: item.senderUsername, senderName: item.senderName)
            senderCounts[key, default: 0] += item.inboundMessageCount
            senderFloors[key, default: false] = (senderFloors[key] ?? false) || item.unansweredCountIsFloor
            // First display name wins for the body text; the key already
            // carries the identity, so only readability depends on this.
            if displayNames[key] == nil { displayNames[key] = item.senderName }
        }
        for (key, count) in senderCounts where count >= 3 {
            let displayName = displayNames[key] ?? key
            // 「连续」 promised back-to-back messages. This bucket is every
            // unanswered alertable item from that sender, across chats and with
            // no adjacency check, so three replies-old messages qualify too.
            // What is actually true — and what the alert is for — is the count.
            let unit = (senderFloors[key] ?? false) ? "条以上" : "条"
            pushAlert(
                title: "多条未回",
                body: "\(displayName) 有 \(count) \(unit)消息还没回",
                identifier: "burst-\(key)"
            )
        }

        // Rule 4: High-priority reply debt. The scorer already clears
        // debt once you reply; `activeConversations` additionally covers
        // the "you're mid-exchange right now" case the scorer can't see.
        //
        // `replyDebtItems` is sorted by priority, so this used to read the
        // first element and ask whether it was P0 — which meant the whole rule
        // went silent whenever that one chat happened to be one you were
        // actively typing in, even with other P0 debt sitting right behind it.
        // Pick the first P0 that is *not* an active conversation instead, and
        // still push at most one per evaluation so the budget-free path cannot
        // fan out.
        if let p0 = replyDebtItems.first(where: {
            $0.priority == .p0 && !activeConversations.contains($0.chatUsername)
        }) {
            let minutes = Int(evaluationNow.timeIntervalSince(p0.timestamp) / 60)
            if minutes > 30 {
                pushAlert(
                    title: "紧急待回复",
                    body: "\(p0.chatName): \(p0.preview)",
                    identifier: "p0-debt-\(p0.chatUsername)",
                    ignoresBudget: true
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
        // The mute list is the one promise every alert path has to keep:
        // 「不想再看到谁的消息 — 选谁，就哪个对话都不再提醒——包括他所在的群」
        // (`AdmissionSettingsView.swift:626`). The scan path honours it through
        // `AdmissionPolicy.isMuted`; this path consulted none of it, so a muted
        // person's deadline went on waking the notification centre.
        let globallyMuted = store.loadGlobalIgnoredSenders()
        let chatMutes = store.loadIgnoredSenderMap()

        for c in commitments where c.status == .pending || c.status == .overdue {
            guard let deadline = c.deadlineAt else { continue }
            guard !isMutedForCommitment(c, globallyMuted: globallyMuted, chatMutes: chatMutes) else {
                continue
            }
            let remaining = deadline.timeIntervalSince(evaluationNow)
            if remaining <= 0 {
                pushAlert(
                    title: "承诺已到期",
                    body: "\(c.content) → \(c.commitTo)",
                    identifier: "commitment-overdue-\(c.msgUID)",
                    cooldown: Self.overdueCommitmentCooldown
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

    /// A commitment records its counterparty only as a display name
    /// (`Commitment.commitTo`), so the name identifier is what can match — and
    /// the chat-scoped mute is checked against the conversation the promise was
    /// made in, which is where 「包括他所在的群」 points.
    private func isMutedForCommitment(
        _ commitment: Commitment,
        globallyMuted: Set<String>,
        chatMutes: [String: Set<String>]
    ) -> Bool {
        let identifier = HUDStore.senderIdentifier(
            senderUsername: "",
            senderName: commitment.commitTo
        )
        if globallyMuted.contains(identifier) { return true }
        return chatMutes[commitment.chatUsername]?.contains(identifier) == true
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
            // Not 「已超时未回复」: 超时 is a different, user-configurable
            // notion (关注谁 → 多久算超时, per contact). A VIP whose own window
            // is 2 小时 would see a row that is not 超时 in the inbox while an
            // OS banner called it 超时. This tier only ever claims the wait.
            title = "VIP 等你 \(tier.agingLabel)了"
            body = "\(item.senderName) 的消息还没回"
        case .t2:
            // Visual-only. Skip the OS notification — the pill pulse
            // and menu-bar badge are enough. A silent notification
            // still bumps the system Notification Center list which
            // we don't want at this tier.
            lastPushedTier[item.chatUsername] = max(lastPushedTier[item.chatUsername] ?? .none, tier)
            return
        case .t3:
            title = "VIP 等你 \(tier.agingLabel)了"
            body = "\(item.senderName): \(item.preview)"
        case .t4:
            // The tier fires at exactly 240 minutes, so 超过 was off by the
            // boundary; keep the same shape as the 2 小时 tier.
            title = "VIP 等你 4 小时了"
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

    /// Identity key for the burst rule (rule 3).
    ///
    /// The username is the real identity; the display name is only a label
    /// that two different people can share ("小王"). Bucketing on the label
    /// merges strangers' messages and makes them share one dedup slot, so the
    /// username wins whenever the row has one. Rows without a username
    /// (system/unread summaries) fall back to the display name.
    nonisolated static func burstBucketKey(senderUsername: String, senderName: String) -> String {
        senderUsername.isEmpty ? senderName : senderUsername
    }

    @discardableResult
    private func pushAlert(
        title: String,
        body: String,
        identifier: String,
        cooldown: TimeInterval = 3600,
        // P0 bypasses the hourly budget (but never the identifier dedup): a
        // full hour of low-priority alerts must not swallow a new P0.
        ignoresBudget: Bool = false,
        onSuccess: (() -> Void)? = nil
    ) -> Bool {
        let submissionNow = now()
        pruneExpiredState(at: submissionNow)
        if !ignoresBudget {
            guard alertHistory.count + inFlightIdentifiers.count < maxAlertsPerHour else { return false }
        }
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
                self.pushedIdentifiers[identifier] = DedupEntry(pushedAt: deliveredAt, window: cooldown)
                onSuccess?()
            }
        }
        return true
    }

    private func pruneExpiredState(at date: Date) {
        let cutoff = date.addingTimeInterval(-3600)
        alertHistory.removeAll { $0 <= cutoff }
        pushedIdentifiers = pushedIdentifiers.filter { _, entry in
            entry.pushedAt.addingTimeInterval(entry.window) > date
        }
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
