import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var panelState: PanelState!
    var monitor: ChatMonitor!
    var store: HUDStore!
    var reader: WeChatReader!
    var aiService: AIService!
    var fsWatcher: FSEventsWatcher?
    var trackingArea: NSTrackingArea?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WCHUD] launch — pid=\(ProcessInfo.processInfo.processIdentifier)")
        // Initialize data layer
        store = HUDStore()
        do {
            try store.open()
        } catch {
            print("Failed to open HUDStore: \(error)")
        }

        // Cache strategy comes from persisted settings (default = persistent).
        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        reader = WeChatReader(cacheStrategy: syncCfg.cacheStrategy)

        aiService = AIService(
            config: store.getSettingJSON("ai", as: AIConfig.self) ?? AIConfig()
        )

        // Initialize services
        panelState = PanelState()
        monitor = ChatMonitor(reader: reader, store: store)

        // SwiftUI view — inject store so settings views can persist.
        let rootView = HUDRootView()
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(store)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel(contentView: hostingView)
        panel.orderFrontRegardless()
        setupMouseTracking()

        // Resize panel when state changes
        Task { @MainActor in
            for await _ in panelState.$currentState.values {
                panel.animateHeight(to: panelState.panelHeight, width: panelState.panelWidth)
            }
        }

        // Start the monitor (includes initial scan + WeChat process observer).
        monitor.start()

        // Start FSEvents-based file watcher for incremental updates.
        startFSWatcher()

        // Forward important notifications to the panel banner.
        Task { @MainActor in
            for await notif in monitor.$latestNotification.values {
                guard notif != nil else { continue }
                let duration = store.getSettingJSON("notification", as: NotificationConfig.self)?.durationSeconds ?? 3
                panelState.showNotification(duration: TimeInterval(duration))
            }
        }
    }

    private func startFSWatcher() {
        let dbDir = reader.dbDir
        print("[WCHUD] dbDir=\(dbDir.isEmpty ? "<EMPTY>" : dbDir)")
        guard !dbDir.isEmpty else {
            print("[WCHUD] FSWatcher NOT started — no dbDir")
            return
        }
        print("[WCHUD] FSWatcher starting on \(dbDir)")
        // latency = 0 → kernel delivers events as soon as they happen, with
        // only the minimum coalescing for concurrent writes. Every 1ms we
        // shave here is 1ms closer to "instant" from the user's POV.
        let watcher = FSEventsWatcher(paths: [dbDir], latency: 0.0) { [weak self] paths in
            // FSEvents delivers on our main dispatch queue (set in start()).
            MainActor.assumeIsolated {
                self?.monitor.onFSEvent(paths: paths)
            }
        }
        watcher.start()
        fsWatcher = watcher
    }

    private func setupMouseTracking() {
        guard let contentView = panel.contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    @objc func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { panelState.mouseEntered() }
    }

    @objc func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { panelState.mouseExited() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fsWatcher?.stop()
        monitor.stop()
        store.close()
    }
}
