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
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        // Each pill state is rendered at its own fixed intrinsic width,
        // CENTERED inside the window. The window animates symmetrically
        // from the center, so center-aligned content stays visually
        // pinned to screen-center rather than sliding with the left edge.
        //
        // `.transaction { $0.animation = nil }` disables all SwiftUI
        // implicit transitions on state changes. Without this, SwiftUI
        // cross-fades / scales the content view in parallel with the
        // AppKit window-frame animation; because the two use different
        // curves and durations they visibly desync, producing a "content
        // slides left after the window has settled" artifact.
        Group {
            switch panelState.currentState {
            case .compact:
                // Compact fills the entire panel frame — AppDelegate's
                // `panelSize(for: .compact)` sizes the panel to
                // (notchWidth + wings) × notchHeight, so we don't
                // hardcode dimensions here. Letting it flex keeps the
                // bar honest when the display (and therefore the
                // notch geometry) changes under us.
                CompactInboxBar()
            case .extended:
                extendedContent
            case .notification:
                if let notif = monitor.latestNotification {
                    NotificationBannerView(notification: notif)
                }
            case .detail:
                DetailPanelView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Island silhouette rendered in two layers so the notch
            // region reads as SOLID BLACK (mimicking hardware) on
            // external displays, instead of a transparent cutout
            // that reveals the menu bar behind.
            //
            // 1) `IslandShape` (with the notch cutout) gives the
            //    pill's visible silhouette — flat top, notch dip in
            //    the middle, bottom-rounded wings.
            // 2) Behind it, a plain black bar fills the notch band
            //    with opaque black. On notched Macs this band is
            //    hidden by hardware anyway; on external it becomes
            //    the "fake notch" proper — solid black like the
            //    real thing, no menu-bar bleed-through.
            ZStack(alignment: .top) {
                Color.black
                    .frame(height: islandNotchHeight)
                    .frame(maxWidth: islandNotchWidth)
                IslandShape(
                    notchWidth: islandNotchWidth,
                    notchHeight: islandNotchHeight,
                    pillCornerRadius: 18,
                    notchCornerRadius: 10
                )
                .fill(Color.black)
            }
        )
        .overlay(alignment: .top) {
            // Toast overlay — transient feedback for silent failures
            // like "在微信中打开" not working. Sits on top of whatever
            // state the panel is in so the user sees it even from
            // compact mode.
            if let message = panelState.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panelState.toastMessage)
        .transaction { $0.animation = nil }
    }

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button(action: { panelState.toastMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 400)
        .padding(.top, 4)
    }

    /// Live notch width from the running panel — used to size the
    /// cutout in the island silhouette.
    private var islandNotchWidth: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchWidth
        }
        return 16
    }

    private var islandNotchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }

    /// Extended inbox with intrinsic-height layout + size reporting.
    /// Extracted so the outer `switch` stays simple enough for Swift's
    /// type checker (nested PreferenceKey / GeometryReader inside a
    /// switch-case trips inference on the whole `Group`).
    private var extendedContent: some View {
        InboxView()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 420)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SizePreferenceKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(SizePreferenceKey.self) { size in
                panelState.reportExtendedSize(size)
            }
    }
}

/// Size of the inbox panel. Width is fixed-compact; height is a sum of the
/// parts actually rendered so the panel hugs its content instead of leaving
/// a large empty tail. Caller passes the count of action-required rows (the
/// only rows drawn in the top list) and whether the handled footer is shown.
func inboxSize(actionCount: Int, hasHandled: Bool) -> (CGFloat, CGFloat) {
    let width: CGFloat = 420

    // Empty inbox — just the "没有待处理消息" stub.
    if actionCount == 0 && !hasHandled {
        return (width, 92)
    }

    let rows = min(max(actionCount, 1), 10)
    let headerHeight: CGFloat = 42       // padding 26 + 4 + label ~12
    let dividerHeight: CGFloat = 1
    // Row height estimate lives on the "plenty of headroom" side of
    // the measured value. Rows with an inline AI briefing line (Tier
    // 2) measure ~78pt; plain rows ~58pt. Using 72pt keeps the
    // first-ever-hover animation within ~10pt of the measured size
    // (which then arrives via PreferenceKey and snaps instantly via
    // the sub-2pt tolerance in AppDelegate's measurement sink).
    let rowHeight: CGFloat = 72
    let handledHeaderHeight: CGFloat = hasHandled ? 28 : 0
    let bottomPadding: CGFloat = 8

    let bodyHeight = CGFloat(rows) * rowHeight
    let total = headerHeight + dividerHeight + bodyHeight + handledHeaderHeight + bottomPadding
    return (width, min(total, 520))
}
