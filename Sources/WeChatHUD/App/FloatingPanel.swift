import AppKit
import SwiftUI

/// A floating NSPanel that sits at the top of the screen.
/// Non-activating: doesn't steal focus from other apps.
class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Visual effect background (dark HUD material)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .darkAqua)
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true

        visualEffect.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        self.contentView = visualEffect
        positionAtTop()
    }

    /// Position the panel centered at the top of the main screen, below the menu bar.
    func positionAtTop() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth = frame.width
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - frame.height - 4  // 4px padding from top
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Animate the panel height change, keeping it anchored at the top.
    func animateHeight(to newHeight: CGFloat, width: CGFloat? = nil) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let newWidth = width ?? frame.width
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.maxY - newHeight - 4

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
