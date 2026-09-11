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
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor(red: 248 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
    })
    static let border = Color.primary.opacity(0.075)
    static let secondarySurface = Color.primary.opacity(0.035)
}

private struct CompanionSurface: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CompanionPalette.border, lineWidth: 1))
    }
}

/// Scales hardcoded chrome sizes when the system (or preview) asks for larger type.
enum CompanionTypeScale {
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

private struct CompanionScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.font(.system(size: max(10, (size * CompanionTypeScale.factor(for: typeSize)).rounded()), weight: weight))
    }
}

extension View {
    func companionSurface(padding: CGFloat = 20) -> some View {
        modifier(CompanionSurface(padding: padding))
    }

    func companionFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(CompanionScaledFont(size: size, weight: weight))
    }

    /// Hide and disable chrome behind an in-window dialog so Tab cannot leave it.
    func companionDimmedByDialog(_ open: Bool) -> some View {
        disabled(open).accessibilityHidden(open)
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
        .companionFont(size: 11, weight: .medium)
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
            .scaleEffect(configuration.isPressed && !CompanionMotion.reduceMotion ? 0.99 : 1)
            .animation(CompanionMotion.press(), value: configuration.isPressed)
    }
}

struct CompanionFilterPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .companionFont(size: 13, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? CompanionPalette.jade : CompanionPalette.surface, in: Capsule())
        }
        .buttonStyle(CompanionPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                        .companionFont(size: 18, weight: .semibold)
                        .foregroundStyle(dark ? Color.white : .primary)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
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
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(CompanionPalette.accent)
            .frame(width: size, height: size)
            .background(CompanionPalette.selectedFill, in: Circle())
            .accessibilityHidden(true)
    }
}
