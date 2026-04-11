import AppKit
import SwiftUI

/// A floating NSPanel that sits at the top of the screen.
/// Non-activating: doesn't steal focus from other apps.
class FloatingPanel: NSPanel {
    init(contentView: NSView) {
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

        // Pure-black container. Explicit opaque sRGB black, no stroke.
        // Only the bottom two corners are rounded so the top edge fuses with
        // the screen's top edge (真吸顶视觉).
        let container = NSView()
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

    /// Animate the panel height change, keeping it anchored at the top.
    func animateHeight(to newHeight: CGFloat, width: CGFloat? = nil) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let newWidth = width ?? frame.width
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.maxY - newHeight

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(
                NSRect(x: x, y: y, width: newWidth, height: newHeight),
                display: true
            )
        }
    }

    // Prevent the panel from becoming key window (no focus stealing)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
