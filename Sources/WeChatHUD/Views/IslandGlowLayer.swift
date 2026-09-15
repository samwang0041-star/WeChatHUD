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
                    notchHeight: notchHeight,
                    radii: IslandChrome.radii(for: panelState.presentedState)
                )
            }

            outerShape
                .strokeBorder(IslandChrome.hairline, lineWidth: expanded ? IslandChrome.hairlineWidth : 0)
                .shadow(
                    color: (glowColor ?? Color.clear).opacity(glowColor == nil ? 0 : 0.35),
                    radius: 14, y: 0
                )
                // Same reshape spring as the body it traces. The halo and the
                // silhouette are two drawings of one edge; if they animate on
                // different curves the glow separates from the shape mid-flight.
                .animation(
                    CompanionMotion.islandSilhouette(expanding: expanded),
                    value: panelState.presentedState
                )
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = CompanionMotion.easeOut(0.25) }
    }

    private var outerShape: IslandShape {
        IslandShape(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            pillCornerRadius: IslandChrome.radii(for: panelState.presentedState).pill,
            notchCornerRadius: IslandChrome.radii(for: panelState.presentedState).notch,
            topCornerRadius: IslandChrome.radii(for: panelState.presentedState).top
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

/// 30 Hz continuous perimeter sweep. Owns its TimelineView so the rest of the island is not
/// rebuilt at display rate.
private struct IslandLoadingSweep: View {
    let tint: Color
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// Same silhouette as the body it traces. Passed in rather than
    /// hardcoded so the sweep cannot drift off the island’s edges when the
    /// radii change with state.
    let radii: IslandChrome.SilhouetteRadii
    /// One full loop duration in seconds.
    private let cycleDuration: Double = 2.4
    /// Length of the glowing beam as a fraction of the shape perimeter.
    private let beamLength: CGFloat = 0.16
    /// Number of layered segments to form a smooth fading comet tail.
    private let tailSteps = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let rawProgress = (t / cycleDuration).truncatingRemainder(dividingBy: 1.0)
            let progress = CGFloat(rawProgress < 0 ? rawProgress + 1.0 : rawProgress)
            let stepLen = beamLength / CGFloat(tailSteps)

            ZStack {
                ForEach(0..<tailSteps, id: \.self) { i in
                    let fraction = CGFloat(tailSteps - i) / CGFloat(tailSteps)
                    let center = progress - CGFloat(i) * stepLen * 0.92
                    let norm = center < 0 ? center + 1.0 : (center > 1.0 ? center - 1.0 : center)
                    let opacity = pow(fraction, 1.6)
                    let isHead = i == 0
                    let strokeColor = isHead ? Color.white.opacity(0.95) : tint.opacity(opacity * 0.88)
                    let lineWidth: CGFloat = isHead ? 3.5 : (1.8 + fraction * 1.6)
                    let blurRadius: CGFloat = isHead ? 0.6 : (0.8 + (1.0 - fraction) * 2.2)

                    beamSegment(center: norm, length: stepLen * 1.5, color: strokeColor, lineWidth: lineWidth)
                        .blur(radius: blurRadius)
                }
            }
        }
    }

    @ViewBuilder
    private func beamSegment(center: CGFloat, length: CGFloat, color: Color, lineWidth: CGFloat) -> some View {
        let shape = IslandShape(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            pillCornerRadius: radii.pill,
            notchCornerRadius: radii.notch,
            topCornerRadius: radii.top
        )
        let half = length / 2
        let start = center - half
        let end = center + half
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        if start < 0 {
            shape.trim(from: start + 1.0, to: 1.0).stroke(color, style: style)
            shape.trim(from: 0.0, to: end).stroke(color, style: style)
        } else if end > 1.0 {
            shape.trim(from: start, to: 1.0).stroke(color, style: style)
            shape.trim(from: 0.0, to: end - 1.0).stroke(color, style: style)
        } else {
            IslandShape(
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                pillCornerRadius: radii.pill,
                notchCornerRadius: radii.notch,
                topCornerRadius: radii.top
            )
            .trim(from: start, to: end)
            .stroke(color, style: style)
        }
    }
}
