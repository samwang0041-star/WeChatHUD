import SwiftUI
import AppKit

/// The workspace's depth and light language.
///
/// Why this exists: every workspace surface used to be the same flat recipe —
/// one fill, one 1pt border, no shadow. That is honest but inert: a page of
/// eight equal cards has no depth cue, so the eye cannot tell an instrument
/// panel from a list row, and the window reads as a web form rather than a
/// Mac app. CleanMyMac 5 is the reference the product owner pointed at, and
/// the thing worth borrowing from it is not its marketing hero art — it is
/// that *light has a direction*: surfaces are lit from above (a highlight
/// along the top edge, a soft shadow underneath), the window ground carries a
/// faint tint of the module's own accent, and the one primary action glows.
///
/// Everything here is deliberately quiet. At workbench density — 12–17pt
/// type, 20 rows on screen — a strong gradient or a big shadow turns into
/// noise. The bands below are chosen so that a card reads as *lifted* without
/// the user being able to point at why:
///
///   - highlight: 4–7 % white on the top edge, nothing on the sides
///   - shadow: one soft pass, never stacked, never darker than 22 % black
///   - ambient tint: 3–6 % of the module accent, over at most the top third
///
/// Reduce Transparency replaces the gradients with flat fills at the same
/// contrast, so the hierarchy survives without translucency.
enum CompanionElevation {
    /// Cards and grouped panels. The default page furniture.
    static let cardRadius: CGFloat = 14
    /// Inset sub-panels inside a card (one step down the hierarchy).
    static let insetRadius: CGFloat = 10

    /// Top-edge highlight: what makes a face look lit from above.
    static var topHighlight: Color { Color.white.opacity(0.055) }

    /// The face’s own luminance ramp, top to bottom, per scheme.
    ///
    /// Dark: a white cap fading into a slightly darker floor. Light: the card
    /// is already near white, so the ramp only darkens toward the bottom — a
    /// white-on-white cap would be a no-op.
    static var faceRamp: [Color] {
        isLightAppearance
            ? [Color.white.opacity(0.0), Color.black.opacity(0.020)]
            : [
                Color.white.opacity(0.030),
                Color.white.opacity(0.004),
                Color.black.opacity(bottomShadeOpacity)
            ]
    }

    /// Resolved from the current drawing appearance rather than the system
    /// setting, so `--preview-light` and a real light-mode Mac agree.
    static var isLightAppearance: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .aqua
    }

    /// The card’s outline, lit along the top edge. On the dark canvas the
    /// lit edge is white; on the light canvas a white edge vanishes into the
    /// card, so the outline carries a light top and a defined bottom instead.
    ///
    /// Under **Increase Contrast** every non-zero stop is scaled by
    /// `CompanionAccessibility.borderOpacityScale`. The ramp keeps its shape —
    /// the light still comes from above — but the edge becomes an edge rather
    /// than a suggestion, which is the whole point of the switch.
    static var edgeRamp: [Color] {
        let k = CompanionAccessibility.borderOpacityScale
        if isLightAppearance {
            return [
                Color.white.opacity(0.0),
                Color.black.opacity(0.055 * k),
                Color.black.opacity(0.085 * k)
            ]
        }
        return [
            Color.white.opacity(topHighlightOpacity * k),
            Color.white.opacity(0.0),
            Color.black.opacity(0.10 * k)
        ]
    }
    /// The same highlight as a number, so its relationship to the bottom
    /// shade is assertable rather than buried in a view body.
    static let topHighlightOpacity: Double = 0.055
    /// The bottom edge darkens by this much, which is what makes the top
    /// read as lit. Without it the gradient is a uniform wash.
    static let bottomShadeOpacity: Double = 0.012

    /// Card drop shadow. One pass, soft and low.
    static var cardShadow: Color { Color.black.opacity(0.20) }
    static let cardShadowRadius: CGFloat = 14
    static let cardShadowY: CGFloat = 6

    /// Hover elevation: the shadow tightens and the surface lifts a hair.
    /// A card that grows a large shadow on hover reads as a jump; this is a
    /// 1pt translate plus a slightly tighter shadow.
    static let hoverLift: CGFloat = 1
    static var hoverShadow: Color { Color.black.opacity(0.28) }
    static let hoverShadowRadius: CGFloat = 18
    static let hoverShadowY: CGFloat = 9

    /// Ambient tint strength for the window ground, per module accent.
    ///
    /// Tuned against a measurement, not by eye. The wash exists so that
    /// switching modules changes the room rather than only the text; at the
    /// original 0.055 the ground measured a peak channel spread of 8–16
    /// against the reference product’s 60, i.e. present but below the
    /// threshold where anyone would notice it — the feature was not doing
    /// its job. Measured again after this change: 34–46 depending on accent.
    ///
    /// The reference’s 60 is not reachable from here, and the reason is
    /// structural rather than a matter of taste: its window is a colour field
    /// with bright, sparse text on it, while this window is a workbench whose
    /// ground carries small meta text. The ceiling below is therefore derived
    /// from the text (see `onWashTextOpacity`), and this number is raised until
    /// that ceiling — not this — is what stops the wash.
    static let ambientTint: Double = 0.46

    /// Target relative luminance of the washed ground at its peak — i.e.
    /// how bright the room gets.
    ///
    /// Chosen against the reference, and against a readability budget. The
    /// reference product’s ground measures 0.058, which is a saturated
    /// colour field; it can afford that because the only text it puts on the
    /// field is bright and sparse. A ground that bright is not available to a
    /// workbench — 55 % white secondary text on it measures 2.9:1, below AA.
    ///
    /// So the ceiling is derived rather than asserted, from the text that
    /// actually sits on the wash (see onWashTextOpacity).
    static let ambientPeakGroundLuminance: Double = 0.048

    /// The step used for supporting text that sits on the wash — the page
    /// header’s subtitle and its date stamp.
    ///
    /// Brighter than the 0.55 secondaryLabelColor used everywhere else, and
    /// deliberately so: this is the same structural move the reference makes.
    /// Its colour field is readable because nothing dim is set on it. Using the
    /// ordinary secondary step here caps the wash at a lift of 0.0066 and
    /// leaves the module colour at a fraction of the reference’s strength —
    /// measured, not guessed. Brightening the two lines that live on the wash
    /// is what buys the room its colour.
    static let onWashTextOpacity: Double = 0.80

    /// WCAG AA for normal text.
    static let aaNormalText: Double = 4.5

    /// The brightest the ground may get before onWashTextOpacity stops passing
    /// AA on it. Solving (L_text + 0.05) / (L_ground + 0.05) = 4.5 for L_ground.
    static var ambientLuminanceCeiling: Double {
        let text = relativeLuminance([Double](repeating: onWashTextOpacity, count: 3))
        return (text + 0.05) / aaNormalText - 0.05
    }

    static let ambientBaseTint: Double = 0.045
    /// How far down the primary ambient tint reaches before it is fully faded.
    /// Kept deliberately short so the strong band belongs to the header. A wash
    /// that runs the full page would put the app’s small meta text on the
    /// brightest part of the ground, which is exactly what the ceiling forbids.
    static let ambientReach: CGFloat = 240
    /// How far the radial reaches, as a multiple of `ambientReach`. Kept under
    /// ~1.3 so the wash has faded to roughly half by the first content row: the
    /// strong region is the header block, not the page.
    static let ambientReachScale: CGFloat = 1.25

    /// Which appearance the wash is being computed for.
    ///
    /// Passed explicitly rather than read from the ambient drawing appearance:
    /// the two appearances need *opposite* treatment (the dark ground is
    /// brightened, the light ground tinted), so a call that silently picked the
    /// wrong one would look plausible and be wrong. Being a parameter also makes
    /// both branches testable on any machine.
    enum CompanionAppearance { case dark, light }

    /// The appearance being drawn right now.
    static var currentAppearance: CompanionAppearance {
        isLightAppearance ? .light : .dark
    }

    /// The window ground in each appearance, as explicit sRGB components.
    ///
    /// Resolved here rather than read from the dynamic `NSColor` so both
    /// appearances can be reasoned about — and tested — deterministically.
    /// The light value is `CompanionPalette.canvas`’ own light constant; the
    /// dark value is `NSColor.windowBackgroundColor` in dark mode (measured
    /// against the running app at 30–34/255).
    static let canvasRGBDark: [Double] = [30.0 / 255, 30.0 / 255, 30.0 / 255]
    static let canvasRGBLight: [Double] = [248.0 / 255, 250.0 / 255, 249.0 / 255]

    static func canvasRGB(for appearance: CompanionAppearance) -> [Double] {
        appearance == .light ? canvasRGBLight : canvasRGBDark
    }

    /// A tint over near-white reads several times stronger than the same tint
    /// over near-black, so the light appearance gets a fraction of the alpha.
    ///
    /// Without this the two appearances would be normalised to the same
    /// *measured* spread, which is the opposite of the same *perceived* one.
    static let lightAppearanceTintScale: Double = 0.38

    /// Floor for the light ground: how dark the wash may make it before the
    /// dark text sitting on it stops passing AA.
    ///
    /// Solved the same way as the dark ceiling, from the text that actually
    /// sits on the wash. On light, that text is the ordinary `.secondary`
    /// (see `onWashSecondary`), whose resolved grey is ~0.42 sRGB.
    static var lightAppearanceGroundFloor: Double {
        let text = relativeLuminance([0.42, 0.42, 0.42])
        return (text + 0.05) * aaNormalText - 0.05
    }

    /// Alpha that makes *this* accent land on the target wash strength.
    ///
    /// A flat alpha would not do: what the eye reads as "the room changed" is
    /// the ground’s channel *spread*, and the accents do not share one.
    /// Jade spans 97/255 across its channels, the amber 179/255, so the same
    /// alpha gave the amber page a wash more than twice as strong as the jade
    /// one — measured at 30.9 vs 13.8. Dividing by the accent’s own spread
    /// is what makes switching modules read as the same amount of change.
    ///
    /// The result is then clamped by the luminance budget, so a module can
    /// never tint itself into an unreadable header. Both constraints are real:
    /// without the first the modules do not match each other, without the
    /// second they do not match the text.
    static func ambientAlpha(
        for tint: Color,
        intensity: Double,
        appearance: CompanionAppearance = currentAppearance
    ) -> Double {
        let spread = channelSpread(of: tint)
        guard spread > 0.02 else { return 0 }
        let appearanceScale = appearance == .light ? lightAppearanceTintScale : 1
        let forSpread = ambientTint * intensity * (referenceChannelSpread / spread) * appearanceScale
        let forLuminance = alphaWithinLuminanceBudget(
            for: tint, intensity: intensity, appearance: appearance
        )
        return min(forSpread, forLuminance)
    }

    /// The alpha at which compositing the tint over the canvas brings the ground
    /// to its readability limit — and the reason this is appearance-aware.
    ///
    /// The two appearances move in opposite directions: on the dark canvas the
    /// wash *brightens* the ground and is capped by a ceiling, on the light one
    /// it *tints/tints down* and is capped by a floor. The first version only
    /// knew about the ceiling and guarded on
    /// `relativeLuminance(tint) > relativeLuminance(canvas)` — which is false
    /// for every accent against a near-white canvas, so the function returned 0
    /// and **the light appearance had no module wash at all**. The feature was
    /// silently absent in half the appearances.
    ///
    /// Solved numerically: the composite is a per-channel sRGB mix and luminance
    /// is a 2.4-power curve on top of it, so there is no clean closed form.
    /// Bisection converges in ~24 steps and this runs once per render.
    static func alphaWithinLuminanceBudget(
        for tint: Color,
        intensity: Double,
        appearance: CompanionAppearance
    ) -> Double {
        let base = canvasRGB(for: appearance)
        let top = resolveRGB(tint)
        let baseLum = relativeLuminance(base)
        let topLum = relativeLuminance(top)

        // The direction the wash is allowed to move the ground.
        let bound: Double
        switch appearance {
        case .dark:
            bound = min(ambientPeakGroundLuminance * intensity, ambientLuminanceCeiling)
            guard topLum > baseLum, bound > baseLum else { return 0 }
        case .light:
            bound = max(lightAppearanceGroundFloor, 0)
            guard topLum < baseLum, bound < baseLum else { return 0 }
        }

        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let blended = zip(base, top).map { $0 * (1 - mid) + $1 * mid }
            let lum = relativeLuminance(blended)
            // Dark: stop *below* the ceiling. Light: stop *above* the floor.
            let stillWithin = appearance == .dark ? lum < bound : lum > bound
            if stillWithin { low = mid } else { high = mid }
        }
        return low
    }

    /// sRGB components in 0...1. Falls back to mid-grey if a colour cannot be
    /// resolved, which makes the budget conservative rather than unbounded.
    /// Scheme-aware colours resolve under `appearance` when given — tests
    /// must pin one or a system light/dark flip changes the result.
    static func resolveRGB(_ color: Color, appearance: NSAppearance? = nil) -> [Double] {
        if let appearance {
            var resolved: [Double] = [0.5, 0.5, 0.5]
            appearance.performAsCurrentDrawingAppearance {
                if let ns = NSColor(color).usingColorSpace(.sRGB) {
                    resolved = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
                }
            }
            return resolved
        }
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let ns else { return [0.5, 0.5, 0.5] }
        return [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
    }

    /// WCAG relative luminance.
    static func relativeLuminance(_ rgb: [Double]) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        guard rgb.count == 3 else { return 0 }
        return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
    }

    /// WCAG contrast ratio between two composited colours.
    static func contrastRatio(_ a: [Double], _ b: [Double]) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Channel spread of the jade accent, the value the band above was tuned
    /// against. Every other module is normalised to it.
    static let referenceChannelSpread: Double = channelSpread(of: CompanionPalette.jade)

    /// max(R,G,B) - min(R,G,B) of a colour, in 0...1.
    static func channelSpread(of color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        let v = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
        return (v.max() ?? 0) - (v.min() ?? 0)
    }
}

/// The window ground.
///
/// Canvas plus a single quiet jade wash under the title. Every page shares
/// this atmosphere so switching tabs does not recolour the room. Colour is
/// for meaning (the one accent, plus red/orange when something needs action),
/// not for naming modules.
struct CompanionBackdrop: View {
    /// Brand accent. Drives the wash; the base stays the canvas colour.
    var tint: Color = CompanionPalette.jade
    /// Extra emphasis for surfaces that own the whole window (onboarding,
    /// the guide) versus a settings page that wants to stay quiet.
    var intensity: Double = 1

    /// The primary wash alpha, normalised per accent so every module lands on
    /// the same perceived strength.
    private var primaryAlpha: Double {
        CompanionElevation.ambientAlpha(for: tint, intensity: intensity)
    }

    /// The full-height base pass, a fraction of the primary.
    private var baseAlpha: Double {
        primaryAlpha * CompanionElevation.ambientBaseTint
    }

    var body: some View {
        ZStack(alignment: .top) {
            CompanionPalette.canvas
            if !CompanionMotion.reduceTransparency {
                // Full-height base: a whisper of the module colour that
                // survives next to the densest part of a list, so the wash
                // does not stop abruptly at the header.
                LinearGradient(
                    colors: [
                        tint.opacity(baseAlpha),
                        tint.opacity(baseAlpha * 0.5),
                        tint.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                // Warm pool of accent light under the page header.
                RadialGradient(
                    colors: [
                        tint.opacity(primaryAlpha),
                        tint.opacity(0.0)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: CompanionElevation.ambientReach * CompanionElevation.ambientReachScale
                )
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The face of a card: lit from above, seated in a soft shadow.
///
/// Used by `CompanionSurface` so the whole app's existing cards gain the
/// language at once instead of being re-plumbed one call site at a time.
struct CompanionCardFace: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var tint: Color?

    /// The card's whole outline and ramp come from `CompanionAccessibility`
    /// statics, which establish no SwiftUI dependency on their own. Reading
    /// the generation here is what makes an Increase Contrast flip reach every
    /// card in the app instead of only the ones that happen to redraw.
    @Environment(\.companionDisplayGeneration) private var displayGeneration

    func body(content: Content) -> some View {
        let _ = displayGeneration
        return content
            .padding(padding)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: CompanionMotion.reduceTransparency ? .clear : CompanionElevation.cardShadow,
                radius: CompanionElevation.cardShadowRadius,
                y: CompanionElevation.cardShadowY
            )
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if CompanionMotion.reduceTransparency {
            shape.fill(CompanionPalette.surface)
        } else {
            // A shallow luminance ramp across the face. Flat fills read as
            // paper; a gradient this shallow reads as a surface catching
            // light. The direction is scheme-aware because the two schemes
            // have different headroom: on the dark canvas a card can only get
            // *lighter* at the top, while on the light canvas it is already
            // near white, so the lift there comes from the card sitting
            // brighter than the canvas plus a darker bottom edge.
            shape.fill(CompanionPalette.surface)
            shape.fill(
                LinearGradient(
                    colors: CompanionElevation.faceRamp,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            if let tint {
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(0.10), tint.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.6, y: 0.8)
                    )
                )
            }
        }
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = CompanionAccessibility.cardEdgeWidth
        return shape
            .strokeBorder(CompanionPalette.border, lineWidth: edge)
            .overlay(
                // The lit edge: a hairline that is white along the top and
                // fades to nothing by mid-height. Stroking the border with a
                // vertical gradient does that without cutting the outline into
                // a partial path, which left a visible seam where the trim
                // started and ended.
                shape.strokeBorder(
                    LinearGradient(
                        colors: CompanionElevation.edgeRamp,
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: edge
                )
                .opacity(CompanionMotion.reduceTransparency ? 0 : 1)
            )
            .allowsHitTesting(false)
    }
}

extension View {
    /// The house card. Padding defaults to the workspace's 20pt gutter.
    func companionCardFace(
        padding: CGFloat = 20,
        radius: CGFloat = CompanionElevation.cardRadius,
        tint: Color? = nil
    ) -> some View {
        modifier(CompanionCardFace(padding: padding, radius: radius, tint: tint))
    }

    /// The same face for a container that manages its own padding and radius.
    ///
    /// Analytics and report pages lay out their panels with
    /// `.background(...).cornerRadius(n)` next to a separately applied
    /// `.padding(...)`. This is the drop-in for those call sites: it swaps a
    /// flat fill for the lit face without touching their layout.
    func companionPanelFace(
        radius: CGFloat = CompanionElevation.insetRadius,
        tint: Color? = nil
    ) -> some View {
        modifier(CompanionCardFace(padding: 0, radius: radius, tint: tint))
    }

    /// Play this view in as the index-th member of a group.
    ///
    /// Used on page content so a tab switch assembles rather than appearing
    /// in one frame. The view starts slightly low and transparent, then
    /// settles. The delay is capped because a sixth-row card should not wait
    /// on a seventh that will never come.
    ///
    /// Reduce Motion removes the movement entirely and leaves the content
    /// present, rather than making the whole group appear at once after a
    /// delay.
    func companionStagger(index: Int, rise: CGFloat = CompanionMotion.staggerRise) -> some View {
        modifier(CompanionStaggerModifier(index: index, rise: rise))
    }

    /// Supporting text that sits *on the module wash* rather than on a card.
    ///
    /// One step brighter than the ordinary secondary style, because the wash
    /// raises the ground’s luminance and ordinary secondary stops clearing AA
    /// on it. Applying this is what lets the wash be strong enough to read as a
    /// room colour instead of a rumour — see `onWashTextOpacity` for the
    /// arithmetic that ties the two together.
    ///
    /// Scheme-aware: the dark canvas needs a *brighter* step than the standard
    /// secondary, while the light canvas is already near white and needs the
    /// ordinary dark secondary instead. A hardcoded white here rendered
    /// invisible text on the light appearance.
    func onWashSecondary() -> some View {
        modifier(OnWashSecondaryModifier())
    }
}

private struct OnWashSecondaryModifier: ViewModifier {
    func body(content: Content) -> some View {
        if CompanionElevation.isLightAppearance {
            content.foregroundStyle(.secondary)
        } else {
            content.foregroundStyle(Color.white.opacity(CompanionElevation.onWashTextOpacity))
        }
    }
}

private struct CompanionStaggerModifier: ViewModifier {
    let index: Int
    let rise: CGFloat
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(CompanionMotion.reduceMotion ? 1 : (arrived ? 1 : 0))
            .offset(y: CompanionMotion.reduceMotion ? 0 : (arrived ? 0 : rise))
            .animation(CompanionMotion.staggerEntrance(index: index), value: arrived)
            .onAppear { arrived = true }
    }
}

/// A card that responds to the pointer.
///
/// The lift is 1pt and the shadow change is small on purpose: at list density
/// a bigger move makes every pointer crossing a page look like it is twitching.
/// What the user should register is "this is a thing I can act on", not
/// "something moved".
struct CompanionHoverCard<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = CompanionElevation.cardRadius
    var tint: Color? = nil
    /// Off for cards whose whole face is already a button (the button supplies
    /// its own press feedback), on for containers that merely highlight.
    var lifts: Bool = true
    @ViewBuilder var content: () -> Content

    @State private var hovered = false

    var body: some View {
        content()
            .companionCardFace(padding: padding, radius: radius, tint: hovered ? (tint ?? CompanionPalette.jade) : tint)
            .scaleEffect(hovered && lifts && !CompanionMotion.reduceMotion ? 1.004 : 1, anchor: .center)
            .offset(y: hovered && lifts && !CompanionMotion.reduceMotion ? -CompanionElevation.hoverLift : 0)
            .shadow(
                color: hovered && lifts && !CompanionMotion.reduceTransparency ? CompanionElevation.hoverShadow : .clear,
                radius: CompanionElevation.hoverShadowRadius,
                y: CompanionElevation.hoverShadowY
            )
            .onHover { hovered = $0 }
            .companionAnimation(CompanionMotion.cardHover(), value: hovered)
    }
}

/// A page section header: label, optional count, optional trailing action.
///
/// Section titles used to be set inline at each call site, so the same
/// "接下来 2 项" line was 11pt here and 13pt there. One component, one voice.
struct CompanionSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Small tinted capsule after the title — a count, usually.
    var badge: String? = nil
    var tint: Color = CompanionPalette.accent
    @ViewBuilder var trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        tint: Color = CompanionPalette.accent,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.tint = tint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .workspaceTitle()
                .foregroundStyle(.primary)
            if let badge {
                Text(badge)
                    .workspaceMicro()
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.11), in: Capsule())
            }
            if let subtitle {
                Text(subtitle)
                    .workspaceMeta()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CompanionSectionHeader where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        tint: Color = CompanionPalette.accent
    ) {
        self.init(title, subtitle: subtitle, badge: badge, tint: tint) { EmptyView() }
    }
}

/// The one action that moves things forward, lit.
///
/// A filled jade capsule for the rare next step (onboarding continue).
/// The halo is a whisper: a lantern on every page header made the chrome
/// louder than the work. Prefer a system bordered-prominent button unless
/// the action is the only thing on the screen.
struct CompanionGlowButtonStyle: ButtonStyle {
    var tint: Color = CompanionPalette.jade
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                tint.opacity(configuration.isPressed ? 0.86 : 1),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(
                color: CompanionMotion.reduceTransparency
                    ? .clear
                    : tint.opacity(configuration.isPressed ? 0.14 : 0.22),
                radius: configuration.isPressed ? 4 : 6,
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(
                configuration.isPressed && !CompanionMotion.reduceMotion ? CompanionMotion.pressScale : 1
            )
            .animation(CompanionMotion.press(), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CompanionGlowButtonStyle {
    static var companionGlow: CompanionGlowButtonStyle { CompanionGlowButtonStyle() }
    static var companionGlowCompact: CompanionGlowButtonStyle {
        CompanionGlowButtonStyle(compact: true)
    }
}

/// A live status light: a tinted dot with a soft halo that breathes while the
/// underlying process is working.
///
/// Static dots can only say "good / bad". The pulse says "in progress" without
/// a spinner, which matters on the status bar where a spinner would fight the
/// text next to it. Under reduce-motion the halo is replaced by a steady ring.
///
/// Under **Differentiate Without Color** the three levels stop being the same
/// circle in three hues and become three silhouettes — solid disc, ring,
/// diamond. HIG is explicit that colour alone must never carry meaning, and a
/// dot whose entire payload is its hue is the textbook violation. The shapes
/// only appear when the switch is on, so the default rendering is byte-for-byte
/// what it was before this existed.
struct CompanionStatusDot: View {
    /// What the light means, independent of what colour it is.
    enum Level: CaseIterable {
        /// Connected / healthy.
        case ok
        /// In progress. Also the neutral "nothing to report" light.
        case working
        /// Needs the user: failure, stale data, a switched account.
        case attention

        /// The outline a level is drawn with.
        enum Silhouette {
            /// A filled circle — the default for every level.
            case disc
            /// A hollow circle: same footprint, half the ink.
            case ring
            /// A square stood on its corner.
            case diamond
        }

        /// Resolved against the live switch, so the token and the view can
        /// never disagree about whether shapes are doing the work.
        var silhouette: Silhouette {
            guard CompanionAccessibility.differentiateWithoutColor else { return .disc }
            switch self {
            case .ok: return .disc
            case .working: return .ring
            case .attention: return .diamond
            }
        }
    }

    var tint: Color
    var level: Level = .working
    var pulsing: Bool = false
    var size: CGFloat = 8

    @State private var phase: Double = 0
    /// The silhouette is chosen from an accessibility static, so the dot has
    /// to depend on the generation to redraw when the switch moves.
    @Environment(\.companionDisplayGeneration) private var displayGeneration

    var body: some View {
        let _ = displayGeneration
        return ZStack {
            if pulsing {
                Circle()
                    .fill(tint.opacity(0.30))
                    .frame(width: size * 2.1, height: size * 2.1)
                    .scaleEffect(CompanionMotion.reduceMotion ? 1 : (1 + phase * 0.32))
                    .opacity(CompanionMotion.reduceMotion ? 0.5 : (0.62 - phase * 0.32))
            }
            mark
                .frame(width: size, height: size)
                .overlay(edge)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: pulsing) { _, _ in startPulseIfNeeded() }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch level.silhouette {
        case .disc:
            Circle().fill(tint)
        case .ring:
            Circle().strokeBorder(tint, lineWidth: max(1.5, size * 0.26))
        case .diamond:
            Rectangle()
                .fill(tint)
                .frame(width: size * 0.82, height: size * 0.82)
                .rotationEffect(.degrees(45))
        }
    }

    /// Hairline that keeps the light from melting into a dark ground. A
    /// diamond has four straight edges already and needs no ring.
    @ViewBuilder private var edge: some View {
        if level.silhouette == .diamond {
            EmptyView()
        } else {
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
        }
    }

    private func startPulseIfNeeded() {
        guard pulsing, !CompanionMotion.reduceMotion else { phase = 0; return }
        withMotion(CompanionMotion.pulse()) { phase = 1 }
    }
}

/// A quiet glyph mark for section headers that still want a small icon.
///
/// The sidebar itself no longer uses this: macOS sidebars are SF Symbols in
/// the app accent, not a wall of saturated squares. Cards that need a
/// leading mark (the guide) keep a glyph on a faint wash so they still
/// belong to the same language without shouting.
struct CompanionModuleTile: View {
    let systemImage: String
    let tint: Color
    var selected: Bool = false
    var hovered: Bool = false
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected || hovered ? tint : Color.secondary)
            .frame(width: size, height: size)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                shape.fill(tint.opacity(selected ? 0.16 : (hovered ? 0.10 : 0.06)))
            }
            .accessibilityHidden(true)
    }
}
