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

        let rootView = SettingsView()
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(monitor.insightCoordinator)
            .environmentObject(store)
            .environmentObject(reader)

        let hostingView = NSHostingView(rootView: rootView)

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WeChatHUD 设置"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false

        // Open on the same screen as the floating panel, below it.
        let panelScreen = NSApp.windows
            .first(where: { $0 is FloatingPanel })?.screen
        let screen = panelScreen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = screen {
            let vf = screen.visibleFrame
            let w: CGFloat = min(1080, vf.width - 40)
            let h: CGFloat = min(780, vf.height - 80)
            let x = vf.midX - w / 2
            let y = vf.maxY - h - 60
            window.setFrame(NSRect(x: x, y: max(y, vf.minY), width: w, height: h), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        shared = window
    }
}
