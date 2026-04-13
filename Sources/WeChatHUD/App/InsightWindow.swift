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

        let rootView = ChatInsightView()
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(store)
            .environmentObject(reader)

        let hostingView = NSHostingView(rootView: rootView)

        let window = InsightWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "聊天洞察"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        shared = window
    }
}
