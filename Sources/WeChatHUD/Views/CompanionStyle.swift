import SwiftUI

/// 青玉 visual language from the 不漏事 design spec.
enum CompanionPalette {
    /// #16776C — primary actions, current selection, confirmed results.
    static let jade = Color(red: 22 / 255, green: 119 / 255, blue: 108 / 255)
    /// Sidebar mist. Follows the color scheme.
    ///
    /// This is a *surface*, so it has to track the scheme the way `canvas` and
    /// `surface` already do. As a fixed light color it sat under labels drawn
    /// with `.primary`, which resolves to white in dark mode — a white plate
    /// with white text, measured 1.05:1 against #F3F5F4 in the reported
    /// screenshot. The dark value keeps the light design's relationship to the
    /// canvas (a few steps darker), so the two panes still read as separate.
    static let mist = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.09, alpha: 1)
            : NSColor(red: 240 / 255, green: 243 / 255, blue: 242 / 255, alpha: 1)
    })
    /// Selected row / pill wash. Stays readable when Reduce Transparency is on.
    static var selectedFill: Color {
        jade.opacity(CompanionMotion.reduceTransparency ? 0.28 : 0.16)
    }
    /// Sidebar current page — light jade wash + leading bar, not system black.
    static var sidebarSelectedFill: Color {
        jade.opacity(CompanionMotion.reduceTransparency ? 0.24 : 0.14)
    }
    /// Hardware Dynamic Island is pure black. Collapsed wings use this
    /// so they fuse with the notch instead of sitting as a charcoal plate.
    static let island = Color.black
    /// #82D3BC — island accent.
    static let islandMint = Color(red: 130 / 255, green: 211 / 255, blue: 188 / 255)

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.51, green: 0.83, blue: 0.74, alpha: 1)
            : NSColor(red: 22 / 255, green: 119 / 255, blue: 108 / 255, alpha: 1)
    })

    /// Jade for **text and glyphs**, as opposed to `jade` for **fills**.
    ///
    /// `jade` (#16776C) is a light-appearance colour. Used as a fill it is
    /// correct in both schemes — white label text on it measures ~5.5:1. Used
    /// as *text* on a dark card it is not: measured on the shipped build, the
    /// 已就绪 / 设置 AI / 查看待确认回复 labels painted `rgb(56,117,108)` on
    /// `#1F1F1F`, which is **3.08:1** against the 4.5:1 AA floor, while every
    /// body text on the same cards measured 5.9–12.3:1. The accent tier was the
    /// only illegible one.
    ///
    /// This is a name for the existing scheme-aware accent, not a new colour:
    /// `ui-language.md` v3 already settled that the workspace has exactly one
    /// accent, and `accent` already resolves to the mint (≈9:1 on the same
    /// surface) in dark mode. The 42 `foregroundStyle(CompanionPalette.jade)`
    /// call sites were the last holdouts of the pre-v3 palette.
    static var jadeInk: Color { accent }
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor(red: 248 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
    })
    /// Card and control outline.
    ///
    /// 7.5 % of the label colour is the tuned default; under **Increase
    /// Contrast** it steps up to the weight `NSColor.separatorColor` uses in
    /// its own increased-contrast variant, so this window stops being the
    /// faintest thing on a screen where every other app deepened its edges.
    /// See `CompanionAccessibility`.
    static var border: Color {
        Color.primary.opacity(CompanionAccessibility.contrastAdjusted(0.075))
    }
    static let secondarySurface = Color.primary.opacity(0.035)

    /// Inset sub-panel outline: one step lighter than `border`.
    static var insetBorder: Color {
        Color.primary.opacity(CompanionAccessibility.contrastAdjusted(0.055))
    }
}

private struct CompanionSurface: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .companionCardFace(padding: padding, radius: CompanionElevation.cardRadius)
    }
}

/// Type tokens for the workspace window — settings, today, tasks, reports.
///
/// Same native-small band as the island: page titles may reach 17pt, row
/// titles sit at 13, and nothing readable goes below 10. These replace the
/// 22–30pt headlines that made the workspace read as a phone app.
enum WorkspaceType {
    /// Page title ("今天", "待办"). Was 30.
    static let display: CGFloat = 17
    /// Section / card titles.
    static let title: CGFloat = 15
    /// Row titles, matching the island.
    static let rowTitle: CGFloat = 13
    /// Body copy and supporting sentences.
    static let body: CGFloat = 12
    /// Timestamps, hints, sidebar section labels.
    static let meta: CGFloat = 11
    /// Badges and micro chrome. Floor of companionFont is 10.
    static let micro: CGFloat = 10.5
}

/// Scales hardcoded chrome sizes when the system (or preview) asks for larger type.
enum CompanionTypeScale {
    /// The band this app's text is allowed to occupy.
    ///
    /// Both ends are deliberate, and both are HIG requirements rather than
    /// taste:
    ///
    /// - **Floor `.large`.** Every measurement in `ui-language.md` — the 36pt
    ///   compact bar, the 560/580pt panel widths, the card gutters — was taken
    ///   at the system default. Rendering below it would clip the island's
    ///   fixed-height chrome, so a user who set a *smaller* system size gets
    ///   the design size instead.
    /// - **Ceiling `.accessibility2`.** This is the largest step that has been
    ///   verified against the real pages (it is what the preview's 大字号
    ///   toggle drives). Above it the two-column pages have nowhere to put
    ///   their inspector.
    ///
    /// The important part is what it *stops* doing. This used to be
    /// `.dynamicTypeSize(.large)`, a hard pin: a user who set 文字大小 to
    /// "更大" in 系统设置 got no change at all, in an app whose own preview
    /// ships a 大字号 button proving the layout can take it. Pinning to the
    /// default is indistinguishable from ignoring the setting.
    static let range: ClosedRange<DynamicTypeSize> = .large ... .accessibility2

    /// The size to pin in preview, so the two ends of the band are reachable
    /// from a repeatable launch instead of by changing the host Mac's settings.
    static var previewSize: DynamicTypeSize { range.upperBound }

    /// The band to hand to `.dynamicTypeSize(_:)` for a given preview toggle.
    ///
    /// `dynamicTypeSize` has two overloads — a single `DynamicTypeSize` and a
    /// `ClosedRange<DynamicTypeSize>` — so a bare `largeType ? previewSize :
    /// range` ternary does not type-check, and spelling the band out at each
    /// call site is exactly how the two of them would drift apart. One
    /// function, both callers.
    static func appliedRange(largeType: Bool) -> ClosedRange<DynamicTypeSize> {
        largeType ? previewSize ... previewSize : range
    }

    static func factor(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.88
        case .small: return 0.94
        case .medium: return 0.97
        case .large: return 1.0
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.24
        case .accessibility1: return 1.35
        case .accessibility2: return 1.48
        case .accessibility3: return 1.62
        case .accessibility4: return 1.76
        case .accessibility5: return 1.90
        @unknown default: return 1.0
        }
    }
}

/// A fixed chrome width, scaled with the type — the width twin of
/// `companionFont`. A box measured at the default type size squeezes its ×1.48
/// contents at 大字号, and the outvoted overflow shows up as clipped glyphs at
/// the window edge (§77's 「全部」 kept getting cut). Hit-target squares stay
/// fixed on purpose: pass those to plain `.frame`.
private struct CompanionScaledWidth: ViewModifier {
    let width: CGFloat
    var alignment: Alignment = .center
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.frame(width: width * CompanionTypeScale.factor(for: typeSize), alignment: alignment)
    }
}

private struct CompanionScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    /// Passed through so `.monospaced` / `.rounded` call sites can scale too —
    /// routing a design through a plain weight-only scaler silently restyled
    /// it, which is why the 14 `.monospaced` sites stayed hardcoded for so long.
    var design: Font.Design = .default
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let scaled = max(10, (size * CompanionTypeScale.factor(for: typeSize)).rounded())
        // `.default` keeps the two-argument call this modifier always made;
        // measured at the default type size the three-argument form moves
        // fewer than 75 pixels, but the legacy call shape costs nothing to
        // keep. The 723 converted call sites do leave a 0.14% glyph-antialias
        // scatter at default (same metrics, same layout) — their old
        // one-argument `.system(size:)` form rasterizes a hair differently
        // from this explicit-weight path.
        return content.font(design == .default
            ? .system(size: scaled, weight: weight)
            : .system(size: scaled, weight: weight, design: design))
    }
}

extension View {
    func companionSurface(padding: CGFloat = 20) -> some View {
        modifier(CompanionSurface(padding: padding))
    }

    func companionFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(CompanionScaledFont(size: size, weight: weight, design: design))
    }

    /// Fixed chrome width that grows with Dynamic Type. See `CompanionScaledWidth`.
    func companionScaledWidth(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(CompanionScaledWidth(width: width, alignment: alignment))
    }

    func workspaceDisplay() -> some View { companionFont(size: WorkspaceType.display, weight: .semibold) }
    func workspaceTitle() -> some View { companionFont(size: WorkspaceType.title, weight: .semibold) }
    func workspaceRowTitle() -> some View { companionFont(size: WorkspaceType.rowTitle, weight: .semibold) }
    func workspaceBody() -> some View { companionFont(size: WorkspaceType.body) }
    func workspaceMeta() -> some View { companionFont(size: WorkspaceType.meta) }
    func workspaceMicro() -> some View { companionFont(size: WorkspaceType.micro, weight: .medium) }

    /// Hide and disable chrome behind an in-window dialog so Tab cannot leave it.
    func companionDimmedByDialog(_ open: Bool) -> some View {
        disabled(open).accessibilityHidden(open)
    }

    /// Disabled because work is in flight. Pass the same sentence the
    /// in-progress primary already uses, so Cancel is not a mute grey control.
    func companionBusyHold(_ active: Bool, _ reason: String) -> some View {
        disabled(active)
            .help(active ? reason : "")
            .accessibilityHint(active ? reason : "")
    }

    /// Background stays in the tree but is not in the Tab / VoiceOver loop while the dialog is up.
    func companionDialogBackdrop<Dialog: View>(
        _ presented: Bool,
        @ViewBuilder dialog: () -> Dialog
    ) -> some View {
        ZStack {
            self.companionDimmedByDialog(presented)
            if presented { dialog() }
        }
        .animation(CompanionMotion.dialog(), value: presented)
    }
}

struct CompanionBadge: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = CompanionPalette.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .workspaceMicro()
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(tint.opacity(0.09), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

struct CompanionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            // 0.96, not 0.99. A press must register as a press: below ~0.97
            // the surface visibly gives under the cursor, above it the label
            // just gains a faint wash. 0.92–0.97 is the band where a button
            // feels responsive without going rubbery — see codex-island's
            // PressableButtonStyle, Emil Kowalski's press-feedback rule.
            .scaleEffect(configuration.isPressed && !CompanionMotion.reduceMotion ? CompanionMotion.pressScale : 1)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
            .animation(CompanionMotion.press(), value: configuration.isPressed)
    }
}

/// Full-width selection rows. Scale reads as rubber on a strip that already
/// has a hover wash; opacity is the press.
struct CompanionRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
            .animation(CompanionMotion.press(), value: configuration.isPressed)
    }
}

extension View {
    /// A stock `DisclosureGroup` label draws at glyph height (15–16pt) —
    /// under the 24pt hit floor the HIG audit measures. This fills the row
    /// without moving the text.
    func companionDisclosureLabel() -> some View {
        frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// 22pt toolbar glyphs on the workspace. Island icons use IslandInk; these
/// use primary wash so a light canvas still shows a halo.
struct CompanionIconButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.10)
                          : (hovered ? Color.primary.opacity(0.055) : Color.clear))
            )
            .scaleEffect(configuration.isPressed && !CompanionMotion.reduceMotion ? CompanionMotion.pressScale : 1)
            .onHover { hovered = $0 }
            .animation(CompanionMotion.hover(), value: hovered)
            .animation(CompanionMotion.press(), value: configuration.isPressed)
    }
}

struct CompanionFilterPill: View {
    let title: String
    let selected: Bool
    /// Brand accent. A selected filter is the current view, not a primary
    /// action, so it uses a quiet wash rather than a filled glowing capsule.
    var tint: Color = CompanionPalette.jade
    let action: () -> Void

    var body: some View {
        // Tens/day filters: press is the feedback; do not wrap the action in
        // pageChange (160ms). The selected wash uses the 100ms hover band.
        Button(action: action) {
            Text(title)
                .companionFont(size: WorkspaceType.rowTitle, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? tint : .primary)
                // A pill is one line.
                //
                // Measured defect: at the window's own 900pt minimum the 待办
                // filter row ran out of width and SwiftUI wrapped the labels
                // *inside* their capsules — 「我要做」 over two lines, then
                // 「共同推进」 and 「信息备忘」. A wrapped pill reads as a broken
                // control.
                //
                // One line, and explicitly NOT `fixedSize`: that is what a
                // first attempt used, and at the same width it threw inside
                // AppKit's layout pass (`_NSViewLayout` → SIGTRAP, exit 133),
                // taking the whole 待办 page down at launch (the launch smoke in
                // WorkspacePageLaunchSurvivalTests reproduces it). `lineLimit`
                // only changes how the text draws — it never removes the view's
                // ability to be laid out in less space — so a tight row gives
                // up its trailing controls instead of crashing.
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? tint.opacity(0.16) : CompanionPalette.surface, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        selected ? tint.opacity(0.28) : CompanionPalette.border,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(CompanionPressStyle())
        .companionAnimation(CompanionMotion.hover(), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The batch-clear affordance at the trailing end of a filter row.
///
/// It shows its label while the row has room and drops to just the glyph when
/// it does not. The reason is measured, not aesthetic: at the window's own
/// 900pt minimum a *labelled* button left the 待办 filter pills too little
/// width, and SwiftUI wrapped 「我要做」·「共同推进」·「信息备忘」 each onto two
/// lines — a wrapped pill row reads as a broken page. `ViewThatFits` picks the
/// glyph form instead, and the glyph keeps the tooltip and the accessibility
/// label, so the only thing that changes is how much room it takes.
struct CompanionBatchClearButton: View {
    var title: String = "一键清空"
    /// Tooltip. Says what will happen, not what the button is called — the
    /// action is the part a person cannot read off the label.
    var help: String
    var action: () -> Void

    private let glyph = "checklist.checked"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            button(showingTitle: true)
            button(showingTitle: false)
        }
    }

    private func button(showingTitle: Bool) -> some View {
        Button(action: action) {
            if showingTitle {
                Label(title, systemImage: glyph)
                    .companionFont(size: 12, weight: .medium)
            } else {
                Image(systemName: glyph)
                    .companionFont(size: 12, weight: .medium)
                    .frame(minWidth: 14)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// In-window dialog so click-after states stay on the same surface as 图 25/36/37/42.
struct CompanionDialog<Content: View>: View {
    let title: String
    var dark: Bool = false
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var panelState: PanelState
    @FocusState private var dialogFocused: Bool

    var body: some View {
        ZStack {
            (dark ? Color.black : Color.black)
                .opacity(CompanionMotion.reduceTransparency ? 0.5 : (dark ? 0.45 : 0.28))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title)
                        .workspaceTitle()
                        .foregroundStyle(dark ? Color.white : .primary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(CompanionIconButtonStyle())
                        .foregroundStyle(dark ? Color.white.opacity(0.7) : .secondary)
                        .keyboardShortcut(.cancelAction)
                        .focused($dialogFocused)
                        .accessibilityLabel("关闭")
                        .accessibilityIdentifier("companion.dialog.close")
                }
                content()
            }
            .padding(22)
            .frame(width: 460)
            .focusSection()
            .background(
                (dark ? CompanionPalette.island : CompanionPalette.surface),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(dark ? Color.white.opacity(0.08) : CompanionPalette.border)
            )
            .companionAnimation(CompanionMotion.dialog(), value: title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("companion.dialog")
        .accessibilityLabel(title)
        .accessibilityHint("按 Esc 关闭，不会执行当前操作")
        .onExitCommand(perform: onClose)
        .transition(.companionDialogReveal)
        .onAppear {
            panelState.modalDialogOpen = true
            dialogFocused = true
        }
        .onDisappear { panelState.modalDialogOpen = false }
        .background(CompanionDialogKeyWindow(stealFocus: $dialogFocused))
    }
}

private struct CompanionDialogKeyWindow: NSViewRepresentable {
    var stealFocus: FocusState<Bool>.Binding

    func makeNSView(context: Context) -> DialogKeyView {
        let view = DialogKeyView()
        view.onReady = { stealFocus.wrappedValue = true }
        return view
    }

    func updateNSView(_ nsView: DialogKeyView, context: Context) {
        nsView.onReady = { stealFocus.wrappedValue = true }
        nsView.claimFocus()
    }
}

private final class DialogKeyView: NSView {
    var onReady: (() -> Void)?
    private var didClaim = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocus()
    }

    func claimFocus() {
        guard let window, !didClaim else { return }
        didClaim = true
        window.makeKey()
        if window.firstResponder is NSTextView || window.firstResponder is NSText {
            window.makeFirstResponder(self)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            if window.firstResponder is NSTextView || window.firstResponder is NSText {
                window.makeFirstResponder(self)
            }
            self.onReady?()
        }
    }
}

struct CompanionAvatar: View {
    let name: String
    var size: CGFloat = 36

    private var glyph: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "群" }
        return String(first)
    }

    var body: some View {
        Text(glyph)
            .companionFont(size: size * 0.38, weight: .semibold)
            .foregroundStyle(CompanionPalette.accent)
            .frame(width: size, height: size)
            .background(CompanionPalette.selectedFill, in: Circle())
            .accessibilityHidden(true)
    }
}
