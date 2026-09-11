import SwiftUI
import AppKit
import simd

/// Central motion gate for "respect system reduce motion" (ui-language.md
/// invariant 5). Every animation in the app flows through this enum so the
/// system accessibility setting disables motion without changing any
/// duration or curve values.
enum CompanionMotion {
    /// Injectable for tests: when replaced, stands in for the live
    /// NSWorkspace accessibility flag.
    static var reduceMotionProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True when the system asks the app to minimize non-essential motion.
    static var reduceMotion: Bool { reduceMotionProvider() }

    /// Injectable for tests: stands in for Reduce Transparency.
    static var reduceTransparencyProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// True when the system asks for more opaque surfaces.
    static var reduceTransparency: Bool { reduceTransparencyProvider() }

    /// easeInOut with the given duration; nil when reduce motion is on.
    static func ease(_ duration: TimeInterval = 0.18) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }

    /// easeIn with the given duration; nil when reduce motion is on.
    static func easeIn(_ duration: TimeInterval) -> Animation? {
        reduceMotion ? nil : .easeIn(duration: duration)
    }

    /// easeOut with the given duration; nil when reduce motion is on.
    static func easeOut(_ duration: TimeInterval) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    /// Standard spring used for expand/collapse transitions.
    static var spring: Animation? {
        reduceMotion ? nil : .spring(duration: 0.25)
    }

    /// Parameterized spring preserving explicit response/damping values.
    static func springResponse(response: TimeInterval, dampingFraction: Double) -> Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: dampingFraction)
    }

    /// Button-press animation (100–140ms).
    static func press() -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    /// Row hover wash (100–120ms).
    static func hover() -> Animation? { ease(0.11) }
    /// Island compact → hover: pop out of the notch.
    static func islandExpand() -> Animation? { easeOut(IslandMotion.expandDuration) }
    /// Island leave collapse: retract into the notch.
    static func islandCollapse() -> Animation? { easeIn(IslandMotion.collapseDuration) }

    /// In-row expand (180–220ms).
    static func rowExpand() -> Animation? { ease(0.20) }
    /// Source drawer (200–240ms).
    static func drawer() -> Animation? { ease(0.22) }
    /// Modal fade (140–180ms).
    static func dialog() -> Animation? { ease(0.16) }
    /// Mark complete (160–180ms).
    static func complete() -> Animation? { ease(0.17) }
    /// Save receipt (120ms).
    static func saveReceipt() -> Animation? { ease(0.12) }
    /// Page content fade (120–160ms).
    static func pageChange() -> Animation? { ease(0.14) }

    /// Bare withAnimation default (Animation.default), gated by reduceMotion.
    static var systemDefault: Animation? {
        reduceMotion ? nil : .default
    }
}

/// Run body inside the given animation, or with animation explicitly
/// disabled when animation is nil (reduce motion on). Guarantees the
/// state change still happens without any animation.
func withMotion(_ animation: Animation?, _ body: () -> Void) {
    if let animation {
        withAnimation(animation, body)
    } else {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction, body)
    }
}

extension View {
    /// Equivalent of .animation(_:value:) but the animation is nil when
    /// reduce motion is on. Chains like the standard modifier.
    func companionAnimation<V: Equatable>(_ motion: Animation?, value: V) -> some View {
        animation(motion, value: value)
    }
}

/// Sizes for the notch-anchored island. Compact stays notch-height;
/// expanded is wide enough that a headline and three rows can breathe.
enum IslandChrome {
    static let expandedWidth: CGFloat = 560
    static let notificationMinWidth: CGFloat = 580
    /// Below-notch budget used before a banner has measured itself — an
    /// **upper bound on real content**, not an average. It has to stay one,
    /// because it is not only the first frame's size: when the same message is
    /// re-presented the banner keeps its `.id`, so the size preference does not
    /// fire again and the fallback is what the panel is left with. A fallback
    /// below real content clips the message; above it costs one frame of extra
    /// height that the spring usually retargets away before it is drawn.
    /// 116 pt is the measured three-line banner (145 pt) less the 32 pt notch.
    static let notificationBaseBelowNotch: CGFloat = 116
}

/// Height budget for the `.notification` banner.
///
/// The panel used to be sized from a static estimate
/// (`notchHeight + notificationBaseBelowNotch`), which is only correct for
/// the shortest possible banner: a long group name plus a three-line
/// snippet lays out taller than that, so the action row was cut off by the
/// window's bottom edge. The banner now reports its rendered height through
/// `SizePreferenceKey`, the same pipe the extended inbox uses, and the
/// panel hugs that measurement.
///
/// The clamp around that measurement is asymmetric on purpose:
///
///   - **Floor = the shortest banner that can exist** (a one-line message:
///     `topGap + identityLine + rowGap + one line + bottomGap` ≈ 68 pt).
///     It exists to reject a bogus near-zero measurement, not to pad the
///     panel. It used to be 168 pt — the panel was then born 89 pt taller
///     than a short banner's content, and that black tail was the emptiness
///     this layout was rebuilt to remove.
///   - **Ceiling = the tallest real content** (the expanded briefing card,
///     measured ~534 pt).
enum IslandNotificationLayout {
    /// Shortest real banner below the notch, in points. A rendering shorter
    /// than this means "no usable measurement yet", never "a small banner".
    static let minBelowNotch: CGFloat = 68

    /// Ceiling for the hung banner, below the notch — a runaway guard, not a
    /// design budget. The tallest real content is the expanded briefing card
    /// with its own 稍后提醒 menu open (measured 615 pt total, i.e. 583 below
    /// the notch), and the panel clips whatever the ceiling cuts off.
    static let maxBelowNotch: CGFloat = 600

    /// Width the panel gives the banner. Single source of truth shared by
    /// `AppDelegate.panelSize(for:)` (which sizes the NSPanel) and
    /// `NotificationBannerView.bannerWidth` (which lays the content out at
    /// this width from the first frame so text never re-wraps mid-grow) —
    /// if the two ever disagree, the banner either clips sideways or the
    /// first-frame wrapping bug returns.
    static func panelWidth(notchWidth: CGFloat) -> CGFloat {
        max(IslandChrome.notificationMinWidth, notchWidth + 240)
    }

    /// Panel height for a banner whose content measured `contentHeight`
    /// (the banner's own rendered height, notch padding included).
    /// `contentHeight <= 1` means "no measurement yet" — fall back to the
    /// historical static estimate.
    static func panelHeight(measuredContentHeight contentHeight: CGFloat,
                            notchHeight: CGFloat,
                            fallbackBelowNotch: CGFloat) -> CGFloat {
        guard contentHeight > 1 else { return notchHeight + fallbackBelowNotch }
        let floor = notchHeight + minBelowNotch
        let ceiling = notchHeight + maxBelowNotch
        return min(max(contentHeight, floor), ceiling)
    }
}

/// Frame dynamics for "grows out of the Dynamic Island / sucks back in".
///
/// The window frame is driven by a damped-spring integrator (see
/// `FloatingPanel`), not a fixed-duration easing curve. Springs carry
/// velocity across retargets — a mid-flight target change (measured
/// banner height arriving, a second notification, hover collapse
/// starting while expand is still in flight) bends the trajectory
/// instead of stopping and restarting, which is what reads as "卡".
enum IslandMotion {
    /// Nominal settle times used by the debug slow-mo path and tests.
    static let expandDuration: TimeInterval = 0.36
    static let collapseDuration: TimeInterval = 0.22

    /// Spring constants in (stiffness, damping). Converted from the
    /// familiar response/dampingFraction pair: k = (2π/r)², c = 4π·ζ/r.
    /// Expand is slightly underdamped so the island visibly "pops" out;
    /// collapse is critically damped so it tucks away without bouncing.
    static func spring(expanding: Bool) -> (stiffness: Double, damping: Double) {
        spring(expanding: expanding, distance: .infinity)
    }

    /// The pair a run uses at `distance` points from its goal.
    ///
    /// An expand pops out of the notch (underdamped) until it is inside
    /// `arrivalBand`, then borrows the critically damped pair so the last
    /// couple of points converge from one side instead of ringing across the
    /// pixel grid.
    static func spring(expanding: Bool, distance: Double) -> (stiffness: Double, damping: Double) {
        let popping = expanding && distance >= arrivalBand
        var response = popping ? 0.42 : 0.26
        let dampingFraction = popping ? 0.82 : 1.0
        // AnimationDebugger's slow-mo used to stretch the fixed-duration
        // ease; under springs the equivalent is scaling the response.
        if AnimationDebugger.isSlowMotion {
            response *= AnimationDebugger.slowDuration / expandDuration
        }
        let omega = 2 * .pi / response
        return (omega * omega, 2 * dampingFraction * omega)
    }

    /// Per-axis velocity (pt/s) below which a spring run counts as settled.
    static let settleVelocity: Double = 18
    /// Distance (pt) inside which an expand stops popping and arrives
    /// critically damped.
    ///
    /// The expand is deliberately underdamped so the island pops out of the
    /// notch, but the tail of that ring decays to a fraction of a point and
    /// then crosses pixel boundaries a few times: the traced hover expansion
    /// stepped 1 pt three times in its last ~100 ms (x, then y/h, then w)
    /// after the motion had visibly stopped. Ringing is worth having over
    /// hundreds of points of travel and worth nothing over the last two, so
    /// inside this band the run borrows the critically damped pair and
    /// converges from one side.
    static let arrivalBand: Double = 2.0
    /// Per-axis distance (pt) below which a spring run used to count as
    /// settled. Kept as the reference the historical freeze test measures
    /// against; the live settle test is pixel-based (see
    /// `IslandFrameSpring.hasSettled`).
    static let settleDistance: Double = 0.45
    /// Hard cap so a wedged run can never pin the panel mid-animation.
    /// Scaled under AnimationDebugger slow-mo so the cap stays "10× the
    /// nominal expand" rather than truncating the debug animation itself.
    static var maxRunDuration: TimeInterval {
        AnimationDebugger.isSlowMotion
            ? 2.5 * (AnimationDebugger.slowDuration / expandDuration)
            : 2.5
    }
    /// Clamp for a display-link hitch — a 200 ms stall must not slingshot
    /// the frame. Anything above one 20 Hz step is treated as a stall.
    static let maxStep: TimeInterval = 1.0 / 20.0

    /// Ease-out back: bursts downward from the island, overshoots, settles.
    /// Retained for tests that pin the historical curve shape.
    static func expandProgress(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        let overshoot: CGFloat = 1.2
        let c3 = overshoot + 1
        return 1 + c3 * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
    }

    /// Ease-in cubic: starts slow, then accelerates into the notch.
    /// Retained for tests that pin the historical curve shape.
    static func collapseProgress(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        return x * x * x
    }

    static func isExpanding(from: NSRect, to: NSRect) -> Bool {
        to.height > from.height + 1 || to.width > from.width + 1
    }
}

/// Integrator state for the window-frame spring.
///
/// `FloatingPanel` owns *when* a run starts, retargets and finishes; the
/// arithmetic and the "has it settled?" rule live here because the panel
/// needs a live `NSPanel` that a test cannot step per vsync.
///
/// `position` is the spring's own, continuous state. It must never be
/// re-seeded from the window's `frame` on every tick: AppKit stores window
/// rects as whole points, so reading the frame back re-injects the
/// quantizer's error, and the run freezes 1–3 pt short of its target with a
/// permanent `k · offset / c` velocity (≈51 pt/s at our 2–3 pt residual).
/// That is above `settleVelocity`, so the settle test can never pass — the
/// bug behind the panel snapping a few pixels toward the notch corner
/// seconds after the hover expansion had already looked finished.
struct IslandFrameSpring {
    /// x, y, width, height of the window, in screen points.
    var position: SIMD4<Double>
    /// pt/s, per component.
    var velocity: SIMD4<Double>
    /// x, y, width, height the run is heading to.
    var target: SIMD4<Double>
    /// Expand is underdamped (a pop out of the notch); collapse is
    /// critically damped.
    var expanding: Bool

    init(position: SIMD4<Double>, target: SIMD4<Double>, expanding: Bool) {
        self.position = position
        self.velocity = .zero
        self.target = target
        self.expanding = expanding
    }

    /// One vsync step of semi-implicit Euler: velocity integrates
    /// acceleration, position integrates the new velocity. Stable for our
    /// stiffness range and cheap enough to run inside a display-link tick.
    mutating func step(dt: TimeInterval) {
        let (k, c) = IslandMotion.spring(expanding: expanding,
                                         distance: simd_distance(position, target))
        let accel = -k * (position - target) - c * velocity
        velocity += accel * dt
        position += velocity * dt
    }

    /// The rect to hand to `setFrame`. Any rounding AppKit does to this is
    /// confined to what is painted; `position` stays continuous.
    var frame: NSRect {
        NSRect(x: position.x, y: position.y, width: position.z, height: position.w)
    }

    /// True once the run is close enough and slow enough to end. Both
    /// thresholds must be clear: distance alone would stop the spring at
    /// the instant it passes the target mid-flight, and velocity alone
    /// would stop a run that is momentarily still but far away.
    var hasSettled: Bool {
        simd_distance(position, target) < IslandMotion.settleDistance
            && simd_length(velocity) < IslandMotion.settleVelocity
    }

    /// True when the rect the window server is storing is already the rect the
    /// run will end on, and the spring is slow.
    ///
    /// `painted` is read back from the live window each tick, so this asks the
    /// only question that matters visually: is there anything left to change?
    /// Comparing the *stored* rects — rather than the spring's own distance to
    /// its target — is what keeps a run from correcting the panel after its
    /// motion has visibly stopped.
    ///
    /// That correction is unavoidable unless the target is chosen for the
    /// quantizer. AppKit floors the origin and ceils the size (verified live:
    /// `w: 560.1` is stored as `561`, `x: 500.6` as `500`), so a spring
    /// converging on the *ideal* fractional rect from above stalls a point
    /// outside it and never rounds back down. The traced hover expansion sat
    /// motionless at `561×253` for ~200 ms and then the finish snap repainted
    /// `560×252` — the "last-step jitter" reported from an idle-pill hover.
    /// Rounding the paint instead moved the knife edge to the half point, where
    /// the same trace showed the left edge flipping `583 ↔ 584` for ~150 ms.
    ///
    /// `FloatingPanel` therefore aims the spring at the *centre of the
    /// quantization cell* for the landing rect (origin + ½, size − ½), so the
    /// stored rect equals the landing rect throughout the tail and the run can
    /// end with nothing left to correct.
    func hasArrived(painted: SIMD4<Double>, landing: SIMD4<Double>) -> Bool {
        simd_length(velocity) < IslandMotion.settleVelocity && painted == landing
    }
}
