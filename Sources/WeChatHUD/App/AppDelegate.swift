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
    private var statusItem: NSStatusItem?
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
        let customDBDir: String? = (syncCfg.wechatDBPath != "auto" && !syncCfg.wechatDBPath.isEmpty)
            ? syncCfg.wechatDBPath
            : nil
        reader = WeChatReader(dbDir: customDBDir, cacheStrategy: syncCfg.cacheStrategy)

        // AI config comes from the settings table — seeded on first launch
        // by HUDStore.open(). Source code never carries the endpoint URL
        // or model name; loadAIConfig() is the single read point.
        aiService = AIService(config: store.loadAIConfig())

        // Initialize services
        panelState = PanelState()
        monitor = ChatMonitor(reader: reader, store: store, aiService: aiService)

        // Wire up window callbacks
        panelState.onShowSettings = { [weak self] in
            guard let self = self else { return }
            SettingsWindow.show(
                panelState: self.panelState,
                monitor: self.monitor,
                store: self.store,
                reader: self.reader
            )
        }
        panelState.onShowInsight = { [weak self] in
            guard let self = self else { return }
            InsightWindow.show(
                panelState: self.panelState,
                monitor: self.monitor,
                store: self.store,
                reader: self.reader
            )
        }

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
        panel.displayScreen = syncCfg.displayScreen
        panel.positionAtTop()
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
                // Re-read display screen preference on every state change
                let latestSync = self.store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
                self.panel.displayScreen = latestSync.displayScreen

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
                    // Use light appearance for settings, dark for conversation detail
                    let isSettings = self.panelState.selectedChatUsername == nil
                    self.panel.setDetailAppearance(isSettings)
                case .extended:
                    self.panel.allowsBecomeKey = true
                    self.panel.makeKey()
                    self.panel.setDetailAppearance(false)
                case .compact, .notification:
                    self.panel.allowsBecomeKey = false
                    self.panel.setDetailAppearance(false)
                }
            }
            .store(in: &cancellables)

        // When the underlying unread / VIP lists change while we're in
        // the extended state, the panel must resize too — otherwise a
        // silence action leaves a gap of empty chrome. These sinks fire
        // on every list mutation and re-run `panelSize` in-place.
        monitor.$inboxItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        monitor.$handledItems
            .dropFirst()
            .sink { [weak self] _ in self?.resizeExtendedIfActive() }
            .store(in: &cancellables)

        // First-launch onboarding
        if store.getSetting("onboarded") == nil {
            showOnboarding()
        }

        // Start the monitor (includes initial scan + WeChat process observer).
        monitor.start()

        // Start FSEvents-based file watcher for incremental updates.
        startFSWatcher()

        // Menu bar status item
        setupMenuBarItem()

        // Forward whitelist-message previews to the banner. Any non-nil
        // publish from ChatMonitor (which, post-change, fires for every
        // new whitelist message — not just @ mentions) flips the panel
        // into .notification state for `durationSeconds`. Combine sink
        // for the same sync reason as the state observer above.
        monitor.$latestNotification
            .compactMap { $0 }
            .sink { [weak self] notif in
                guard let self = self else { return }
                let cfg = self.store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()

                // Apply notification filter toggles
                let shouldNotify: Bool
                switch notif.kind {
                case .groupAt:
                    shouldNotify = cfg.atMention
                case .privateChat:
                    if notif.attentionLevel == .vip {
                        shouldNotify = cfg.important
                    } else {
                        shouldNotify = cfg.allWhitelist
                    }
                case .groupMessage:
                    shouldNotify = cfg.allWhitelist
                }

                guard shouldNotify else { return }
                self.panelState.showNotification(duration: TimeInterval(cfg.durationSeconds))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hudAIConfigDidChange)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let cfg = self.store.loadAIConfig()
                Task {
                    await self.aiService.updateConfig(cfg)
                    await self.monitor.autopilotService?.updateConfig(cfg)
                    await self.monitor.refreshReplySuggesterConfig()
                }
            }
            .store(in: &cancellables)


        // Keyboard shortcuts — only active when the panel is key.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) ? nil : event }
        }
    }

    /// Set up menu bar status item with unread badge.
    @MainActor
    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示/隐藏 HUD", action: #selector(toggleHUD), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "刷新", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Update badge when inbox items change — show p0/p1 count, fall back
        // to total, hide badge when empty.
        monitor.$inboxItems
            .sink { [weak self] items in
                guard let self = self, let button = self.statusItem?.button else { return }
                let p0p1 = items.filter { $0.priority != .p2 }.count
                let total = items.count
                if p0p1 > 0 {
                    button.title = " \(p0p1)"
                } else if total > 0 {
                    button.title = " \(total)"
                } else {
                    button.title = ""
                }
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "message.badge.fill", accessibilityDescription: "WeChatHUD")
        button.image?.size = NSSize(width: 18, height: 18)
    }

    @objc private func toggleHUD() {
        MainActor.assumeIsolated {
            if panelState.currentState == .detail {
                panelState.collapse()
            } else {
                panelState.showDetail()
            }
        }
    }

    @objc private func refreshNow() {
        MainActor.assumeIsolated { monitor.refreshNow() }
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { panelState.showDetail() }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Show first-launch onboarding in a separate window.
    private func showOnboarding() {
        let onboardingView = OnboardingView {
            // Dismiss onboarding window
            NSApp.windows.first { $0.title == "WeChatHUD 设置向导" }?.close()
        }
        .environmentObject(store)
        .environmentObject(monitor)

        let hostingView = NSHostingView(rootView: onboardingView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WeChatHUD 设置向导"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Handle keyboard shortcuts. Returns true if the event was consumed.
    /// Called from NSEvent local monitor (always main thread).
    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Esc → collapse to compact
        if event.keyCode == 53 {
            panelState.collapse()
            return true
        }

        guard event.modifierFlags.contains(.command) else { return false }

        switch event.charactersIgnoringModifiers {
        case ",":
            panelState.showDetail()
            return true
        default:
            return false
        }
    }

    /// Resolve the target panel size for a given state. `.extended`
    /// grows to fit the tabbed VIP / 未读 view. The 未读 row count must
    /// cover whichever sub-filter could be showing the longest list —
    /// that's `max(unread, suppressed)` since the user may click into
    /// 已处理. Mirrored by `extendedTabsSize(vip:unread:)` in HUDRootView.
    @MainActor
    private func panelSize(for state: HUDState) -> (CGFloat, CGFloat) {
        switch state {
        case .compact:
            // Dynamic compact width based on inbox urgency
            let items = monitor.inboxItems
            let hasUrgent = items.contains { $0.priority != .p2 }
            if hasUrgent {
                return (380, 36)
            } else if !items.isEmpty {
                return (240, 36)
            } else {
                return (200, 36)
            }
        case .extended:
            let count = monitor.inboxItems.count
            return inboxSize(itemCount: count)
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
