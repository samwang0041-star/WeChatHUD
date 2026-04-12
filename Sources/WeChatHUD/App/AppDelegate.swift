import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var panelState: PanelState!
    var monitor: ChatMonitor!
    var store: HUDStore!
    var reader: WeChatReader!
    var aiService: AIService!
    var fsWatcher: FSEventsWatcher?
    private var cancellables = Set<AnyCancellable>()

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

        // AI config comes from the settings table — seeded on first launch
        // by HUDStore.open(). Source code never carries the endpoint URL
        // or model name; loadAIConfig() is the single read point.
        aiService = AIService(config: store.loadAIConfig())

        // Initialize services
        panelState = PanelState()
        monitor = ChatMonitor(reader: reader, store: store, aiService: aiService)

        // SwiftUI view — inject store and reader so settings views can
        // persist (store) and browse WeChat contacts (reader).
        let rootView = HUDRootView()
            .environmentObject(panelState)
            .environmentObject(monitor)
            .environmentObject(store)
            .environmentObject(reader)

        // Use our first-mouse-accepting subclass so a click on the
        // non-key pill reaches the SwiftUI tap gesture on the first
        // tap instead of being swallowed by AppKit as a
        // window-activation click.
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel(contentView: hostingView)
        panel.orderFrontRegardless()

        // Hook mouse enter/exit to PanelState. PillContainerView handles
        // NSTrackingArea dispatch on the main thread — assumeIsolated is
        // safe because AppKit delivers mouse events on main.
        panel.pillContainer.onEntered = { [weak self] in
            MainActor.assumeIsolated { self?.panelState.mouseEntered() }
        }
        panel.pillContainer.onExited = { [weak self] in
            MainActor.assumeIsolated { self?.panelState.mouseExited() }
        }

        // Resize panel when state changes.
        //
        // We use a Combine sink instead of `for await … in $currentState.values`
        // because the async-stream bridge hops to the next runloop tick before
        // delivering, so SwiftUI re-lays out the content for the new state in
        // the OLD window frame one tick before the window animation fires.
        // That desync is exactly what produced the "cursor enters → pill
        // shifts, then shifts back after expansion" glitch. Combine's sink
        // fires synchronously in the same dispatch as the @Published setter,
        // so the window-frame animation starts BEFORE SwiftUI gets a chance
        // to render the new content in the old frame.
        // @Published fires in willSet, so `panelState.currentState` inside
        // the sink still reads the OLD value. We MUST compute the target
        // size from the `state` parameter (which is the new value) via the
        // static PanelState.width(for:)/height(for:) helpers — reading
        // `panelState.panelWidth` here would lag by one transition.
        panelState.$currentState
            .sink { [weak self] state in
                guard let self = self else { return }
                let (w, h) = self.panelSize(for: state)
                self.panel.animateHeight(to: h, width: w)

                // Focus policy.
                //
                // `.compact` / `.notification` stay non-key so they never
                // steal focus from whatever the user is typing in.
                //
                // `.detail` needs key status so TextFields can accept
                // input — we also force `makeKey()` on entry.
                //
                // `.extended` also needs `canBecomeKey = true`, BUT we
                // do NOT call `makeKey()`. The panel only becomes key
                // when the user actually clicks it (standard AppKit
                // mouseDown → tryMakeKeyAndOrderFront flow). Without
                // this, SwiftUI tap gestures never complete because
                // mouseUp isn't routed to a non-key window. Hovering
                // alone does not grab focus. Combined with the
                // `.nonactivatingPanel` style, clicking never activates
                // the HUD application either.
                switch state {
                case .detail:
                    self.panel.allowsBecomeKey = true
                    self.panel.makeKey()
                case .extended:
                    self.panel.allowsBecomeKey = true
                case .compact, .notification:
                    self.panel.allowsBecomeKey = false
                }
            }
            .store(in: &cancellables)

        // When the underlying unread / VIP lists change while we're in
        // the extended state, the panel must resize too — otherwise a
        // silence action leaves a gap of empty chrome. These sinks fire
        // on every list mutation and re-run `panelSize` in-place.
        monitor.$unreadItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        monitor.$suppressedItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        monitor.$recentNotifications
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        monitor.$replyDebtItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        // Start the monitor (includes initial scan + WeChat process observer).
        monitor.start()

        // Start FSEvents-based file watcher for incremental updates.
        startFSWatcher()

        // Forward whitelist-message previews to the banner. Any non-nil
        // publish from ChatMonitor (which, post-change, fires for every
        // new whitelist message — not just @ mentions) flips the panel
        // into .notification state for `durationSeconds`. Combine sink
        // for the same sync reason as the state observer above.
        monitor.$latestNotification
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self = self else { return }
                let duration = self.store.getSettingJSON("notification", as: NotificationConfig.self)?.durationSeconds ?? 3
                self.panelState.showNotification(duration: TimeInterval(duration))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hudAIConfigDidChange)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let cfg = self.store.loadAIConfig()
                Task {
                    await self.aiService.updateConfig(cfg)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hudReplyDebtAIConfigDidChange)
            .sink { [weak self] _ in
                self?.monitor.refreshNow()
            }
            .store(in: &cancellables)
    }

    /// Resolve the target panel size for a given state. `.extended`
    /// grows to fit the tabbed VIP / 未读 view. The 未读 row count must
    /// cover whichever sub-filter could be showing the longest list —
    /// that's `max(unread, suppressed)` since the user may click into
    /// 已处理. Mirrored by `extendedTabsSize(vip:unread:)` in HUDRootView.
    @MainActor
    private func panelSize(for state: HUDState) -> (CGFloat, CGFloat) {
        switch state {
        case .extended:
            let vip = monitor.recentNotifications.count
            let visible = monitor.unreadItems.count
            let suppressed = monitor.suppressedItems.count
            let replyDebt = monitor.replyDebtItems.count
            if vip == 0 && visible == 0 && suppressed == 0 && replyDebt == 0 {
                return (PanelState.width(for: .extended), PanelState.height(for: .extended))
            }
            return extendedTabsSize(
                vip: vip,
                unread: max(visible, suppressed),
                replyDebt: replyDebt
            )
        default:
            return (PanelState.width(for: state), PanelState.height(for: state))
        }
    }

    @MainActor
    private func resizeExtendedIfActive() {
        guard panelState.currentState == .extended else { return }
        let (w, h) = panelSize(for: .extended)
        panel.animateHeight(to: h, width: w)
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

    func applicationWillTerminate(_ notification: Notification) {
        fsWatcher?.stop()
        monitor.stop()
        store.close()
    }
}
