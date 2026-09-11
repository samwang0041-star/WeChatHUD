import SwiftUI

/// Type and spacing tokens for the external HUD — the pill, the hover
/// inbox, the task preview and the notification banner that live in the
/// island panel.
///
/// Why this exists: the island surfaces had grown to 24pt bold headlines,
/// 16pt brand text and 15pt row titles on a 560pt-wide panel, with each row
/// reserving 88pt for two lines of content. On macOS that reads as a
/// toy — the same information in Mail, Messages, Linear or Raycast sits at
/// 11–13pt. Everything here is one step down and one step tighter, defined
/// once so the four surfaces cannot drift apart again.
///
/// These replace ad-hoc `.font(.system(size:))` calls in the island views.
/// Use the modifiers, not the raw numbers, so a future rescale stays a
/// one-file change.
enum IslandType {
    /// Count headline ("现在有 3 件事需要你"). Was 24 bold.
    static let display: CGFloat = 15
    /// Brand name in the banner / empty state.
    static let brand: CGFloat = 13.5
    /// Row title: contact or conversation name. Was 15.
    static let rowTitle: CGFloat = 13
    /// Message body / AI summary inside a row. Was 14.
    static let rowBody: CGFloat = 12
    /// Buttons and inline actions. Was 15.
    static let button: CGFloat = 12
    /// Section labels ("需要你处理", "已处理 (3)").
    static let section: CGFloat = 11.5
    /// Timestamps, sync state, secondary affordances. Was 12.
    static let meta: CGFloat = 11
    /// Badges, status chips, the compact pill's count.
    static let micro: CGFloat = 10.5
}

/// Spacing and sizing for the external HUD. A row's height is
/// `avatar + 2 * rowPadding`; the inbox's measured height is derived from
/// these numbers, so changing them here resizes the panel to match.
enum IslandMetrics {
    /// Vertical padding above/below a row's content.
    static let rowPadding: CGFloat = 9
    /// Leading/trailing inset for row content.
    static let rowInset: CGFloat = 14
    /// Circular contact monogram in the inbox list. Was 36.
    static let avatar: CGFloat = 26
    /// Height one row contributes to the inbox size estimate. Measured
    /// 51pt for a two-line row (contact title + summary/preview), which is
    /// what the inbox list renders — the avatar alone would suggest 44.
    /// `HUDRootView.inboxSize` multiplies this, so it has to match reality
    /// or the panel opens short and corrects itself a frame later.
    static let rowHeight: CGFloat = 51
    /// Pill buttons in the bottom bar / banner.
    static let buttonHeight: CGFloat = 26
    static let buttonInset: CGFloat = 13
    /// The small companion mark in the workspace bar.
    static let buddy: CGFloat = 18
    /// Inset for section headers and dividers so they line up with rows.
    static let sectionInset: CGFloat = 14
}

/// Text colours for the island. One ramp, because the surfaces had drifted
/// into six different white opacities (0.25 / 0.35 / 0.45 / 0.55 / 0.65 /
/// 0.9) with no rule about which meant what.
enum IslandInk {
    /// Titles and primary content.
    static let primary = Color.white.opacity(0.92)
    /// Message previews, AI summaries, explanatory text.
    static let secondary = Color.white.opacity(0.66)
    /// Timestamps, sync state, hints.
    static let tertiary = Color.white.opacity(0.42)
    /// Disabled / decorative chrome (chevrons, collapsed counts).
    static let quaternary = Color.white.opacity(0.26)
    /// Hairlines and dividers.
    static let divider = Color.white.opacity(0.07)
    /// Row hover wash.
    static let hover = Color.white.opacity(0.05)
    /// Neutral chip / inline control fill. A bordered control needs more
    /// presence than a row hover, and expressing it as white alpha (rather
    /// than a multiple of `hover`) keeps it readable on its own.
    static let chip = Color.white.opacity(0.10)
    /// Emphasised neutral chip — the cached-snippet variant of the same control.
    static let chipStrong = Color.white.opacity(0.12)
    /// Pressed state for a neutral pill — one step brighter than `hover`.
    /// (Expressed directly: `opacity(1.6)` would silently clamp to 1.)
    static let hoverPressed = Color.white.opacity(0.10)
    /// Grouped footer / bar background.
    static let bar = Color.white.opacity(0.03)
}

extension View {
    func islandDisplay() -> some View { companionFont(size: IslandType.display, weight: .semibold) }
    func islandBrand() -> some View { companionFont(size: IslandType.brand, weight: .semibold) }
    func islandRowTitle() -> some View { companionFont(size: IslandType.rowTitle, weight: .semibold) }
    func islandRowBody() -> some View { companionFont(size: IslandType.rowBody) }
    func islandButton() -> some View { companionFont(size: IslandType.button, weight: .medium) }
    func islandSection() -> some View { companionFont(size: IslandType.section, weight: .semibold) }
    func islandMeta() -> some View { companionFont(size: IslandType.meta) }
    func islandMicro() -> some View { companionFont(size: IslandType.micro, weight: .medium) }
}

/// Pill button used by the extended inbox's bottom bar and the notification
/// banner. Primary = the one action that moves things forward.
struct IslandPillButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .islandButton()
            .foregroundStyle(emphasized ? Color.white : IslandInk.primary)
            .padding(.horizontal, IslandMetrics.buttonInset)
            .padding(.vertical, 7)
            .background(
                emphasized
                    ? CompanionPalette.jade.opacity(configuration.isPressed ? 0.82 : 1)
                    : (configuration.isPressed ? IslandInk.hoverPressed : IslandInk.hover),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}
