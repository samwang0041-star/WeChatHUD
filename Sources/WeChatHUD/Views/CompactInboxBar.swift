import SwiftUI
import AppKit

/// Dynamic Island-style compact bar. The pill wraps the hardware notch
/// (or a fake notch on external displays); compact content lives only
/// in two small, equal-width wings outside the notch:
///
///   [ status ]  ( notch )  [ buddy ]
///
/// The compact state is intentionally ambient: never render sender
/// names or message previews here, because screenshots can show pixels
/// that the user cannot see behind the physical notch. Message content
/// belongs in the hover-expanded inbox.
enum CompactInboxMetrics {
    static let wingWidth: CGFloat = 44
}

struct CompactInboxBar: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    @ObservedObject private var aiTracker = AIActivityTracker.shared

    @State private var idleSince: Date? = nil
    @State private var idleMinutes: Int = 0
    @State private var idleTimer: Timer? = nil

    var body: some View {
        HStack(spacing: 0) {
            Button { panelState.goExtended() } label: {
                leftWing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开聊天收件箱")
            .accessibilityValue(accessibilityStatus)
            .help(accessibilityStatus + " · 点击打开收件箱")
            .padding(.trailing, 8)
            .frame(width: CompactInboxMetrics.wingWidth, height: notchHeight, alignment: .trailing)

            // Middle void — EXACTLY notch width. Because the two
            // wings are equal width, this spacer's center stays
            // aligned with the panel center, which is locked to the
            // physical notch center by FloatingPanel.
            Rectangle()
                .fill(Color.clear)
                .frame(width: notchWidth)

            Button {
                panelState.pendingSettingsTab = "today"
                panelState.showDetail()
            } label: {
                rightWing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开今天")
            .help("打开今天")
            .padding(.leading, 8)
            .frame(width: CompactInboxMetrics.wingWidth, height: notchHeight, alignment: .leading)
        }
        // Horizontal: natural content width (drives panel width via
        // the PreferenceKey feedback loop below).
        //
        // Vertical: EXPLICIT `notchHeight` so the pill actually has
        // the island's full vertical extent. Using `.fixedSize()`
        // on the vertical axis shrank the bar to the tallest child
        // (~18pt buddy), producing the cramped "text jammed to the
        // top edge" look. A hard height centers content vertically
        // (HStack default alignment) with breathing room on top
        // and bottom.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: notchHeight)
        .background(escalationGlow)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self) { size in
            panelState.reportExtendedSize(size)
        }
        .onAppear {
            idleSince = Date()
            startIdleTimer()
        }
        .onDisappear {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    private var accessibilityStatus: String {
        let count = monitor.inboxItems.filter(\.surfacesInCompact).count
        let sync: String
        switch monitor.stats.syncStatus {
        case .ok: sync = "微信连接正常"
        case .idle: sync = "等待同步"
        case .syncing: sync = "正在同步"
        case .waitingForWeChat: sync = "等待微信运行"
        case .accountSwitched: sync = "当前数据目录已失效"
        case .stale: sync = "同步已延迟"
        case .error: sync = "同步失败"
        }
        return CompanionProductCopy.compactStatus(
            count: count,
            sync: sync + (aiTracker.isActive ? "，AI 正在分析" : "")
        )
    }

    // MARK: - Notch width lookup

    /// Query the live panel for its current notch geometry. Falls
    /// back to the standard MBP-ish default if the panel isn't
    /// reachable (e.g. SwiftUI preview).
    private var notchWidth: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchWidth
        }
        return 200
    }

    private var notchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }

    /// Subtle VIP escalation affordance. It is intentionally tied to a
    /// visible urgent action item, not just `vipAlertTiers`, because the
    /// compact bar's idle dot otherwise says "normal" while the whole pill
    /// turns red.
    private var escalationGlow: some View {
        let worstTier = monitor.inboxItems.compactMap { item -> VIPAlertTier? in
            guard item.surfacesInCompact,
                  item.participatesInActionQueue,
                  item.isVIP,
                  item.priority == .p0 || item.isOverdue else { return nil }
            return monitor.vipAlertTiers[item.chatUsername]
        }.max() ?? .none
        let active = worstTier >= .t2
        return ZStack {
            if active {
                Capsule(style: .continuous)
                    .strokeBorder(Color.red.opacity(worstTier >= .t3 ? 0.55 : 0.35), lineWidth: 1)
                    .modifier(PulsingOpacity(active: active))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Left wing

    private var leftWing: some View {
        let status = compactStatus
        let aiCount = aiTracker.activeTasks.count
        return HStack(spacing: 4) {
            if status.isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.yellow)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .companionAnimation(CompanionMotion.ease(0.3), value: status.color)
            }

            if let badge = status.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if aiCount > 0 {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.9))
            }
        }
    }

    private struct CompactStatus {
        let color: Color
        let badge: String?
        let isError: Bool
    }

    private var compactStatus: CompactStatus {
        let surfacedItems = monitor.inboxItems.filter { $0.surfacesInCompact }
        let actionItems = surfacedItems.filter { $0.participatesInActionQueue }
        let fyiItems = surfacedItems.filter { !$0.participatesInActionQueue }
        let p0p1Items = actionItems.filter { $0.priority != .p2 }
        let hasUrgent = !p0p1Items.isEmpty

        let pendingCount = surfacedItems.count
        if hasUrgent {
            let topPriority = p0p1Items.sorted(by: compactPrioritySort).first?.priority ?? .p1
            return CompactStatus(
                color: topPriority == .p0 ? .red : .yellow,
                badge: compactCountBadge(pendingCount),
                isError: false
            )
        }
        if !actionItems.isEmpty {
            return CompactStatus(
                color: .white.opacity(0.42),
                badge: compactCountBadge(pendingCount),
                isError: false
            )
        }
        if !fyiItems.isEmpty {
            return CompactStatus(
                color: .blue.opacity(0.78),
                badge: compactCountBadge(pendingCount),
                isError: false
            )
        }
        if !syncIsOK {
            return CompactStatus(color: .yellow, badge: nil, isError: true)
        }
        return CompactStatus(color: .green.opacity(0.72), badge: nil, isError: false)
    }

    private func compactCountBadge(_ count: Int) -> String? {
        guard count > 1 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    // MARK: - Right wing

    private var rightWing: some View {
        PixelBuddyView(mood: buddyMood)
    }

    // MARK: - Sync state helpers

    private var syncIsOK: Bool {
        switch monitor.stats.syncStatus {
        case .ok, .idle, .syncing: return true
        default: return false
        }
    }

    private func compactPrioritySort(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        if lhs.isVIP != rhs.isVIP {
            return lhs.isVIP
        }
        return lhs.timestamp > rhs.timestamp
    }

    private var buddyMood: BuddyMood {
        let surfacedItems = monitor.inboxItems.filter { $0.surfacesInCompact }
        let actionItems = surfacedItems.filter { $0.participatesInActionQueue }
        let hasUrgent = actionItems.contains { $0.priority == .p0 }
        let hasPending = !actionItems.isEmpty
        let base = deriveCompactMood(
            syncStatus: monitor.stats.syncStatus,
            hasUrgent: hasUrgent,
            hasPending: hasPending,
            idleMinutes: idleMinutes
        )
        // Autopilot is a persistent background signal that shouldn't
        // mask urgent/error states (which demand immediate attention),
        // but should win over idle/pending/sleepy (quiescent moods).
        if monitor.autopilotActive {
            switch base {
            case .idle, .pending, .sleepy, .browsing, .celebrating:
                return .autopiloting
            case .scanning, .urgent, .error, .analyzing, .autopiloting:
                return base
            }
        }
        return base
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            DispatchQueue.main.async {
                let baseMood = deriveCompactMood(
                    syncStatus: monitor.stats.syncStatus,
                    hasUrgent: monitor.inboxItems.contains { $0.surfacesInCompact && $0.participatesInActionQueue && $0.priority == .p0 },
                    hasPending: monitor.inboxItems.contains { $0.surfacesInCompact && $0.participatesInActionQueue },
                    idleMinutes: 0
                )
                if baseMood == .idle {
                    if let since = idleSince {
                        idleMinutes = Int(Date().timeIntervalSince(since) / 60)
                    }
                } else {
                    idleSince = Date()
                    idleMinutes = 0
                }
            }
        }
    }
}

/// Slow auto-reverse pulsing opacity. Used for the escalation glow —
/// 1.2 s period is fast enough to draw the eye but slow enough not to
/// feel like a disco.
private struct PulsingOpacity: ViewModifier {
    let active: Bool
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .opacity(active && !CompanionMotion.reduceMotion ? (lit ? 1.0 : 0.45) : 1.0)
            .onAppear {
                guard active else { return }
                withMotion(CompanionMotion.ease(1.2).map { $0.repeatForever(autoreverses: true) }) {
                    lit = true
                }
            }
    }
}
