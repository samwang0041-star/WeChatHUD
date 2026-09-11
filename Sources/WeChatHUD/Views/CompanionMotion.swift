import SwiftUI
import AppKit

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
    static let islandLeaveDelay: TimeInterval = 0.40
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
    static let notificationBaseBelowNotch: CGFloat = 168
}

/// Height budget for the `.notification` banner.
///
/// The panel used to be sized from a static estimate
/// (`notchHeight + notificationBaseBelowNotch`), which is only correct for
/// the shortest possible banner: a long group name plus a three-line
/// snippet lays out taller than that, so the action row was cut off by the
/// window's bottom edge. The banner now reports its rendered height through
/// `SizePreferenceKey`, the same pipe the extended inbox uses, and the
/// panel hugs that measurement. The static constants below survive only as
/// the floor / pre-measurement fallback.
enum IslandNotificationLayout {
    /// Smallest useful distance below the notch. Matches the historical
    /// static budget, so the measured path can only ever grow the panel —
    /// a bogus short measurement can never produce a sliver window.
    static let minBelowNotch: CGFloat = 168

    /// Ceiling for the hung banner, below the notch. The tallest real
    /// content is the expanded briefing card (measured ~534 pt total),
    /// which fits comfortably inside this.
    static let maxBelowNotch: CGFloat = 560

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

/// Frame curves for "grows out of the Dynamic Island / sucks back in".
enum IslandMotion {
    static let expandDuration: TimeInterval = 0.36
    static let collapseDuration: TimeInterval = 0.22

    /// Ease-out back: bursts downward from the island, overshoots, settles.
    static func expandProgress(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        let overshoot: CGFloat = 1.2
        let c3 = overshoot + 1
        return 1 + c3 * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
    }

    /// Ease-in cubic: starts slow, then accelerates into the notch.
    static func collapseProgress(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        return x * x * x
    }

    static func isExpanding(from: NSRect, to: NSRect) -> Bool {
        to.height > from.height + 1 || to.width > from.width + 1
    }
}
