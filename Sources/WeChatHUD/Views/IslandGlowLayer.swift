import SwiftUI
import AppKit

/// Outer-silhouette chrome for the island: hairline, severity halo, and an
/// orbiting sweep while AI is working.
///
/// Drawn on the real `IslandShape` — notch cutout included — so the halo and
/// the sweep trace the hanging pill and climb the notch's inner walls instead
/// of spanning the camera cutout as a plain capsule. Lives in its own view so
/// a 30 Hz sweep cannot rebuild HUDRootView's routing tree.
struct IslandGlowLayer: View {
    /// Real hardware-notch width. Drawn into the glow silhouette so the halo
    /// and the sweep hug the hanging pill and climb the notch's inner walls
    /// instead of spanning the full cutout as a plain capsule.
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// The compact bar's debounced AI state, passed in rather than read from
    /// `AIActivityTracker` directly so the glow layer's snapshot races the
    /// wings' — one island, one story. The tracker flips per task; the bar
    /// holds the last true value briefly so a scan cannot blink the sweep.
    let heldAIActive: Bool

    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var islandPresentation: IslandPresentation

    var body: some View {
        let snap = CompactIslandPolicy.snapshot(CompactIslandInput(
            sync: islandPresentation.live.sync,
            actions: islandPresentation.live.actions,
            noticeCount: islandPresentation.live.noticeCount,
            aiActive: heldAIActive,
            autopilotActive: islandPresentation.live.autopilotActive,
            idleMinutes: 0,
            worstVIPTier: islandPresentation.live.vipGlowTier
        ))
        let expanded = panelState.presentedState != .compact
        let glowColor = color(for: snap.glow)
        // Sweep means "AI is working right now". A VIP halo is a steady
        // severity signal, not activity — the old `|| snap.glow != .none`
        // spun the sweep for every urgent island, which misread as work.
        let sweep = snap.phase == .working(.analyzing) && !CompanionMotion.reduceMotion

        ZStack {
            if sweep {
                IslandLoadingSweep(
                    tint: glowColor ?? CompanionPalette.islandMint,
                    notchWidth: notchWidth,
                    notchHeight: notchHeight
                )
            }

            outerShape
                .strokeBorder(IslandChrome.hairline, lineWidth: expanded ? IslandChrome.hairlineWidth : 0)
                .shadow(
                    color: (glowColor ?? Color.clear).opacity(glowColor == nil ? 0 : 0.35),
                    radius: 14, y: 0
                )
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = CompanionMotion.easeOut(0.25) }
    }

    private var outerShape: IslandShape {
        IslandShape(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            pillCornerRadius: 22,
            notchCornerRadius: 10,
            topCornerRadius: 16
        )
    }

    private func color(for glow: CompactIslandGlow) -> Color? {
        switch glow {
        case .none: return nil
        case .attention: return IslandChrome.glowAmber
        case .critical: return IslandChrome.glowRed
        }
    }
}

/// 30 Hz conic sweep. Owns its TimelineView so the rest of the island is not
/// rebuilt at display rate.
private struct IslandLoadingSweep: View {
    let tint: Color
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let rotation = (t * 100).truncatingRemainder(dividingBy: 360)
            IslandShape(
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                pillCornerRadius: 22,
                notchCornerRadius: 10,
                topCornerRadius: 16
            )
            .stroke(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: tint.opacity(0.0), location: 0.55),
                        .init(color: tint, location: 0.78),
                        .init(color: .white.opacity(0.95), location: 0.92),
                        .init(color: tint.opacity(0.0), location: 1.00),
                    ]),
                    center: .center,
                    angle: .degrees(rotation)
                ),
                lineWidth: 4
            )
            .blur(radius: 3)
        }
    }
}
