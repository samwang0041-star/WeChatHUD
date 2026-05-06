import AppKit
import SwiftUI

/// Standalone settings window — independent from the floating panel.
/// Opens centered on screen as a regular window with title bar.
class SettingsWindow: NSWindow {
    private static var shared: SettingsWindow?

    /// Show the settings window (creates if needed, brings to front if exists).
    @MainActor
    static func show(
        panelState: PanelState,
        monitor: ChatMonitor,
        store: HUDStore,
        reader: WeChatReader
    ) {
        if let existing = shared, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Compute target size as 90% of the target screen.
        let panelScreen = NSApp.windows
            .first(where: { $0 is FloatingPanel })?.screen
        let screen = panelScreen ?? NSScreen.main ?? NSScreen.screens.first
        let targetFrame: NSRect
        if let screen = screen {
            let vf = screen.visibleFrame
            let w: CGFloat = vf.width * 0.9
            let h: CGFloat = vf.height * 0.9
            let x = vf.midX - w / 2
            let y = vf.maxY - h - 20
            targetFrame = NSRect(x: x, y: max(y, vf.minY), width: w, height: h)
        } else {
            let w: CGFloat = 1080
            let h: CGFloat = 780
            targetFrame = NSRect(x: 0, y: 0, width: w, height: h)
        }

        let rootView = SettingsView()
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(store)
            .environmentObject(reader)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = targetFrame

        let window = SettingsWindow(
            contentRect: targetFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WeChatHUD 设置"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false

        if screen == nil {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        shared = window
    }
}
