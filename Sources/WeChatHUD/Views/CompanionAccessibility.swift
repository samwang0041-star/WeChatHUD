import SwiftUI
import AppKit

/// The two macOS accessibility switches that change how **chrome is drawn**,
/// as opposed to how it moves (`CompanionMotion`) or how translucent it is
/// (`CompanionMotion.reduceTransparency`).
///
/// Why this exists at all: the design language states its hierarchy with
/// hairlines — `CompanionPalette.border` at 7.5 % of the label colour,
/// `CompanionElevation.edgeRamp` at 5.5 % white on the top edge. Those numbers
/// are tuned for a user looking at a normal-contrast display. macOS ships two
/// switches that say "those numbers are not enough for me":
///
/// - **Increase Contrast** (系统设置 → 辅助功能 → 显示 → 提高对比度)
/// - **Differentiate Without Color** (同页 → 不用颜色区分)
///
/// Before this file the app answered neither, while it did answer Reduce Motion
/// and Reduce Transparency. The result was an inversion: a user who asks the
/// system for *more* definition got the same 7.5 % hairline that everyone else
/// gets, next to every other app's separators deepened by the system — i.e.
/// relatively less legible than with the switch off.
///
/// Mirrors `CompanionMotion`'s shape on purpose: injectable providers so tests
/// can flip a switch without touching the host Mac's settings, read at draw
/// time so nothing has to be invalidated, and a named notification so views
/// re-render when the real switch moves.
enum CompanionAccessibility {
    /// Injectable for tests: stands in for the live NSWorkspace flag.
    static var increaseContrastProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// True when the system asks for stronger definition between surfaces.
    static var increaseContrast: Bool { increaseContrastProvider() }

    /// Injectable for tests: stands in for the live NSWorkspace flag.
    static var differentiateWithoutColorProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    /// True when colour alone must never be the carrier of meaning.
    static var differentiateWithoutColor: Bool { differentiateWithoutColorProvider() }

    // MARK: - Derived chrome tokens

    /// Separator / border stroke width.
    ///
    /// 0.5 pt is the Retina hairline and the right default; on a display the
    /// user has described as low-contrast it disappears into the wash, so the
    /// switch takes it to a full point. Not thicker than 1: without a
    /// deliberate two-tone treatment a 2 pt line reads as a box, and the
    /// design language forbids nested borders.
    static var hairlineWidth: CGFloat { increaseContrast ? 1 : 0.5 }

    /// Card and grouped-panel outline width.
    ///
    /// A card edge is already a full point (it has to survive being stroked
    /// twice — flat border plus lit ramp). Increase Contrast takes it to 1.5,
    /// which is the widest an outline can go before it starts reading as a
    /// container drawn *around* the card rather than the card's own edge.
    static var cardEdgeWidth: CGFloat { increaseContrast ? 1.5 : 1 }

    /// Multiplier applied to every separator / card-edge opacity.
    ///
    /// 2.4 is the smallest factor that moves a 7.5 % hairline onto the same
    /// step as `NSColor.separatorColor` in its increased-contrast variant
    /// (measured against the resolved dynamic colour, ≈ 0.18 of the label
    /// colour on the light canvas). It stays under the point where a card
    /// outline starts competing with its own content — `CompanionMaterialTests`
    /// pins both the factor and that ceiling.
    static var borderOpacityScale: Double { increaseContrast ? 2.4 : 1 }

    /// Applies the contrast factor to a nominal opacity, clamped so a
    /// deliberately faint decorative wash (an ambient tint, a hover layer)
    /// never turns into an edge just because the switch is on.
    static func contrastAdjusted(_ opacity: Double) -> Double {
        min(opacity * borderOpacityScale, 0.32)
    }

    // MARK: - Derived text ramp

    /// The dimmest white-on-dark foreground that still clears 4.5:1 — the WCAG
    /// AA threshold for body text — against these surfaces' near-black canvas.
    ///
    /// Derived, not picked: `Color.white.opacity(a)` over the 0.94-black canvas
    /// resolves to an sRGB channel of ≈ a, and the ratio against that canvas is
    /// `(lin(a) + 0.05) / (lin(0.06) + 0.05)` where `lin` is the sRGB
    /// linearisation. That crosses 4.5 at a ≈ 0.50, hence 0.52 with a hair of
    /// margin. `CompanionAccessibilityTests` recomputes the ratio for every
    /// nominal value the app ships and fails if one lands under the threshold.
    static let legibleDimFloor: Double = 0.52

    /// Ceiling for the lift. Above this a caption stops reading as a caption
    /// and starts competing with the title the ramp exists to sit under.
    static let legibleDimCeiling: Double = 0.86

    /// Primary-text threshold: at 0.88 and above the foreground is already the
    /// loudest thing on the surface, and lifting it further would only flatten
    /// the hierarchy.
    static let primaryForegroundThreshold: Double = 0.88

    /// Foreground opacity for dimmed text on the island and retrospective
    /// canvases.
    ///
    /// `borderOpacityScale` answers "this hairline is too faint to see as an
    /// edge" and does nothing for the far more common complaint on those two
    /// surfaces, which is the 0.30–0.65 white text that carries the actual
    /// sentences. The switch now lifts that ramp too: monotonically, so
    /// whatever was quieter stays quieter, but never below `legibleDimFloor`.
    static func foregroundOpacity(_ nominal: Double) -> Double {
        guard increaseContrast else { return nominal }
        guard nominal < primaryForegroundThreshold else { return nominal }
        let lifted = min(max(nominal * 1.35, legibleDimFloor), legibleDimCeiling)
        // The outer `max` is load-bearing: a ceiling alone would *dim* a value
        // sitting just above it (0.87 → 0.86), and a legibility switch must
        // never make anything harder to read than it already was.
        return max(nominal, lifted)
    }

    /// The keyboard focus ring.
    ///
    /// macOS draws this itself for AppKit controls, but every custom control in
    /// this app (filter pills, sidebar rows, cards that act as buttons) is a
    /// SwiftUI shape and gets nothing unless the view draws it. HIG lists a
    /// visible focus indicator as a requirement, not a nicety: without it the
    /// Full Keyboard Access user has no idea where they are.
    static let focusRingWidth: CGFloat = 3
    /// Inset so the ring sits inside the control's own bounds and cannot be
    /// clipped by a neighbouring row.
    static let focusRingInset: CGFloat = 1.5

    /// Posts when either real switch moves, so views that read these tokens
    /// during `body` can invalidate themselves.
    ///
    /// `NSWorkspace` posts on its own notification centre, which SwiftUI's
    /// `onReceive` does not observe; this bridges it onto the default centre.
    static let displayOptionsDidChange = Notification.Name(
        "com.wechat-hud.companionAccessibilityDisplayOptionsDidChange"
    )

    /// Bumped every time the display options move.
    ///
    /// This exists because the contrast tokens are **statics**. SwiftUI
    /// invalidates a view when something it *read* changed; a static read from
    /// inside `body` establishes no dependency, so a card whose whole
    /// appearance comes from `CompanionPalette.border` would happily keep the
    /// old colour after the user flipped the switch. Incrementing this and
    /// carrying it in the environment (see `companionDisplayGeneration`) is
    /// what gives those views something to depend on.
    ///
    /// The same gap existed for Reduce Transparency before this — the preview
    /// button appeared to work only because it also re-identified the demo
    /// chrome, so the redraw was incidental rather than caused.
    private(set) static var generation: Int = 0

    /// Records that the options moved and tells the roots to re-publish.
    static func noteDisplayOptionsChanged() {
        generation &+= 1
        NotificationCenter.default.post(name: displayOptionsDidChange, object: nil)
    }

    private static var bridgeInstalled = false

    /// Called once at launch. Idempotent.
    static func installSystemBridge() {
        guard !bridgeInstalled else { return }
        bridgeInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            noteDisplayOptionsChanged()
        }
    }
}

private struct CompanionDisplayGenerationKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Reading `colorSchemeContrast` is what makes SwiftUI re-evaluate a view
    /// when the user flips Increase Contrast, so views that need the *drawn*
    /// tokens should touch this. `CompanionAccessibility.increaseContrast` is
    /// for AppKit-side drawing and tests, where there is no environment.
    var companionIncreaseContrast: Bool { colorSchemeContrast == .increased }
    var companionDifferentiateWithoutColor: Bool { accessibilityDifferentiateWithoutColor }

    /// The display-options generation. Any view whose appearance is computed
    /// from `CompanionAccessibility` statics should read this so a switch flip
    /// reaches it.
    var companionDisplayGeneration: Int {
        get { self[CompanionDisplayGenerationKey.self] }
        set { self[CompanionDisplayGenerationKey.self] = newValue }
    }
}

extension View {
    /// Draws the macOS focus ring around a custom control while `focused`.
    ///
    /// Uses the system accent so it matches AppKit's own ring rather than the
    /// app's jade, which is what a person comparing this window to Finder
    /// expects to see.
    func companionFocusRing(_ focused: Bool, radius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .keyboardFocusIndicatorColor),
                    lineWidth: CompanionAccessibility.focusRingWidth
                )
                .padding(-CompanionAccessibility.focusRingInset)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// Publish the display-options generation into the subtree.
    ///
    /// Applied at the two roots (workspace, island) from a `@State` the
    /// `displayOptionsDidChange` notification bumps. Everything below that
    /// reads `companionDisplayGeneration` then redraws when a switch moves.
    func companionDisplayGeneration(_ generation: Int) -> some View {
        environment(\.companionDisplayGeneration, generation)
    }
}

/// A hairline outline that follows the Increase Contrast switch.
///
/// Drop-in for the `Capsule().strokeBorder(CompanionPalette.border)` /
/// `RoundedRectangle(...).strokeBorder(...)` calls scattered through the
/// workspace. Those were the reason a switch flip did not fully reach the
/// screen: they read a static inside a body that had no reason to re-run. The
/// shape is a parameter so the call site keeps whatever silhouette it had.
struct CompanionHairline<S: InsettableShape>: View {
    let shape: S
    /// Overrides the plain separator weight — used where the outline means
    /// "selected" rather than "this is a card".
    var tint: Color? = nil

    @Environment(\.companionDisplayGeneration) private var generation

    var body: some View {
        // The read is the point, not the value: it is what makes this view
        // depend on the generation.
        let _ = generation
        shape.strokeBorder(
            tint ?? CompanionPalette.border,
            lineWidth: CompanionAccessibility.cardEdgeWidth
        )
    }
}

extension InsettableShape {
    /// Wrap this shape in a contrast-aware hairline outline.
    func companionHairline(tint: Color? = nil) -> CompanionHairline<Self> {
        CompanionHairline(shape: self, tint: tint)
    }
}

/// Dimmed white text that answers Increase Contrast.
///
/// A modifier rather than a `foregroundColor(.white.opacity(ramp(x)))` at the
/// call site because of the dependency: the ramp is a *static* read, and
/// SwiftUI only re-evaluates a view when something it *read* changes. Reading
/// `companionDisplayGeneration` here is what makes a switch flip redraw the
/// sentences instead of leaving the old opacity until some unrelated
/// invalidation happens to come along.
private struct CompanionDimmedForegroundModifier: ViewModifier {
    let nominal: Double

    @Environment(\.companionDisplayGeneration) private var generation

    func body(content: Content) -> some View {
        let _ = generation
        content.foregroundColor(
            .white.opacity(CompanionAccessibility.foregroundOpacity(nominal))
        )
    }
}

extension View {
    /// `foregroundColor(.white.opacity(nominal))` that also lifts under
    /// Increase Contrast. Drop-in for the dimmed text on the dark island and
    /// retrospective canvases.
    func companionDimmedForeground(_ nominal: Double) -> some View {
        modifier(CompanionDimmedForegroundModifier(nominal: nominal))
    }
}
