import AppKit
import SwiftUI

/// NSView subclass that owns a single persistent mouse tracking area and
/// forwards enter/exit events via closures. Needed because NSTrackingArea
/// only dispatches to NSResponder-class owners — AppDelegate (NSObject)
/// silently drops the events.
///
/// The tracking area is added **once** at init with `.inVisibleRect`, so
/// AppKit auto-syncs its rect with the view's bounds across resizes. We
/// must NOT override `updateTrackingAreas` and re-create the area on every
/// bounds change — that would fire spurious exited/entered pairs during
/// the spring animation, causing the pill to flicker between states.
final class PillContainerView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTrackingArea()
    }

    /// Make the very first click on the pill dispatch through AppKit's
    /// responder chain immediately instead of being swallowed as a
    /// window-activation click. This override has to exist on EVERY
    /// view in the hit-test chain — the deepest hit view is the one
    /// AppKit asks about, and that's inside the hosted SwiftUI tree
    /// (see `FirstMouseHostingView` below).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func installTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onExited?()
    }
}

/// NSHostingView subclass that accepts first-mouse. Clicks landing on
/// any SwiftUI-rendered subview bubble up to here for the first-mouse
/// poll, so the host returning `true` is enough to bypass AppKit's
/// window-activation-swallow behavior for the whole SwiftUI tree.
final class FirstMouseHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// A floating NSPanel rendered as a Dynamic Island-style pill that
/// wraps the notch on MacBooks, and emulates the same silhouette on
/// external / non-notched displays. In compact state the panel's
/// height equals the notch height and its middle span is aligned
/// with the physical cutout so only the left/right "wings" of the
/// pill read as visible UI. Expanded states grow DOWNWARD from the
/// notch — the top edge stays locked to `screen.frame.maxY`.
class FloatingPanel: NSPanel {
    /// The pill-shaped container view. Exposed so AppDelegate can hook up
    /// the mouse enter/exit closures to PanelState.
    let pillContainer: PillContainerView

    init(contentView: NSView) {
        // Allocate the container before super.init so we can assign self.pillContainer.
        let container = PillContainerView()
        self.pillContainer = container

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // `.popUpMenu` (level 101) paints above the menu bar on
        // every macOS configuration we've tested. `.statusBar` (25)
        // theoretically sits above `.mainMenu` (24), but some setups
        // still clip floating panels to `visibleFrame` — leaving a
        // ~25pt gap between our pill and the physical screen top
        // that breaks the "island continues out of the notch"
        // illusion. Overriding to pop-up-menu level is the simplest
        // reliable fix.
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = false
        self.backgroundColor = .clear
        // No drop shadow — the pill's top edge is flush with the
        // hardware notch, and a shadow would paint a visible halo
        // above/around the notch that breaks the "island" illusion.
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Container is now a transparent host — the island
        // silhouette (pill with a notch cutout at top-center) is
        // drawn by SwiftUI via `IslandShape` as the root view's
        // background. Keeping the AppKit layer transparent lets
        // the notch cutout show whatever's behind the panel on
        // external displays, mirroring the hardware cutout on
        // notched Macs.
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        container.layer?.masksToBounds = false

        // Set a window appearance so SwiftUI controls render correctly in the
        // dark pill states. The detail (settings) state will override this.
        self.appearance = NSAppearance(named: .darkAqua)

        container.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: container.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.contentView = container
        positionAtTop()
    }

    /// Which screen preference to use — updated from settings.
    var displayScreen: DisplayScreen = .builtIn

    /// Resolve the target screen based on the displayScreen preference.
    private var targetScreen: NSScreen {
        let screens = NSScreen.screens
        switch displayScreen {
        case .builtIn:
            // Built-in display has localizedName containing "Built-in" or is the first screen
            return screens.first { $0.localizedName.contains("Built") || $0.localizedName.contains("内置") }
                ?? NSScreen.main ?? screens[0]
        case .external:
            // External = any screen that is NOT built-in
            return screens.first { !$0.localizedName.contains("Built") && !$0.localizedName.contains("内置") }
                ?? NSScreen.main ?? screens[0]
        }
    }

    /// Cached geometry of the target screen's notch. Refreshed on
    /// every reposition so moving the panel to a different display
    /// or changing the display configuration picks up the new
    /// notch/fake-notch metrics.
    private(set) var notch: NotchGeometry = NotchGeometry(
        hasRealNotch: false, notchWidth: 200, notchHeight: 32, notchCenterX: 0
    )

    /// Refresh `notch` from the current `targetScreen`. Cheap.
    private func refreshNotchGeometry() {
        notch = NotchGeometry.detect(on: targetScreen)
    }

    /// Position the panel with its top edge flush against the
    /// screen's top edge, horizontally centered on the notch (real
    /// or fake). On notched Macs the compact-height pill's middle
    /// span then disappears under the hardware cutout; on external
    /// screens the same positioning produces a notch-silhouette
    /// look. Expansions always grow downward — the top edge is
    /// locked, so the animation visually "drops out" of the island.
    func positionAtTop() {
        refreshNotchGeometry()
        let panelWidth = frame.width
        let x = notch.notchCenterX - panelWidth / 2
        let y = targetScreen.frame.maxY - frame.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Animate the panel frame, keeping its top edge locked to the
    /// screen top (i.e., to the notch). Uses AppKit's default animator.
    func animateHeight(to newHeight: CGFloat, width: CGFloat? = nil) {
        let frame = targetFrame(height: newHeight, width: width)
        animator().setFrame(frame, display: true)
    }

    /// Snap the panel to the target size with NO animation. Used on
    /// first-ever layout so the initial placeholder `contentRect`
    /// doesn't animate down to the real compact size — that's the
    /// "first animation is wrong" artifact on launch.
    func setFrameInstantly(height: CGFloat, width: CGFloat? = nil) {
        setFrame(targetFrame(height: height, width: width), display: true)
    }

    /// Compute the target NSRect given a desired height/width. Keeps
    /// the top edge pinned to the notch and horizontally centers the
    /// panel on the notch center — so expansions "grow down" out of
    /// the island rather than drifting sideways.
    private func targetFrame(height newHeight: CGFloat, width: CGFloat? = nil) -> NSRect {
        refreshNotchGeometry()
        let newWidth = width ?? frame.width
        let x = notch.notchCenterX - newWidth / 2
        let y = targetScreen.frame.maxY - newHeight
        return NSRect(x: x, y: y, width: newWidth, height: newHeight)
    }

    /// Switch the panel between the dark pill appearance and the light
    /// system-settings appearance used in the `.detail` state. The
    /// dark island silhouette is painted by SwiftUI (IslandShape),
    /// so the container itself stays transparent in the dark
    /// states — we only set a solid background for detail/settings
    /// which uses a standard rounded window instead of the island.
    func setDetailAppearance(_ isDetail: Bool) {
        if isDetail {
            // Use system (light) appearance for the settings panel so SwiftUI
            // controls render with native macOS System Settings styling.
            self.appearance = nil   // inherit system appearance
            pillContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            pillContainer.layer?.cornerRadius = 12
            pillContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            pillContainer.layer?.masksToBounds = true
        } else {
            // Island states (compact / extended / notification):
            // container stays transparent — SwiftUI's IslandShape
            // paints the black pill with its notch cutout. Reverting
            // to an opaque black layer here would fill the notch
            // region too and break the silhouette.
            self.appearance = NSAppearance(named: .darkAqua)
            pillContainer.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
            pillContainer.layer?.cornerRadius = 0
            pillContainer.layer?.masksToBounds = false
        }
    }

    // Dynamic focus policy.
    //
    // The pill states (compact / extended / notification) must never be
    // key, otherwise the passive glance-view would keep stealing focus
    // from whatever the user is actually typing in. But the detail state
    // embeds real controls (TextField, search, etc.) that MUST be able
    // to become first responder — if `canBecomeKey` is hard-coded to
    // false, SwiftUI text fields silently reject every click.
    //
    // AppDelegate flips `allowsBecomeKey` alongside the state transition
    // and calls `makeKey()` on entering `.detail`.
    var allowsBecomeKey: Bool = false {
        didSet {
            if !allowsBecomeKey, isKeyWindow {
                resignKey()
            }
        }
    }
    override var canBecomeKey: Bool { allowsBecomeKey }
    override var canBecomeMain: Bool { false }
}
