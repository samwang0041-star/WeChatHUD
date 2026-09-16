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

    /// The house curve for content that appears or disappears in place.
    ///
    /// A strong ease-out — cubic-bezier(0.23, 1, 0.32, 1) — rather than
    /// easeInOut. Every call site is a disclosure, a state flip or a toast:
    /// the user has already committed to the action, so the motion has to
    /// react on the attack and only soften the landing. easeInOut spends its
    /// first third barely leaving the start value, which reads as input lag.
    ///
    /// Borrowed from codex-island (github.com/ericjypark/codex-island),
    /// which cites Emil Kowalski's curve for non-spring UI transitions.
    static func strongEaseOut(_ duration: TimeInterval = 0.2) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// The generic in-place content transition. Still called `ease` because
    /// every caller means "this thing appears / disappears in place", not
    /// "please run an easeInOut".
    static func ease(_ duration: TimeInterval = easeDuration) -> Animation? {
        strongEaseOut(duration)
    }

    /// easeIn with the given duration; nil when reduce motion is on.
    static func easeIn(_ duration: TimeInterval) -> Animation? {
        reduceMotion ? nil : .easeIn(duration: duration)
    }

    /// easeOut with the given duration; nil when reduce motion is on.
    static func easeOut(_ duration: TimeInterval) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    /// In-place appear/disappear default duration.
    static let easeDuration: TimeInterval = 0.18
    /// Full page / tab swap. Longer than an in-place disclosure.
    static let pageChangeDuration: TimeInterval = 0.22
    /// Row hover wash duration.
    static let hoverDuration: TimeInterval = 0.10
    /// Visible press duration (100–140ms band).
    static let pressDuration: TimeInterval = 0.12

    /// Expand morph: slightly underdamped so the surface pops out.
    static let morphExpandResponse: TimeInterval = 0.42
    static let morphExpandDamping: Double = 0.82
    /// Collapse morph: snappier and more damped than expand.
    static let morphCollapseResponse: TimeInterval = 0.30
    static let morphCollapseDamping: Double = 0.88

    /// Standard spring used for expand/collapse transitions.
    ///
    /// Response-based (physical) rather than duration-based: the window-frame
    /// spring in `FloatingPanel` runs response 0.42/0.26, so content riding a
    /// spring from the same family settles together with the frame instead of
    /// visibly leading or lagging it mid-flight.
    static var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9)
    }

    /// Parameterized spring preserving explicit response/damping values.
    static func springResponse(response: TimeInterval, dampingFraction: Double) -> Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: dampingFraction)
    }

    /// Button-press animation (100–140ms).
    static func press() -> Animation? {
        reduceMotion ? nil : .easeOut(duration: pressDuration)
    }

    /// How far a pressable surface shrinks under the cursor.
    ///
    /// The usable band is ~0.92–0.97: below it the surface reads as rubber,
    /// above it the press is invisible next to the opacity wash. Exposed as a
    /// token so the value is assertable rather than buried in a ButtonStyle.
    static let pressScale: CGFloat = 0.96

    /// Row hover wash (~100ms).
    ///
    /// easeOut, not easeInOut: a hover wash must react on the attack (the
    /// cursor is already there) and only soften the landing. easeInOut spends
    /// half its budget barely leaving the start value, which reads as input
    /// lag next to AppKit hover states (Finder, Mail).
    static func hover() -> Animation? { easeOut(hoverDuration) }

    /// Card hover lift/shadow transition.
    static func cardHover() -> Animation? { easeOut(0.14) }

    /// Sidebar module selection. Slightly slower than a hover wash: the
    /// selection fill and its tinted border have to arrive together, and a
    /// 100ms swap on a whole row reads as a flicker next to the page swap
    /// that follows it.
    static func sidebarSelection() -> Animation? { ease(0.20) }

    /// Island compact → hover: same spring family as the frame expand.
    static func islandExpand() -> Animation? { openMorph }
    /// Island leave collapse: same spring family as the frame collapse.
    static func islandCollapse() -> Animation? { closeMorph }

    /// Shape growth. Leisurely: the user is reaching toward the island and tracks the morph.
    static var openMorph: Animation? {
        springResponse(response: morphExpandResponse, dampingFraction: morphExpandDamping)
    }

    /// Shape shrink. Snappier than open. Window-frame collapse stays critically damped.
    static var closeMorph: Animation? {
        springResponse(response: morphCollapseResponse, dampingFraction: morphCollapseDamping)
    }

    /// The silhouette’s own reshape, matched to the window-frame spring.
    ///
    /// The frame is animated by `FloatingPanel`’s display-link spring using
    /// `IslandMotion.spring(expanding:)` — response 0.42 / damping 0.82 on the
    /// way out and 0.26 / 1.0 on the way back. The corner radii ride the same
    /// physics on purpose: if the silhouette reshapes on a different curve from
    /// the body it is drawing, the corners visibly lead or lag the edges for the
    /// length of the transition.
    ///
    /// Note this is *not* `closeMorph` (0.30 / 0.88). Those values are the
    /// SwiftUI content morph; the frame’s collapse is the critically damped
    /// 0.26 / 1.0 pair, and the shape has to match the frame, not the content.
    static func islandSilhouette(expanding: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return expanding
            ? .spring(response: morphExpandResponse, dampingFraction: morphExpandDamping)
            : .spring(response: morphCollapseResponse, dampingFraction: 1.0)
    }

    /// Compact hover stays in .peek this long before opening the inbox.
    /// Tests replace this so they do not wait on the live 180ms.
    static var hoverExpandDelayProvider: () -> TimeInterval = { 0.18 }

    /// In-row expand.
    ///
    /// Same spring as the island open morph: a row's height change re-drives
    /// the panel frame through the measurement pipe, so the content curve and
    /// the frame curve must be the same physics or they visibly desync while
    /// the panel grows around the expanding row.
    static func rowExpand() -> Animation? { openMorph }
    /// Source drawer (200–240ms).
    static func drawer() -> Animation? { ease(0.22) }
    /// Modal fade (140–180ms).
    static func dialog() -> Animation? { ease(0.16) }
    /// Mark complete (160–180ms).
    static func complete() -> Animation? { ease(0.17) }
    /// Save receipt (120ms).
    static func saveReceipt() -> Animation? { ease(0.12) }

    /// A slow, continuous breathe for live status indicators.
    ///
    /// Repeating on purpose: it has to read as "still working" for as long as
    /// the work lasts, unlike every other curve here which is a one-shot
    /// arrival. Gated like the rest, so Reduce Motion gets a steady ring.
    static func pulse() -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
    }

    /// The breathe's period, for callers that need to describe or test it.
    static let pulsePeriod: TimeInterval = 1.15

    // MARK: - Entrances

    /// How long a staggered group takes from first child to last.
    ///
    /// The budget is the point. A page whose cards arrive one after another
    /// reads as considered; the same idea stretched over a second reads as
    /// the app being slow to wake up. This covers five to six children at the
    /// step below and finishes before the eye has settled on the title.
    static let staggerSpan: TimeInterval = 0.24
    /// Delay added per child index. Five children span the budget above.
    static let staggerStep: TimeInterval = 0.045
    /// Longer than a hover, shorter than a page swap: the child is arriving
    /// as part of a group, so it must not feel like it is still loading.
    static let staggerDuration: TimeInterval = 0.30

    /// How far a staggered child rises while fading in.
    ///
    /// 6pt, not 20: at workbench density a larger move makes the page look
    /// like it is assembling itself, and on a list that re-renders it becomes
    /// the most noticeable thing on screen. This is meant to be felt rather
    /// than watched.
    static let staggerRise: CGFloat = 6

    /// One child's entrance: rise a little and fade in. Nil under reduce
    /// motion, which leaves the content present with no delay.
    static func staggerEntrance(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        let capped = min(max(0, index), 6)
        return .timingCurve(0.23, 1, 0.32, 1, duration: staggerDuration)
            .delay(Double(capped) * staggerStep)
    }

    /// The delay a child at this index waits. Exposed separately so the cap
    /// can be asserted without reaching into SwiftUI's Animation.
    static func staggerDelay(index: Int) -> TimeInterval {
        Double(min(max(0, index), 6)) * staggerStep
    }
    /// Full page swap (Settings tab, report page). Longer than an in-place
    /// disclosure: the whole surface changes, so the eye needs a beat to read
    /// it as one replacement rather than a flicker. Same strong ease-out, so
    /// it shares the family with every other content transition.
    static func pageChange() -> Animation? { ease(pageChangeDuration) }

    /// Bare withAnimation default (Animation.default), gated by reduceMotion.
    static var systemDefault: Animation? {
        reduceMotion ? nil : .default
    }

    /// Trackpad tick for the hover expansion.
    ///
    /// A haptic is a separate channel from motion, but someone who asked the
    /// system for reduced motion is asking for less incidental activity, so
    /// the tick is suppressed alongside the animation. No trackpad (or a Mac
    /// without Force Touch) makes this a no-op in AppKit, so no capability
    /// check is needed here. Borrowed from codex-island, which ticks on the
    /// hover-in that morphs its island out to peek width.
    static func performHoverTick() {
        guard !reduceMotion else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
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

extension AnyTransition {
    /// Codex Island detailReveal: small anchored scale + fade, no slide.
    /// A translation would fight the panel-frame spring on row expand.
    static var islandDetailReveal: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

/// Sizes for the notch-anchored island. Compact stays notch-height;
/// expanded is wide enough that a headline and three rows can breathe.
/// How the island reads SwiftUI's reported size.
///
/// The hosting view fills a grow-only stage. `.frame(width:)` without a
/// following `.fixedSize(vertical: true)` takes the stage's proposed
/// height, so a GeometryReader reports the window instead of the inbox.
/// That is the tall black plate under a short list after a row click.
enum IslandMeasurement {
    static let maxExtendedHeight: CGFloat = 720

    /// What the AppDelegate measurement sink should do with a reported size.
    enum SizeAction: Equatable {
        case ignore
        case animate
        case snapInstantly
    }

    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(0, size.width),
            height: min(max(0, size.height), maxExtendedHeight)
        )
    }

    /// Whether a frame change should land in one step instead of starting a
    /// frame spring.
    ///
    /// Three cases, and the third is the one that produced the "clicked
    /// 在微信中打开 and the panel went black" report:
    ///
    /// - Reduce Motion is on: the user asked for no motion.
    /// - There is nothing to travel: the island is already there.
    /// - The panel cannot be drawn right now. `FloatingPanel` drives its spring
    ///   from a display link taken off its content view, and a link does not
    ///   fire while the window is ordered out. A run started on a hidden panel
    ///   therefore never advances: `visibleFrame` stays at the rect it started
    ///   from, the compositor mask keeps revealing that rect, and ordering the
    ///   panel back in re-anchors the same oversized island over the desktop.
    ///   A change nobody can see is landed on its target instead.
    static func landsWithoutMotion(
        reduceMotion: Bool,
        isDisplayable: Bool,
        from: CGSize,
        to: CGSize
    ) -> Bool {
        reduceMotion || !isDisplayable || from == to
    }

    /// What the AppDelegate measurement sink should do with a reported size.
    ///
    /// Peek is a same-height width morph: snapping it would call
    /// `setFrameInstantly`, whose `cancelFrameAnimation` kills the mask spring
    /// that the peek morph is riding — the pill would jump to the new width and
    /// the hover expansion would read as a stutter. So every state that morphs
    /// — and anything that has left the notch — animates.
    ///
    /// A compact-only width change (idle → pending → urgent wing relayout) is
    /// layout jitter, not motion the user asked for: it snaps, which also
    /// re-centers the pill on the notch so a bad compact self-measurement
    /// cannot poison the next hover. A compact measurement that is genuinely
    /// *taller* than the visible island is a real collapse out of an expanded
    /// state, and animates back into the notch.
    static func sizeAction(
        state: HUDState,
        visible: CGSize,
        target: CGSize,
        isAnimating: Bool
    ) -> SizeAction {
        let tolerance = IslandMotion.retargetTolerance(isAnimating: isAnimating)
        if abs(target.width - visible.width) < tolerance,
           abs(target.height - visible.height) < tolerance {
            return .ignore
        }
        switch state {
        case .peek, .extended, .notification, .detail:
            return .animate
        case .compact:
            // A genuine collapse out of a taller island is motion.
            if visible.height > target.height + 8 {
                return .animate
            }
            // Peek → compact is a same-height width morph (~156 pt). Snapping
            // would cancel the in-flight mask spring the same way peek
            // widening used to. If a spring is already running, leave it
            // alone; otherwise start one.
            if abs(visible.width - target.width) > 48 {
                return isAnimating ? .ignore : .animate
            }
            // Compact-only width jitter (idle → pending → urgent) snaps at
            // rest so a bad self-measurement cannot poison the next hover.
            // Mid-flight, ignore it — snapping would kill the collapse.
            if isAnimating {
                return .ignore
            }
            return .snapInstantly
        }
    }

    /// True when `size` is the covering stage, not the inbox content.
    static func isCoveringStage(_ size: CGSize, cover: CGSize, lastContent: CGSize) -> Bool {
        let matchesCover = abs(size.height - cover.height) < 2
            && abs(size.width - cover.width) < 2
        guard matchesCover else { return false }
        // A first layout pass that reports the grow-only window used to pin
        // lastExtendedSize at the 720 pt ceiling. After that every later
        // stage-sized report matched lastContent and sailed through, leaving
        // a short inbox on a tall black plate.
        if lastContent.height <= 1 {
            return isCeilingHeight(size.height)
        }
        return size.height > lastContent.height + 24
    }

    static func isCeilingHeight(_ height: CGFloat) -> Bool {
        height >= maxExtendedHeight - 1
    }

    /// Cached inbox size we can animate to on the next open. The 720 pt
    /// ceiling is the grow-only stage, not a remembered list.
    static func isUsableCachedSize(_ size: CGSize) -> Bool {
        size.width > 1 && size.height > 1 && !isCeilingHeight(size.height)
    }
}

enum IslandChrome {
    static let expandedWidth: CGFloat = 560
    static let notificationMinWidth: CGFloat = 580

    // MARK: - Silhouette radii
    //
    // These are state-driven on purpose. Before this, all three radii were
    // hardcoded (22 / 10 / 16) at every call site, identical in every state,
    // so the silhouette could only ever *scale* — the corner curvature stayed
    // pinned to a 32pt pill while the body grew to 250pt, which is what made
    // an open island read as the same small pill stretched downward.
    //
    // The reference implementation (`MrKai77/DynamicNotchKit`, used by
    // `TheBoredTeam/boring.notch`) keeps an `opened` and a `closed` radius set
    // and swaps between them, exposing the radii as `animatableData` so they
    // interpolate over the spring. Adopting that here is what makes the
    // transition feel like one object unfolding.
    //
    // The direction is deliberate: an open island gets *tighter* corners
    // (it is a panel, not a pill) while the notch's inner radius *grows*, so
    // the cutout keeps hugging the hardware at any speed.

    /// Bottom corners while the island is a notch-height pill.
    static let pillRadiusClosed: CGFloat = 22
    /// Bottom corners once the island is a body. Tighter, so a tall shape
    /// does not look like a lozenge.
    static let pillRadiusOpen: CGFloat = 16
    /// Inner radius of the notch cutout, closed.
    static let notchRadiusClosed: CGFloat = 10
    /// Inner radius of the notch cutout, open. Grows slightly so the cutout
    /// still reads as Apple's notch after the body beneath it widens.
    static let notchRadiusOpen: CGFloat = 12
    /// The outward fillet where the body meets the top edge, closed.
    static let topRadiusClosed: CGFloat = 16
    /// Same fillet, open — a little larger, so the widened body still meets
    /// the screen edge tangentially rather than as a hard shoulder.
    static let topRadiusOpen: CGFloat = 20

    /// The three radii for a presented state, as one value.
    ///
    /// Single source of truth: the island body and the glow layer both draw
    /// the same `IslandShape`, and they used to pass the same three literals
    /// independently. Two copies of a silhouette that must stay pixel-aligned
    /// is a drift waiting to happen — the halo would slowly stop tracing the
    /// body. Everything that draws the silhouette asks here.
    struct SilhouetteRadii: Equatable {
        var pill: CGFloat
        var notch: CGFloat
        var top: CGFloat
    }

    /// Radii for a panel state. Compact and peek share the pill shape;
    /// everything with a body below the notch uses the open set.
    static func radii(for state: HUDState) -> SilhouetteRadii {
        switch state {
        case .compact, .peek:
            return SilhouetteRadii(pill: pillRadiusClosed,
                                   notch: notchRadiusClosed,
                                   top: topRadiusClosed)
        case .extended, .notification, .detail:
            return SilhouetteRadii(pill: pillRadiusOpen,
                                   notch: notchRadiusOpen,
                                   top: topRadiusOpen)
        }
    }
    /// Per-side outboard slot in .peek. Fixed so a count flip cannot jitter the silhouette.
    static let peekSlotWidth: CGFloat = 78
    /// Hairline on the outer silhouette once the island has left compact.
    static let hairlineWidth: CGFloat = 0.5
    static let hairline = Color.white.opacity(0.12)
    /// Ambient glow hues. Opacity stays constant so only hue signals severity.
    static let glowAmber = Color(red: 245 / 255, green: 165 / 255, blue: 36 / 255)
    static let glowRed = Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255)
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

    /// Minimum size delta that justifies bending a window-frame run
    /// mid-flight. At rest the panel hugs measurements tightly (2 pt); while
    /// a spring is running, layout-pass jitter must not retarget it — only a
    /// genuine content change (row expand, snooze menu, briefing card, all
    /// 50 pt+) may bend the trajectory.
    static func retargetTolerance(isAnimating: Bool) -> CGFloat {
        isAnimating ? 6 : 2
    }

    /// Bottom-corner radius of the island mask. Top stays square so the
    /// pill remains flush with the screen edge; the radius is clamped to a
    /// half-side so a compact 32 pt bar still reads as a capsule.
    static func maskCornerRadius(width: CGFloat, height: CGFloat) -> CGFloat {
        min(22, max(0, min(width, height) / 2))
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
