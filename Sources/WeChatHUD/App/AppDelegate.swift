import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var panelState: PanelState!
    var monitor: ChatMonitor!
    var store: HUDStore!
    var reader: WeChatReader!
    var aiService: AIService!
    var trackingArea: NSTrackingArea?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize data layer
        store = HUDStore()
        do {
            try store.open()
        } catch {
            print("Failed to open HUDStore: \(error)")
        }

        reader = WeChatReader()
        aiService = AIService(
            config: store.getSettingJSON("ai", as: AIConfig.self) ?? AIConfig()
        )

        // Initialize services
        panelState = PanelState()
        monitor = ChatMonitor(reader: reader, store: store)

        // Create SwiftUI view
        let rootView = HUDRootView()
            .environmentObject(panelState)
            .environmentObject(monitor)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Create floating panel
        panel = FloatingPanel(contentView: hostingView)
        panel.orderFrontRegardless()

        // Set up mouse tracking on the panel's content view
        setupMouseTracking()

        // Observe state changes to resize panel
        Task { @MainActor in
            for await _ in panelState.$currentState.values {
                panel.animateHeight(to: panelState.panelHeight, width: panelState.panelWidth)
            }
        }

        // Start monitoring
        let interval = store.getSettingJSON("sync", as: SyncConfig.self)?.intervalSeconds ?? 30
        monitor.start(interval: TimeInterval(interval))
    }

    private func setupMouseTracking() {
        guard let contentView = panel.contentView else { return }

        // Tracking area covers the entire content view. `.inVisibleRect` keeps
        // it in sync when the panel resizes between compact/notification/detail.
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    // NSTrackingArea dispatches these via selector on the owner. AppDelegate
    // isn't an NSResponder so we can't override them — @objc is sufficient.
    // AppKit guarantees delivery on the main thread, so we assert main-actor
    // isolation rather than hop through Task.
    @objc func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated {
            panelState.mouseEntered()
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated {
            panelState.mouseExited()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        store.close()
    }
}
