import AppKit
import SwiftUI

/// Standalone insight window — large independent window for chat analysis.
class InsightWindow: NSWindow {
    private static var shared: InsightWindow?

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

        let rootView = ChatInsightView(insightCoordinator: monitor.insightCoordinator)
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(store)
            .environmentObject(reader)

        let hostingView = NSHostingView(rootView: rootView)

        // 80% of screen size. Never index screens[0]: with no display attached
        // (clamshell without external monitor, hot-plug gap) it traps on the
        // launch path — the same crash FloatingPanel already fixed.
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = frame.width * 0.8
        let h = frame.height * 0.8

        let window = InsightWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "聊天回顾"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        // Match RetrospectiveWindow: dark theme for consistency with the
        // floating HUD (which is always dark).
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        shared = window
    }
}
