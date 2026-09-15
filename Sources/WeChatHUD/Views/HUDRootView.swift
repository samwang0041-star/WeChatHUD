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

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState

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
        .overlay(alignment: .top) {
            // Toast overlay — transient feedback for silent failures
            // like "在微信中打开" not working. Sits on top of whatever
            // state the panel is in so the user sees it even from
            // compact mode.
            HUDToastLayer()
        }
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
        .companionAnimation(CompanionMotion.ease(0.2), value: panelState.toastMessage)
        .animation(nil, value: panelState.presentedState)
        .dynamicTypeSize(PreviewRuntime.largeType ? .accessibility2 : .large)
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
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
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

private struct HUDToastLayer: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        Group {
            if let message = panelState.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
                        _ = monitor.restoreInboxItem(item)
                    }
                    panelState.islandSnoozeUndo = nil
                    panelState.toastMessage = nil
                }
                .buttonStyle(CompanionPressStyle())
                .islandSection()
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("撤销")
            }
            Button(action: { panelState.toastMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(IslandInk.tertiary)
            }
            .buttonStyle(CompanionPressStyle())
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
