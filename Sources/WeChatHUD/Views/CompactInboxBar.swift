import SwiftUI
import AppKit

/// Dynamic Island-style compact bar. The pill wraps the hardware notch
/// (or a fake notch on external displays); content lives in two wings
/// that extend past the notch edges:
///
///   [  status · summary · badges ]  ( notch )  [ buddy ]
///
/// On notched Macs the middle `notchWidth`-sized spacer aligns with
/// the hardware cutout so only the wings read as visible UI. On
/// external / non-notched displays the same layout leaves a visually
/// unified empty center, preserving the island metaphor.
struct CompactInboxBar: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @ObservedObject private var aiTracker = AIActivityTracker.shared

    @State private var idleSince: Date? = nil
    @State private var idleMinutes: Int = 0
    @State private var idleTimer: Timer? = nil

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                leftWing
                aiTick
                AutopilotIndicator()
            }
            .padding(.leading, 16)

            // Middle void — EXACTLY notch width. Spacer minLength
            // collapses to its minimum in a fixed-width HStack,
            // keeping the camera gap exactly aligned.
            Spacer(minLength: notchWidth)

            rightWing
                .padding(.trailing, 14)
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

    /// Red translucent glow behind the wings when any VIP escalation
    /// is at T2+. Confined to the wings (via the HStack padding)
    /// so it doesn't paint across the notch void.
    private var escalationGlow: some View {
        let worstTier = monitor.vipAlertTiers.values.max() ?? .none
        let active = worstTier >= .t2
        return ZStack {
            if active {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(worstTier >= .t3 ? 0.22 : 0.14))
                    .blendMode(.screen)
                    .modifier(PulsingOpacity(active: active))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Left wing

    @ViewBuilder
    private var leftWing: some View {
        let actionItems = monitor.inboxItems.filter { $0.actionRequired }
        let p0p1Items = actionItems.filter { $0.priority != .p2 }
        let hasUrgent = !p0p1Items.isEmpty

        if hasUrgent, let top = actionItems.first {
            urgentWing(top: top, extraCount: p0p1Items.count - 1)
        } else if !actionItems.isEmpty {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text("\(actionItems.count)条待处理")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        } else if !syncIsOK {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                Text(syncErrorText)
                    .font(.system(size: 11))
                    .foregroundColor(.yellow.opacity(0.85))
                    .lineLimit(1)
            }
        } else {
            // Idle — single green dot, tight against the notch edge.
            Circle()
                .fill(Color.green.opacity(0.7))
                .frame(width: 7, height: 7)
        }
    }

    private func urgentWing(top: InboxItem, extraCount: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(top.priority == .p0 ? Color.red : Color.yellow)
                .frame(width: 7, height: 7)

            // Context chip — who is asking, which chat. Without this
            // the compact bar just reads "啥时候拉群" with no idea
            // which chat or sender it came from. Cap chars so a long
            // name doesn't eat the summary budget.
            Text(contextLabel(top))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)

            Text(top.aiSummary ?? top.preview)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)

            if top.isOverdue {
                Text(overdueLabel(minutes: top.overdueMinutes))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(3)
            }

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    /// Short "who" label for the urgent wing. Group chats prefer the
    /// sender's name (who actually asked), falling back to the chat
    /// name; private chats use the chat (peer) name directly.
    /// Emoji-prefixed names (e.g. "💰个金互联网搞钱组💰") are stripped
    /// down to the inner text so the 6-char cap lands on useful
    /// content instead of decorative runes.
    private func contextLabel(_ item: InboxItem) -> String {
        let raw: String
        if item.isGroup, !item.senderName.isEmpty {
            raw = item.senderName
        } else {
            raw = item.chatName
        }
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0.isSymbol || $0.isPunctuation || !$0.isLetter && !$0.isNumber && $0.unicodeScalars.first.map { $0.value > 0x1F000 } == true }
        let cleaned = String(stripped).isEmpty ? raw : String(stripped)
        return cleaned.count > 6 ? String(cleaned.prefix(6)) + "…" : cleaned
    }

    /// Compact overdue badge text. Minutes → "超时Nm" up to 1h,
    /// hours → "超时Nh" up to a day, days → "超时Nd". The compact
    /// bar has limited width — never render three-digit minute
    /// counts like "超时143分" that blow out the summary budget.
    private func overdueLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Right wing

    private var rightWing: some View {
        PixelBuddyView(mood: buddyMood)
    }

    // MARK: - AI activity tick

    /// Tiny always-on indicator for background AI work. Living in the
    /// left wing next to the status keeps the AI signal inside the
    /// island language instead of popping a separate rectangular
    /// overlay that covered half the panel.
    ///
    ///   0 running  → invisible (takes zero space)
    ///   1 running  → small spinning indicator
    ///   2+ running → "AI·N" pill (N = count)
    ///
    /// Hover on the right-wing buddy still surfaces the full task
    /// breakdown — this is just the passive ambient signal.
    @ViewBuilder
    private var aiTick: some View {
        let count = aiTracker.activeTasks.count
        if count == 0 {
            EmptyView()
        } else if count == 1 {
            ProgressView()
                .scaleEffect(0.45)
                .frame(width: 10, height: 10)
                .tint(.white.opacity(0.7))
        } else {
            HStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.85))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.orange.opacity(0.18))
            )
        }
    }

    // MARK: - Sync state helpers

    private var syncIsOK: Bool {
        switch monitor.stats.syncStatus {
        case .ok, .idle, .syncing: return true
        default: return false
        }
    }

    private var syncErrorText: String {
        switch monitor.stats.syncStatus {
        case .stale:
            return "未同步"
        case .waitingForWeChat:
            return "微信未运行"
        case .accountSwitched:
            return "已切换账号 · 重启"
        case .error(let msg):
            return msg.localizedCaseInsensitiveContains("WeChat") ? "微信未运行" : "未同步"
        default:
            return ""
        }
    }

    private var buddyMood: BuddyMood {
        let actionItems = monitor.inboxItems.filter { $0.actionRequired }
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
                    hasUrgent: monitor.inboxItems.contains { $0.priority == .p0 },
                    hasPending: monitor.inboxItems.contains { $0.actionRequired },
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

// MARK: - Compact width helper (kept for HUDRootView compat)

/// Legacy helper — retained so existing call sites don't need touching.
/// Returns a width that matches the new `panelSize(for: .compact)`
/// logic in AppDelegate (notch + scaled wings). The specific values
/// here are overridden by AppDelegate; this is purely a fallback.
func compactBarWidth(inboxItems: [InboxItem], syncStatus: SyncStatus) -> CGFloat {
    let hasUrgent = inboxItems.contains { $0.priority != .p2 }
    let notchWidth: CGFloat = 200  // MBP-ish default
    let wingRight: CGFloat = 56
    let wingLeft: CGFloat
    if hasUrgent {
        wingLeft = 200
    } else if !inboxItems.isEmpty {
        wingLeft = 130
    } else {
        wingLeft = 56
    }
    return notchWidth + wingLeft + wingRight
}

/// Slow auto-reverse pulsing opacity. Used for the escalation glow —
/// 1.2 s period is fast enough to draw the eye but slow enough not to
/// feel like a disco.
private struct PulsingOpacity: ViewModifier {
    let active: Bool
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (lit ? 1.0 : 0.45) : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }
}
