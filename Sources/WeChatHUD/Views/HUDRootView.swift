import SwiftUI
import AppKit

/// SwiftUI → AppKit size channel. Any subtree with
/// `.background(SizeReporter())` publishes its rendered bounds up to the
/// nearest `onPreferenceChange(SizePreferenceKey.self)`.
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Keep whichever value is non-zero. If both are non-zero, prefer
        // the latest (typical case — single reporter in the tree).
        if next != .zero { value = next }
    }
}

/// The island's content clock, expressed apart from the view that draws it.
///
/// The silhouette is driven by an AppKit frame spring, and the content inside
/// it is a SwiftUI swap — two systems on two clocks. Left to themselves the
/// content arrives at the *start* of the morph, so the mask spends the first
/// fifth of a second clipping a timestamp in half. This type owns the one
/// decision that fixes it: when the content is allowed to be visible.
enum IslandContentChoreography {
    /// Compact and peek share one surface (`CompactInboxBar`), so hovering
    /// must not re-run the reveal — the widen has to read as one gesture.
    enum Family: Equatable {
        case ambient
        case body
    }

    static func family(of state: HUDState) -> Family {
        switch state {
        case .compact, .peek: return .ambient
        case .extended, .notification, .detail: return .body
        }
    }

    /// - Parameter midFlight: a collapsing spring is running, so
    ///   `presentedState` is still the outgoing body surface while
    ///   `currentState` has already asked for compact. The surface stays
    ///   mounted to keep the covering window painted, which is exactly when
    ///   the mask would otherwise cut a glyph in half.
    /// - Parameter revealed: the body content has been let in. Only the body
    ///   family waits for this; the ambient wings never do, or every hover
    ///   would blink.
    static func isVisible(family: Family, midFlight: Bool, revealed: Bool) -> Bool {
        if midFlight { return false }
        if family == .body && !revealed { return false }
        return true
    }

    /// The curve for the transition *into* `visible`.
    ///
    /// A collapse landing back on the ambient wings is instant: the pill is
    /// already at its final size by then, and a delayed reveal there would
    /// leave the closed island visibly empty for 200 ms.
    static func animation(family: Family, visible: Bool) -> Animation? {
        if !visible { return CompanionMotion.islandContentFadeOut() }
        return family == .body ? CompanionMotion.islandContentReveal() : nil
    }

    /// Whether opening a body surface should go dark for one turn so the
    /// delayed reveal can play. Reduce Motion has no delay and no fade, so
    /// staging a 0 then a 1 would flash an empty island.
    static func stagesBodyReveal(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState
    /// Bumped when Increase Contrast / Differentiate Without Color move, so
    /// the island's hairline chrome and status lights redraw with the new
    /// tokens. See `CompanionAccessibility`.
    @State private var displayOptionsNonce = 0
        // Read so the island re-evaluates when the flag flips; the value is
        // carried by `.companionDisplayGeneration` below.

    /// Whether the body surface (inbox / banner / detail) has been let in yet.
    /// Flips false the moment the silhouette starts opening so the content
    /// materialises inside the shape rather than being unmasked mid-word.
    @State private var bodyContentRevealed = true

    var body: some View {
        // Each pill state is rendered at its own fixed intrinsic width,
        // CENTERED inside the window. The window animates symmetrically
        // from the center, so center-aligned content stays visually
        // pinned to screen-center rather than sliding with the left edge.
        //
        // Isolate island *state* swaps from SwiftUI implicit animation so
        // compact/extended/detail do not cross-fade against the mask spring.
        // Do not nil the whole transaction: that also killed in-row expand,
        // which then snapped and could report the covering stage as height.
        Group {
            switch panelState.presentedState {
            case .compact, .peek:
                // Compact/peek fill the panel frame — AppDelegate sizes
                // them geometrically (notch + wings, plus peek slots).
                CompactInboxBar()
            case .extended, .notification, .detail:
                HUDMonitorSurface()
            }
        }
        // Top-aligned so a covering window (the union of current and target
        // frames during a mask-driven spring) keeps the island hung from the
        // notch. Centering would drop compact content into the middle of the
        // cover while the mask shrinks from the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The content breathes on a different clock from the silhouette: it
        // leaves first and arrives last, so the mask never shows half a
        // timestamp. Applied *before* the background so the black body itself
        // stays opaque through the whole morph.
        .opacity(islandContentVisible ? 1 : 0)
        .animation(IslandContentChoreography.animation(family: islandContentFamily,
                                                      visible: islandContentVisible),
                   value: islandContentVisible)
        .background(
            // One black body: notch band + pill are the same color as
            // the hardware Dynamic Island, so compact wings disappear
            // into it and expand reads as that island growing down.
            ZStack(alignment: .top) {
                CompanionPalette.island
                    .frame(height: islandNotchHeight)
                    .frame(maxWidth: islandNotchWidth)
                IslandShape(
                    notchWidth: islandNotchWidth,
                    notchHeight: islandNotchHeight,
                    pillCornerRadius: radii.pill,
                    notchCornerRadius: radii.notch,
                    topCornerRadius: radii.top
                )
                .fill(CompanionPalette.island)
                // Scope the reshape animation to the silhouette itself.
                //
                // The outer .animation(nil, value: presentedState) exists so the
                // content swap does not cross-fade against the mask spring, and
                // it also suppresses implicit animation here — without this line
                // the radii would *snap* while the body springs, and the corners
                // would arrive a quarter second before the edges they belong to.
                .animation(
                    CompanionMotion.islandSilhouette(expanding: isExpanding),
                    value: panelState.presentedState
                )
            }
        )
        // The toast is NOT painted here — the compositor mask clips the
        // island's content, so anything inside this surface is invisible
        // below the ~34pt compact band. AppDelegate floats it as its own
        // nonactivating window just below the island instead. Only the
        // toast *triggers* live in this tree (they must always be mounted).
        .background(HUDToastTriggers())
        // Composite the island as one scene before it hits the window.
        //
        // Every part of this surface is either translucent (the AI sweep, the
        // severity halo, the row hovers) or drawn with a shadow, so without a
        // single compositing boundary each layer is blended against the
        // *window* independently. That is what produces faint seams where the
        // shadowed silhouette meets the opaque notch band mid-animation, and
        // it costs a separate offscreen pass per blended layer per frame.
        // Flattening once is both cleaner at the edges and cheaper to draw —
        // the reference implementation groups its notch scene the same way.
        .compositingGroup()
        .animation(nil, value: panelState.presentedState)
        .onChange(of: islandContentFamily) { _, family in
            guard family == .body else {
                bodyContentRevealed = true
                return
            }
            guard IslandContentChoreography.stagesBodyReveal(
                reduceMotion: CompanionMotion.reduceMotion
            ) else {
                bodyContentRevealed = true
                return
            }
            // Two run-loop turns on purpose: the 0 has to be committed before
            // the 1, or SwiftUI coalesces both writes into one transaction and
            // the reveal never renders.
            bodyContentRevealed = false
            DispatchQueue.main.async { bodyContentRevealed = true }
        }
        .companionDisplayGeneration(CompanionAccessibility.generation)
        .dynamicTypeSize(CompanionTypeScale.appliedRange(largeType: PreviewRuntime.largeType))
        .onReceive(NotificationCenter.default.publisher(for: CompanionAccessibility.displayOptionsDidChange)) { _ in
            displayOptionsNonce &+= 1
        }
    }

    /// Which surface family is painted right now.
    private var islandContentFamily: IslandContentChoreography.Family {
        IslandContentChoreography.family(of: panelState.presentedState)
    }

    /// The one value the content opacity reads.
    private var islandContentVisible: Bool {
        IslandContentChoreography.isVisible(family: islandContentFamily,
                                            midFlight: panelState.presentedState != panelState.currentState,
                                            revealed: bodyContentRevealed)
    }

    private var islandNotchWidth: CGFloat {
        (NSApp.delegate as? AppDelegate)?.attachedPanel?.notch.notchWidth ?? 200
    }

    private var islandNotchHeight: CGFloat {
        (NSApp.delegate as? AppDelegate)?.attachedPanel?.notch.notchHeight ?? 32
    }

    /// The silhouette’s corner radii for the state being presented.
    ///
    /// Driving these from `presentedState` is what lets the shape animate:
    /// `IslandShape.animatableData` interpolates them, so the body unfolds
    /// rather than stretching. Reading the *presented* state (not `currentState`)
    /// keeps the radii in step with the frame spring, which is the animation
    /// that is actually on screen.
    private var radii: IslandChrome.SilhouetteRadii {
        IslandChrome.radii(for: panelState.presentedState)
    }

    /// Whether the current transition is opening. Picks the silhouette spring,
    /// which has to match the window-frame spring rather than the content morph.
    private var isExpanding: Bool {
        switch panelState.presentedState {
        case .compact, .peek: return false
        case .extended, .notification, .detail: return true
        }
    }
}

private struct HUDMonitorSurface: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        surface
            .background { expandedChrome }
    }

    @ViewBuilder
    private var expandedChrome: some View {
        let show = panelState.presentedState == .extended
            || panelState.presentedState == .notification
            || panelState.presentedState == .detail
        UnevenRoundedRectangle(
            // Follows the silhouette rather than a literal. This was pinned at
            // 22 while the body below it reshapes between 16 and 22, so the
            // hairline and the shadow it casts sat on a different radius from
            // the shape they belong to — visible as the border cutting inside
            // the corner at one end of the transition.
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: chromeRadii.pill,
                bottomTrailing: chromeRadii.pill,
                topTrailing: 0
            ),
            style: .continuous
        )
        .strokeBorder(IslandChrome.hairline, lineWidth: show ? IslandChrome.hairlineWidth : 0)
        .shadow(color: show ? Color.black.opacity(0.45) : .clear, radius: 20, y: 10)
        .allowsHitTesting(false)
        .animation(
            CompanionMotion.islandSilhouette(expanding: show),
            value: panelState.presentedState
        )
    }

    /// The silhouette radii for the state this surface is drawing. Same source
    /// as the island body, so the chrome cannot drift from the shape.
    private var chromeRadii: IslandChrome.SilhouetteRadii {
        IslandChrome.radii(for: panelState.presentedState)
    }

    @ViewBuilder
    private var surface: some View {
        switch panelState.presentedState {
        case .extended:
            InboxView()
                .frame(width: IslandChrome.expandedWidth, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: SizePreferenceKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    panelState.reportExtendedSize(size)
                }
                // Same order as the notification banner: measure the
                // intrinsic list first, *then* let the view fill the
                // covering stage. Measuring after the infinite frame
                // reports the window (720 pt) instead of the inbox.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .notification:
            if let notif = monitor.latestNotification {
                StableNotificationBanner(notification: notif)
                    .id(notif.messageID)
                    .transition(.islandDetailReveal)
                    .onPreferenceChange(SizePreferenceKey.self) { size in
                        panelState.reportNotificationSize(size)
                    }
            }
        case .detail:
            DetailPanelView()
                .padding(.top, islandNotchHeight)
        case .compact, .peek:
            EmptyView()
        }
    }

    private var islandNotchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }
}

/// Toast trigger observer — the publishers that CREATE toasts must stay
/// mounted inside the panel tree; the toast window only exists while a
/// toast is visible, so hosting these there would swallow the first one.
private struct HUDToastTriggers: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        EmptyView()
            .onReceive(monitor.$inboxActionError) { message in
                if let message { panelState.showToast(message) }
            }
            .onReceive(monitor.$discussionArchiveNotice) { message in
                if let message {
                    panelState.showToast(message, duration: 8)
                    monitor.discussionArchiveNotice = nil
                }
            }
    }
}

struct IslandToastContent: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    let message: String
    /// False when the window is already up (a replacement) or Reduce Motion
    /// asked for a snap — the scale would otherwise replay from 0.95.
    var playsEnter: Bool = true
    @State private var landed: Bool

    init(message: String, playsEnter: Bool = true) {
        self.message = message
        self.playsEnter = playsEnter
        _landed = State(initialValue: !playsEnter || CompanionMotion.reduceMotion)
    }

    var body: some View {
        toastView(message)
            // Grows down from the island it hangs under, never from nothing.
            .scaleEffect(toastSettled ? 1 : 0.95, anchor: .top)
            .companionAnimation(
                panelState.toastCollapsing ? CompanionMotion.exit() : CompanionMotion.enter(),
                value: toastSettled
            )
            .onAppear {
                guard !landed else { return }
                landed = true
            }
    }

    /// Enter lands at 1; exit shrinks back toward the island. Reduce Motion
    /// stays settled so the window-alpha snap is the only change.
    private var toastSettled: Bool {
        if CompanionMotion.reduceMotion { return true }
        if panelState.toastCollapsing { return false }
        return landed
    }

    private func toastView(_ message: String) -> some View {
        let snoozeUndo = panelState.islandSnoozeUndo
        return HStack(spacing: 6) {
            Image(systemName: snoozeUndo == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(toastTint)
            // The message gets the space the action would have taken when
            // there is no action. A toast is one line of news; letting the
            // text keep its full width is what stops it wrapping to two.
            Text(message)
                .islandMeta()
                .foregroundColor(IslandInk.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if snoozeUndo != nil {
                Button("撤销") {
                    if let item = panelState.islandSnoozeUndo?.item {
                        guard monitor.restoreInboxItem(item) else {
                            panelState.showToast(
                                monitor.inboxActionError ?? CompanionInteractionCopy.inboxRestoreFailed,
                                duration: 5
                            )
                            return
                        }
                    }
                    panelState.islandSnoozeUndo = nil
                    panelState.toastMessage = nil
                }
                .buttonStyle(IslandRowButtonStyle())
                .islandSection()
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("撤销")
            }
            Button(action: { panelState.toastMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(IslandInk.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandIconButtonStyle())
            .accessibilityLabel("关闭提示")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        // The edge takes the toast's own semantic colour. It
                        // used to be orange unconditionally, so a successful
                        // 撤销 toast — green check, green action — wore a
                        // warning border and read as a problem.
                        .stroke(toastTint.opacity(0.42), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 400)
        .padding(.top, 4)
    }

    /// Orange means "something needs you"; mint means "done". The toast picks
    /// one, and both the glyph and the border follow it.
    private var toastTint: Color {
        panelState.islandSnoozeUndo == nil ? .orange : CompanionPalette.islandMint
    }
}

/// Size of the inbox panel. Width is fixed; height is a sum of the parts
/// actually rendered so the panel hugs its content instead of leaving a
/// large empty tail. Caller passes the count of action-required rows (the
/// only rows drawn in the top list) and whether the handled footer is shown.
///
/// SwiftUI reports the real rendered height through `SizePreferenceKey`, and
/// that measurement is what the panel animates to — this is the starting
/// estimate, so it only has to be close. The row height comes from
/// `IslandMetrics` so the estimate cannot drift away from the rows again.
func inboxSize(actionCount: Int, hasHandled: Bool) -> (CGFloat, CGFloat) {
    let width = IslandChrome.expandedWidth

    // Empty inbox — brand block + empty copy + workspace bar.
    if actionCount == 0 && !hasHandled {
        return (width, 236)
    }

    let rows = min(max(actionCount, 1), 10)
    // Notch band + section row.
    let headerHeight: CGFloat = 44
    let dividerHeight: CGFloat = 1
    let rowHeight = IslandMetrics.rowHeight
    let handledHeaderHeight: CGFloat = hasHandled ? 30 : 0
    let bottomBarHeight: CGFloat = 46

    let bodyHeight = CGFloat(rows) * rowHeight
    let total = headerHeight + dividerHeight + bodyHeight + handledHeaderHeight + bottomBarHeight
    return (width, min(total, 720))
}

/// Freeze the recipient and evidence while the user is interacting with a banner.
/// New arrivals remain in the inbox and appear after this presentation is dismissed.
private struct StableNotificationBanner: View {
    @State private var notification: HUDNotification
    init(notification: HUDNotification) { _notification = State(initialValue: notification) }
    var body: some View { NotificationBannerView(notification: notification) }
}
