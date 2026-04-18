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

    /// Cached SwiftUI-measured size of the extended inbox. Used as the
    /// target for the STATE-CHANGE animation so we don't animate to a
    /// numeric estimate and then re-animate to the measured size mid-
    /// flight (which produced the visible "dropdown stutters" the user
    /// reported).
    ///
    /// Staleness: the cache can be wrong (e.g. user expanded an
    /// ActionPanel last session but SwiftUI rebuilt @State on re-open,
    /// so content is now shorter). The measurement sink below
    /// unconditionally corrects the frame — no suppression window —
    /// so a stale cache produces a brief "overshoot + pull back"
    /// animation rather than a stuck-at-wrong-size panel.
    private var lastMeasuredExtendedSize: CGSize?

    /// Separate cache for compact state. compact and extended share
    /// the same `measuredExtendedSize` pipe (SwiftUI PreferenceKey →
    /// PanelState), but their cached target sizes MUST be stored
    /// separately — otherwise a compact→extended transition would
    /// animate the panel toward the old compact width, and vice
    /// versa, producing wrong-sized intermediate frames.
    private var lastMeasuredCompactSize: CGSize?

    /// `@Published` fires an initial emission to every new subscriber.
    /// We ride that to position the panel on launch, but do it
    /// without animation — otherwise the 250pt placeholder
    /// `contentRect` from `FloatingPanel.init` would animate down to
    /// the real compact size and the user sees a weird "first
    /// animation" every launch.
    private var didHandleInitialStateEmission = false

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
        // Insight is now embedded in SettingsView — no standalone window needed.

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

                // Sizing strategy:
                //
                // `.extended` WITHOUT a cached measurement (first-ever
                // hover this session) → skip the state-driven animation
                // entirely. SwiftUI will render the content, fire the
                // PreferenceKey, and the measurement sink below runs
                // the single correct animation from 36pt → real size.
                // This avoids the "estimate → measurement" two-stage
                // bounce the user was seeing.
                //
                // `.extended` WITH a cached measurement → animate
                // straight to cached size (smooth one-shot).
                //
                // All other states (compact / notification / detail)
                // use the regular `panelSize(for:)` targets.
                // Both .compact and .extended now self-size via
                // PreferenceKey — SwiftUI reports the natural width
                // of the rendered content, the measurement sink
                // animates the panel to match. Cached targets are
                // per-state so a cache populated in extended isn't
                // reused for compact (they have wildly different
                // dimensions).
                let stateCache: CGSize?
                switch state {
                case .extended: stateCache = self.lastMeasuredExtendedSize
                case .compact:  stateCache = self.lastMeasuredCompactSize
                default:        stateCache = nil
                }
                let drivenByMeasurement = (
                    (state == .extended || state == .compact) &&
                    stateCache == nil
                )

                let (w, h): (CGFloat, CGFloat)
                if let cached = stateCache, cached.height > 1, cached.width > 1 {
                    w = cached.width
                    h = cached.height
                } else {
                    (w, h) = self.panelSize(for: state)
                }

                // First emission on launch: snap instantly so the
                // placeholder 250×36 `contentRect` doesn't animate to
                // the real compact size.
                if !self.didHandleInitialStateEmission {
                    self.didHandleInitialStateEmission = true
                    self.panel.setFrameInstantly(height: h, width: w)
                } else if !drivenByMeasurement {
                    self.panel.animateHeight(to: h, width: w)
                }
                // else: leave the current frame alone; the measurement
                // sink will drive the one animation that matters.

                // Force the next SwiftUI measurement to re-publish by
                // resetting our locally-held size expectation. Needed
                // on EVERY transition into a measured state — compact
                // and extended both feed the same `measuredExtendedSize`
                // pipe, so without a reset the new state's rendered
                // size could match the last one and get filtered by
                // `removeDuplicates`.
                if state == .extended || state == .compact {
                    self.panelState.invalidateMeasuredSize()
                }

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

        // Both .compact and .extended self-size via SwiftUI
        // PreferenceKey. Compact reports its natural pill width
        // (left wing + notch + right wing), extended reports its
        // natural inbox height. We animate the NSPanel frame to
        // match and cache the result per-state for fast re-open.
        panelState.$measuredExtendedSize
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self = self else { return }
                let current = self.panelState.currentState
                guard current == .extended || current == .compact,
                      size.height > 1, size.width > 1 else { return }
                // Stash in the per-state cache so next transition
                // animates straight to the right target.
                switch current {
                case .extended: self.lastMeasuredExtendedSize = size
                case .compact:  self.lastMeasuredCompactSize = size
                default: break
                }
                // Tolerance — don't re-animate for sub-pixel jitter.
                // This also absorbs the common "cache matches rendered
                // content" case so we don't queue a second animation
                // on top of the state-change animation.
                let curr = self.panel.frame
                if abs(size.height - curr.height) < 2, abs(size.width - curr.width) < 2 {
                    return
                }
                self.panel.animateHeight(to: size.height, width: size.width)
            }
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

        // Collapse the panel whenever WeChatLauncher is handing focus
        // to WeChat — clicks into a chat, send button, autopilot, etc.
        // Short suppression window prevents the hover tracking area from
        // immediately re-expanding if the cursor is still over our frame.
        NotificationCenter.default.publisher(for: .hudWillOpenWeChat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.panelState.collapseAndYield() }
            }
            .store(in: &cancellables)

        // Surface launcher failures as a transient toast so the user
        // sees *why* "在微信中打开" didn't do anything, instead of
        // silently logging to /tmp/wchud_launcher.log.
        NotificationCenter.default.publisher(for: .hudLauncherFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                guard let message = notif.userInfo?["message"] as? String else { return }
                MainActor.assumeIsolated { self?.panelState.showToast(message) }
            }
            .store(in: &cancellables)

        // VIP escalation: when the engine advances a chat to T3+,
        // surface a toast on top of whatever the user is currently
        // doing. We intentionally don't auto-open the extended panel
        // — the user might be mid-typing in WeChat and we shouldn't
        // steal their attention, just tap them on the shoulder.
        monitor.$pendingEscalationBanner
            .compactMap { $0 }
            .sink { [weak self] banner in
                guard let self = self else { return }
                let label = "「\(banner.chatName)」已等你 \(banner.tier.agingLabel) — 该回一下了"
                self.panelState.showToast(label, duration: 6)
                // Consume it so a re-run of the sink doesn't re-fire.
                Task { @MainActor in self.monitor.pendingEscalationBanner = nil }
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

        // Update badge when inbox items OR VIP escalation tiers change.
        // Priority: VIP at T2+ takes over with a "!" prefix + aging,
        // otherwise show unread counts. Two publishers combined via
        // CombineLatest so either signal redraws the badge.
        monitor.$inboxItems
            .combineLatest(monitor.$vipAlertTiers)
            .sink { [weak self] items, tiers in
                guard let self = self, let button = self.statusItem?.button else { return }
                let p0p1 = items.filter { $0.priority != .p2 }.count
                let total = items.count
                // Any VIP at T2+ wins — show longest-waiting aging label
                // with a "!" prefix so the user can tell at a glance.
                let escalated = tiers.values.filter { $0 >= .t2 }
                let worstTier = escalated.max() ?? .none
                if worstTier >= .t2 {
                    button.title = " ! \(worstTier.agingLabel)"
                } else if p0p1 > 0 {
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

    /// Resolve the target panel size for a given state.
    ///
    /// All states now anchor their TOP edge to the notch — compact
    /// hugs the notch height, everything else grows downward. Width
    /// is measured as `notchWidth + 2*wingWidth` where wing width
    /// scales with content (longer AI summary = wider left wing).
    @MainActor
    private func panelSize(for state: HUDState) -> (CGFloat, CGFloat) {
        let notch = panel.notch
        switch state {
        case .compact:
            let items = monitor.inboxItems
            let hasUrgent = items.contains { $0.priority != .p2 }
            let aiTaskCount = AIActivityTracker.shared.activeTasks.count

            // Tight right wing — just enough for the buddy (18pt
            // crop) + inner padding. Previously 56pt, which left a
            // big gap between buddy and the right edge.
            let wingRight: CGFloat = 32

            // Left wing sized to the content actually rendered:
            //   idle      → priority dot (~7pt)
            //   pending   → dot + "N条待处理" text (~80pt)
            //   urgent    → dot + AI summary + overdue badge (~240pt)
            // aiTick adds 14pt (single spinner) or 38pt (sparkle pill).
            // +12pt accounts for inner HStack padding.
            let aiTickWidth: CGFloat
            if aiTaskCount == 0 {
                aiTickWidth = 0
            } else if aiTaskCount == 1 {
                aiTickWidth = 14
            } else {
                aiTickWidth = 38
            }
            let leftBase: CGFloat
            if hasUrgent {
                leftBase = 240
            } else if !items.isEmpty {
                leftBase = 80
            } else {
                leftBase = 14
            }
            let wingLeft = leftBase + aiTickWidth + 12
            let width = notch.notchWidth + wingLeft + wingRight
            return (width, notch.notchHeight)
        case .extended:
            let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
            let hasHandled = !monitor.handledItems.isEmpty
            return inboxSize(actionCount: actionCount, hasHandled: hasHandled)
        case .notification:
            // Minimal-mode preview drops out of the island: narrow
            // width (notch + some wings) with enough height for a
            // two-line preview directly below the notch.
            return (notch.notchWidth + 220, notch.notchHeight + 72)
        case .detail:
            return (PanelState.width(for: state), PanelState.height(for: state))
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

    func applicationWillTerminate(_ notification: Notification) {
        fsWatcher?.stop()
        monitor.stop()
        store.close()
    }
}
