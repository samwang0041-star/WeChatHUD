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
    static let wingWidth: CGFloat = 56
    static let markSize: CGFloat = 9
    static let quietMarkSize: CGFloat = 7
    static let badgeSize: CGFloat = 12
}

struct CompactInboxBar: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var islandPresentation: IslandPresentation
    @ObservedObject private var aiTracker = AIActivityTracker.shared

    @State private var idleSince: Date? = nil
    @State private var idleMinutes: Int = 0
    @State private var idleTimer: Timer? = nil
    @State private var heldAIActive = false
    @State private var aiHoldTask: Task<Void, Never>? = nil

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
            .padding(.trailing, 6)
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
            .padding(.leading, 6)
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
            heldAIActive = aiTracker.isActive
            startIdleTimer()
        }
        .onChange(of: aiTracker.isActive) { _, active in
            holdAIActivity(active)
        }
        .onDisappear {
            idleTimer?.invalidate()
            idleTimer = nil
            aiHoldTask?.cancel()
        }
    }

    private var island: CompactIslandSnapshot {
        let live = islandPresentation.live
        return CompactIslandPolicy.snapshot(CompactIslandInput(
            sync: live.sync,
            actions: live.actions,
            noticeCount: live.noticeCount,
            aiActive: heldAIActive,
            autopilotActive: live.autopilotActive,
            idleMinutes: idleMinutes,
            worstVIPTier: live.vipGlowTier
        ))
    }

    private var accessibilityStatus: String { island.spoken }

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

    /// Static rim only. A repeating pulse made the whole island look like it was blinking.
    private var escalationGlow: some View {
        let glow = island.glow
        return ZStack {
            if glow != .none {
                Capsule(style: .continuous)
                    .strokeBorder(Color.red.opacity(glow == .critical ? 0.45 : 0.28), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Left wing

    private var leftWing: some View {
        let snap = island
        return HStack(spacing: 5) {
            leftMark(snap.mark)
            if let badge = snap.badge {
                Text(badge)
                    .font(.system(size: CompactInboxMetrics.badgeSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func leftMark(_ mark: CompactIslandMark) -> some View {
        switch mark {
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: CompactInboxMetrics.markSize, weight: .semibold))
                .foregroundStyle(Color.yellow)
        case .dot(let kind):
            Circle()
                .fill(dotColor(kind))
                .frame(width: dotSize(kind), height: dotSize(kind))
        }
    }

    private func dotSize(_ kind: CompactIslandMark.Kind) -> CGFloat {
        kind == .quiet ? CompactInboxMetrics.quietMarkSize : CompactInboxMetrics.markSize
    }

    private func dotColor(_ kind: CompactIslandMark.Kind) -> Color {
        switch kind {
        case .urgentP0: return Color.red.opacity(0.92)
        case .urgentP1: return Color.yellow.opacity(0.88)
        case .working: return CompanionPalette.islandMint
        case .waiting: return Color.white.opacity(0.62)
        case .notices: return Color.blue.opacity(0.72)
        case .quiet: return CompanionPalette.islandMint.opacity(0.4)
        }
    }

    // MARK: - Right wing

    private var rightWing: some View {
        PixelBuddyView(mood: island.buddy)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            DispatchQueue.main.async {
                let live = islandPresentation.live
                let snap = CompactIslandPolicy.snapshot(CompactIslandInput(
                    sync: live.sync,
                    actions: live.actions,
                    noticeCount: live.noticeCount,
                    aiActive: heldAIActive,
                    autopilotActive: live.autopilotActive,
                    idleMinutes: 0,
                    worstVIPTier: live.vipGlowTier
                ))
                if case .quiet = snap.phase {
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

    /// Classifier hops are short. Hold the flag so the left mark does not
    /// jump between working and waiting on every task.
    private func holdAIActivity(_ live: Bool) {
        aiHoldTask?.cancel()
        if live {
            aiHoldTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, aiTracker.isActive else { return }
                heldAIActive = true
            }
        } else {
            aiHoldTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, !aiTracker.isActive else { return }
                heldAIActive = false
            }
        }
    }
}
