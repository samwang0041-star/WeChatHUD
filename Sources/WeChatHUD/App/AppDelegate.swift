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

        panel = FloatingPanel(contentView: hostingView, displayScreen: syncCfg.displayScreen)
        panel.positionAtTop()
        panel.onFrameAnimationStarted = { [weak self] in
            MainActor.assumeIsolated {
                self?.panelState.frameAnimationStarted()
            }
        }
        panel.onFrameAnimationEnded = { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.panelState.frameAnimationEnded(mouseInside: self.panel.frame.contains(NSEvent.mouseLocation))
            }
        }
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
        // the `state` parameter (the new value) instead of reading
        // `panelState.currentState` which still holds the old value.
        panelState.$currentState
            .sink { [weak self] state in
                guard let self = self else { return }
                AnimationDebugger.logEvent("state -> \(state)")
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
                // `.compact` and `.extended` are measurement-driven:
                // SwiftUI renders the content, reports its natural size
                // via PreferenceKey, and the measurement sink animates
                // the panel frame to match. The state sink only snaps
                // the initial frame on launch (to avoid animating from
                // the 320×32 placeholder `contentRect`).
                let (w, h) = self.panelSize(for: state)

                // First emission on launch: snap instantly so the
                // placeholder 320×32 `contentRect` doesn't animate to
                // the real compact size.
                if !self.didHandleInitialStateEmission {
                    self.didHandleInitialStateEmission = true
                    self.panel.setFrameInstantly(height: h, width: w)
                } else if state == .extended || state == .notification || state == .detail {
                    // Start the resize synchronously with the state change.
                    // Extended still accepts the later SwiftUI measurement,
                    // but this first target prevents the 420pt inbox from
                    // rendering for one frame inside the old compact window.
                    self.panel.animateHeight(to: h, width: w, caller: "AppDelegate.currentState.\(state)")
                }
                // compact is left for the measurement sink to drive because
                // its layout can change while idle/pending/urgent content
                // updates inside the same state.

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
                // `.extended` stays non-key too. FirstMouseHostingView
                // accepts the click so SwiftUI buttons and row gestures
                // still work, but a passive row click must not steal key
                // focus from the app the user was typing in.
                switch state {
                case .detail:
                    self.panel.allowsBecomeKey = true
                    self.panel.makeKey()
                    // Use light appearance for settings, dark for conversation detail
                    let isSettings = self.panelState.selectedChatUsername == nil
                    self.panel.setDetailAppearance(isSettings)
                case .extended:
                    self.panel.allowsBecomeKey = false
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
        // natural inbox height. We animate the NSPanel frame to match.
        panelState.$measuredExtendedSize
            .dropFirst()
            .filter { [weak self] _ in self?.panelState.isReady == true }
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self = self else { return }
                let current = self.panelState.currentState
                guard current == .extended || current == .compact,
                      size.height > 1, size.width > 1 else { return }
                let targetSize: CGSize
                if current == .compact {
                    let (w, h) = self.panelSize(for: .compact)
                    targetSize = CGSize(width: w, height: h)
                } else {
                    targetSize = size
                }

                AnimationDebugger.logEvent("measurement current=\(current) raw=(\(String(format: "%.1f", size.width))×\(String(format: "%.1f", size.height))) target=(\(String(format: "%.1f", targetSize.width))×\(String(format: "%.1f", targetSize.height))) frame=(\(String(format: "%.1f", self.panel.frame.width))×\(String(format: "%.1f", self.panel.frame.height)))")
                // Tolerance — don't re-animate for sub-pixel jitter.
                let curr = self.panel.frame
                if abs(targetSize.height - curr.height) < 2, abs(targetSize.width - curr.width) < 2 {
                    return
                }
                if current == .compact {
                    if curr.height > targetSize.height + 8 {
                        // Real collapse from extended → compact: animate it.
                        self.panel.animateHeight(to: targetSize.height, width: targetSize.width, caller: "AppDelegate.compactCollapse")
                    } else {
                        // Compact-only width changes (idle → pending → urgent)
                        // should not animate — snap instantly back to the
                        // notch center so a bad compact self-measurement
                        // cannot poison the next hover animation.
                        self.panel.setFrameInstantly(height: targetSize.height, width: targetSize.width)
                    }
                } else {
                    self.panel.animateHeight(to: targetSize.height, width: targetSize.width, caller: "AppDelegate.measuredExtendedSize")
                }
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

                // Apply notification filter toggles through the Stage 1
                // presentation semantics. Raw group @ is FYI unless a
                // later action item supplies ask/action evidence.
                let semantic = notif.presentationSemanticState
                let shouldNotify: Bool = {
                    switch semantic {
                    case .privateVIPRisk:
                        return cfg.important
                    case .groupMentionFYI:
                        return cfg.atMention && (notif.attentionLevel == .vip || cfg.allWhitelist)
                    case .privateInfoOnly, .groupInfoOnly:
                        return cfg.allWhitelist
                    default:
                        return false
                    }
                }()

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

        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self,
                      self.panelState.currentState == .extended,
                      self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.panelState.popoverOpen = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.panelState.updateMouseInside(self.panel.frame.contains(NSEvent.mouseLocation))
                self.panelState.popoverOpen = false
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
        menu.addItem(NSMenuItem(title: "打开复盘…", action: #selector(openRetrospective), keyEquivalent: "R"))
        menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Update badge when inbox items OR VIP escalation tiers change.
        // Priority: VIP at T2+ takes over with a "!" prefix + aging,
        // otherwise show unread counts. Two publishers combined via
        // CombineLatest so either signal redraws the badge.
        //
        // Plan M6.1: instead of writing directly to statusItem.button.title
        // (which would race with MenuBarController's spinner overlay during
        // retrospective jobs), we feed the computed string into
        // MenuBarController.shared.badgeText. The controller renders it
        // when no job is running and replaces it with a spinner otherwise.
        if let statusItem { MenuBarController.shared.attach(statusItem) }
        monitor.$inboxItems
            .combineLatest(monitor.$vipAlertTiers)
            .sink { items, tiers in
                let p0p1 = items.filter { $0.priority != .p2 }.count
                let total = items.count
                let escalated = tiers.values.filter { $0 >= .t2 }
                let worstTier = escalated.max() ?? .none
                let text: String
                if worstTier >= .t2 {
                    text = " ! \(worstTier.agingLabel)"
                } else if p0p1 > 0 {
                    text = " \(p0p1)"
                } else if total > 0 {
                    text = " \(total)"
                } else {
                    text = ""
                }
                MenuBarController.shared.badgeText = text
            }
            .store(in: &cancellables)

        // Plan M6.1: also subscribe to RetrospectiveJob state so the
        // controller can swap to / from the spinner overlay.
        monitor.retrospectiveJob.$state
            .sink { state in
                MenuBarController.shared.jobState = state
            }
            .store(in: &cancellables)

        // Mark the panel geometry as fully configured. Until this point
        // the measurement sink ignores any SwiftUI size reports to avoid
        // reacting to stale geometry produced during window creation.
        panelState.isReady = true
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

    @objc private func openRetrospective() {
        MainActor.assumeIsolated {
            RetrospectiveWindowManager.shared.showWindow(monitor: monitor)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        // Ensure we read the freshest notch geometry — the cached
        // `panel.notch` may be stale (initial placeholder or from a
        // previous screen) and using it produces a width/height
        // mismatch against the SwiftUI-measured content.
        panel.refreshNotchGeometry()
        let notch = panel.notch
        switch state {
        case .compact:
            // Compact is an ambient notch-integrated state, not a
            // readable message preview. Keep both wings equal-width so
            // the middle void remains physically aligned with the
            // hardware notch; message text appears only after hover.
            let width = notch.notchWidth + CompactInboxMetrics.wingWidth * 2
            return (width, notch.notchHeight)
        case .extended:
            let actionCount = monitor.inboxItems.filter { $0.participatesInActionQueue }.count
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
