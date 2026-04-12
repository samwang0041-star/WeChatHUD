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

/// A floating NSPanel that sits at the top of the screen.
/// Non-activating: doesn't steal focus from other apps.
class FloatingPanel: NSPanel {
    /// The pill-shaped container view. Exposed so AppDelegate can hook up
    /// the mouse enter/exit closures to PanelState.
    let pillContainer: PillContainerView

    init(contentView: NSView) {
        // Allocate the container before super.init so we can assign self.pillContainer.
        let container = PillContainerView()
        self.pillContainer = container

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // .statusBar (25) is one level above .mainMenu (24), so the panel
        // draws on top of the menu bar — required for true 吸顶 look.
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false   // AppKit shadow paints a thin top edge — off
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Pure-black container (PillContainerView allocated above).
        // Explicit opaque sRGB black, no stroke. Only the bottom two corners
        // are rounded so the top edge fuses with the screen's top edge.
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        container.layer?.cornerRadius = 18
        // In AppKit (Y-up), MinY is the bottom, so these are the bottom corners.
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        container.layer?.masksToBounds = true

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

    /// Position the panel centered at the very top of the main screen,
    /// overlapping the menu bar region (真吸顶 — uses .frame, not .visibleFrame).
    func positionAtTop() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let panelWidth = frame.width
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - frame.height  // flush with screen top
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Animate the panel frame, keeping it anchored to the screen top.
    /// Uses AppKit's default animator — no custom duration or curve.
    func animateHeight(to newHeight: CGFloat, width: CGFloat? = nil) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let newWidth = width ?? frame.width
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.maxY - newHeight

        animator().setFrame(
            NSRect(x: x, y: y, width: newWidth, height: newHeight),
            display: true
        )
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
