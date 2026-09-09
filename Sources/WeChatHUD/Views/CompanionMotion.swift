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
    static let briefingExtra: CGFloat = 360
    static let snoozeExtra: CGFloat = 176
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
