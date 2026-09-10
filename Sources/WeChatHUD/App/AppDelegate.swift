import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var panelState: PanelState!
    var monitor: ChatMonitor!
    var store: HUDStore!
    var reader: WeChatReader!
    var aiService: AIService!
    var fsWatcher: FSEventsWatcher?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var wechatYieldRestoreWorkItem: DispatchWorkItem?
    private var relaunchWaitTask: Task<Void, Never>?
    /// The onboarding window is owned here instead of being looked up by
    /// title, so dismissal always targets exactly this window and a second
    /// request re-fronts it instead of stacking a duplicate.
    private var onboardingWindow: NSWindow?

    /// `@Published` fires an initial emission to every new subscriber.
    /// We ride that to position the panel on launch, but do it
    /// without animation — otherwise the 250pt placeholder
    /// `contentRect` from `FloatingPanel.init` would animate down to
    /// the real compact size and the user sees a weird "first
    /// animation" every launch.
    private var didHandleInitialStateEmission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WCHUD] launch — pid=\(ProcessInfo.processInfo.processIdentifier)")
        // Resolve the selected account before opening its business database.
        // Device AI/sync preferences are shared; no chat data is copied between accounts.
        let selectedRoot: String?
        do {
            if PreviewRuntime.isEnabled {
                store = HUDStore(dbPath: PreviewRuntime.directory + "/hud.sqlite3")
                try store.open()
                selectedRoot = PreviewRuntime.directory + "/no-wechat"
            } else {
                let bootstrap = try AccountStoreCoordinator().bootstrap()
                store = bootstrap.store
                selectedRoot = bootstrap.databaseRoot
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开助手数据"
            alert.informativeText = "账号数据或设备设置未能读取。为避免混用账号，本次启动已停止；请检查本地存储后重试。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        reader = PreviewRuntime.isEnabled
            ? WeChatReader(keysPath: PreviewRuntime.directory + "/no-keys.json", dbDir: selectedRoot, cacheStrategy: .memory)
            : WeChatReader(keysPath: syncCfg.keysFilePath, dbDir: selectedRoot ?? "", cacheStrategy: syncCfg.cacheStrategy)

        // AI config comes from the settings table — seeded on first launch
        // by HUDStore.open(). Source code never carries the endpoint URL
        // or model name; loadAIConfig() is the single read point.
        aiService = AIService(config: PreviewRuntime.isEnabled ? AIConfig() : store.loadAIConfig())

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
            .environmentObject(monitor.islandPresentation)
            .environmentObject(monitor.workspaceBadges)
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
                // Tolerance-inset test: a cursor parked on the display's top
                // scanline sits exactly on our frame's `maxY`, which plain
                // `contains` rejects — that made the panel collapse by
                // itself right after expanding under a pointer that never
                // moved.
                let inside = self.panel.containsMouse()
                AnimationDebugger.logEvent("frameAnimationEnded mouseInside=\(inside) state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(x:\(String(format: "%.1f", self.panel.frame.minX))…\(String(format: "%.1f", self.panel.frame.maxX)) y:\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
                self.panelState.frameAnimationEnded(mouseInside: inside)
            }
        }
        panel.orderFrontRegardless()

        // Hook mouse enter/exit to PanelState. PillContainerView handles
        // NSTrackingArea dispatch on the main thread — assumeIsolated is
        // safe because AppKit delivers mouse events on main.
        panel.pillContainer.onEntered = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                AnimationDebugger.logEvent("mouseEntered state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
                self.panelState.mouseEntered()
            }
        }
        panel.pillContainer.onExited = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                AnimationDebugger.logEvent("mouseExited state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
                self.panelState.mouseExited()
            }
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
                } else if state == .extended {
                    let cached = self.panelState.lastExtendedSize
                    if cached.width > 1, cached.height > 1 {
                        self.panel.animateHeight(to: cached.height, width: cached.width, caller: "AppDelegate.currentState.extended.cached")
                    } else {
                        // First hover: snap the estimate so the inbox is not
                        // clipped, then let the measurement sink run the only
                        // animation. Animating the estimate first was the bounce.
                        self.panel.setFrameInstantly(height: h, width: w)
                    }
                } else if state == .notification || state == .detail {
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
                    // Opening a conversation is an explicit editing action.
                    // A nonactivating panel can expose an AX text responder
                    // while the accessory application still lacks input focus.
                    self.panel.allowsBecomeKey = true
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.makeKeyAndOrderFront(nil)
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

        // In-place briefing card in the notification banner: keep the
        // panel frame in step with the expanded card. @Published fires
        // in willSet, so use the sink parameter (the new value) instead
        // of reading panelState.briefingExpanded, which still holds the
        // old value inside the sink.
        panelState.$measuredNotificationSize
            .dropFirst()
            .filter { [weak self] _ in self?.panelState.isReady == true }
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self else { return }
                guard self.panelState.currentState == .notification, size.height > 1 else { return }
                // The banner grew or shrank (long message, expanded
                // briefing card, snooze menu): keep the window hugging it.
                // @Published fires in willSet, so pass the sink parameter —
                // reading `measuredNotificationSize` here still yields the
                // previous height.
                self.resizeNotificationPanel(caller: "AppDelegate.measuredNotificationSize",
                                             measuredHeight: size.height)
            }
            .store(in: &cancellables)

        // Toggling the in-place briefing card or the snooze menu changes the
        // banner's height without the state machine changing; the banner's
        // own measurement above does the resizing. These sinks just make
        // sure the panel re-reads its target on the same tick.
        panelState.$briefingExpanded
            .dropFirst()
            .filter { [weak self] _ in self?.panelState.isReady == true }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resizeNotificationPanel(caller: "AppDelegate.briefingExpanded")
            }
            .store(in: &cancellables)

        panelState.$snoozeMenuExpanded
            .dropFirst()
            .filter { [weak self] _ in self?.panelState.isReady == true }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resizeNotificationPanel(caller: "AppDelegate.snoozeMenuExpanded")
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .hudIslandNeedsResize, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizeNotificationPanel(caller: "AppDelegate.islandNeedsResize")
            }
        }

        NotificationCenter.default.addObserver(
            forName: .hudShowOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }

        // Start the monitor (includes initial scan + WeChat process observer).
        if PreviewRuntime.isEnabled {
            PreviewRuntime.applyAccessibilityOverrides()
            PreviewRuntime.installCaptureBridge()
            PreviewRuntime.seed(store: store, monitor: monitor)
        } else {
            startMonitoringAfterRelaunch()
        }

        AppUpdateController.shared.bind(store: store)
        if !PreviewRuntime.isEnabled {
            AppUpdateController.shared.scheduleLaunchCheck()
        }

        // Menu bar status item
        setupMenuBarItem()
        if store.getSetting("onboarded") == nil {
            showOnboarding()
        } else if PreviewRuntime.isEnabled {
            panelState.showDetail()
            // `--preview-notification` renders the notification banner
            // immediately at launch and holds it, so the island's frame
            // and the banner's content can be captured side by side
            // without clicking anything.
            // `--preview-tasks` / `--preview-empty` do the same for the
            // inline task list and the empty inbox, so every island surface
            // can be inspected from a repeatable launch.
            if CommandLine.arguments.contains("--preview-tasks") {
                panelState.islandSurface = .tasks
                panelState.goExtended()
            }
            if CommandLine.arguments.contains("--preview-empty") {
                PreviewRuntime.simulateEmptyIsland(monitor: monitor, panelState: panelState)
            }
            if CommandLine.arguments.contains("--preview-notification") {
                // Fire the banner after the launch-time work (workspace
                // window first paint, preview data seeding) has settled — a
                // real notification never races the app's own launch, and
                // animating into that window is what made the measurement
                // log look like the motion itself was stuttering.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    // Hold the banner long enough to inspect it, then put
                    // the stored (consumer-facing) duration back so this
                    // launch flag leaves no trace in the preview settings.
                    var cfg = self.store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
                    let savedDuration = cfg.durationSeconds
                    cfg.durationSeconds = 900
                    try? self.store.setSettingJSON("notification", value: cfg)
                    PreviewRuntime.simulateNotification(monitor: self.monitor, panelState: self.panelState, longForm: true)
                    cfg.durationSeconds = savedDuration
                    try? self.store.setSettingJSON("notification", value: cfg)
                    // `--preview-briefing` performs the banner's own
                    // "看看什么事" action afterwards, so the expanded
                    // in-place card can be captured in the real panel too.
                    if CommandLine.arguments.contains("--preview-briefing") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            guard let self, let notif = self.monitor.latestNotification else { return }
                            withMotion(CompanionMotion.spring) { self.panelState.setBriefingExpanded(true) }
                            self.monitor.loadGroupContextBriefing(for: notif)
                        }
                    }
                }
            }
        }

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
                guard cfg.shouldPresent(semantic) else { return }
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

        NotificationCenter.default.publisher(for: .hudDisplayPreferenceDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .sink { [weak self] _ in
                guard let self else { return }
                let cfg = self.store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
                self.panel.displayScreen = cfg.displayScreen
                let (width, height) = self.panelSize(for: self.panelState.currentState)
                self.panel.setFrameInstantly(height: height, width: width)
                self.panelState.invalidateMeasuredSize()
            }
            .store(in: &cancellables)

        // Collapse the panel whenever WeChatLauncher is handing focus
        // to WeChat — clicks into a chat, send button, autopilot, etc.
        // Short suppression window prevents the hover tracking area from
        // immediately re-expanding if the cursor is still over our frame.
        NotificationCenter.default.publisher(for: .hudWillOpenWeChat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.temporarilyHideHUDForWeChatAutomation() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hudDidFinishWeChatAutomation)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreHUDAfterWeChatAutomation() }
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
                      self.panel.containsMouse() else { return }
                self.panelState.menuTrackingOpen = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.panelState.updateMouseInside(self.panel.containsMouse())
                self.panelState.menuTrackingOpen = false
            }
            .store(in: &cancellables)

        panelState.$islandTextInputActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    self.panel.allowsBecomeKey = true
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.makeKeyAndOrderFront(nil)
                } else if self.panelState.currentState != .detail {
                    self.panel.allowsBecomeKey = false
                }
            }
            .store(in: &cancellables)

        // Keyboard shortcuts — only active when the panel is key.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKeyDown(event) }
            return handled ? nil : event
        }

    }

    private func configureMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: CompanionProductCopy.brandName)
        application.addItem(NSMenuItem(title: CompanionProductCopy.openCompanion, action: #selector(toggleCompanionFromMenu), keyEquivalent: "1"))
        application.addItem(NSMenuItem(title: "设置…", action: #selector(openPreferences), keyEquivalent: ","))
        application.addItem(NSMenuItem(title: CompanionProductCopy.checkUpdates, action: #selector(checkForUpdates), keyEquivalent: ""))
        application.addItem(.separator())
        let quit = NSMenuItem(title: CompanionProductCopy.quitCompanion, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        application.addItem(quit)
        applicationItem.submenu = application
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "帮助")
        help.addItem(NSMenuItem(title: CompanionProductCopy.howToUse, action: #selector(openGuide), keyEquivalent: "?"))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    @objc func openGuide() {
        MainActor.assumeIsolated {
            panelState.pendingSettingsTab = "guide"
            panelState.showDetail()
        }
    }

    @objc private func openPreferences() {
        MainActor.assumeIsolated {
            panelState.pendingSettingsTab = "system"
            panelState.showDetail()
        }
    }

    /// Set up menu bar status item with unread badge.
    @MainActor
    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        if let statusItem {
            MenuBarController.shared.isCompanionOpen = { [weak self] in
                self?.panelState.currentState != .compact
            }
            MenuBarController.shared.installMenu(on: statusItem, target: self)
        }

        AppUpdateController.shared.$offer
            .combineLatest(AppUpdateController.shared.$phase)
            .receive(on: DispatchQueue.main)
            .sink { offer, _ in
                MenuBarController.shared.setUpdateVersion(offer.map { $0.version.description })
            }
            .store(in: &cancellables)

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
        monitor.$inboxItems
            .combineLatest(monitor.$vipAlertTiers)
            .sink { items, tiers in
                let compactCount = items.filter(\.surfacesInCompact).count
                let escalated = tiers.values.filter { $0 >= .t2 }
                let worstTier = escalated.max() ?? .none
                let text: String
                if worstTier >= .t2 {
                    text = " ! \(worstTier.agingLabel)"
                } else if compactCount > 9 {
                    text = " 9+"
                } else if compactCount > 0 {
                    text = " \(compactCount)"
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

    @MainActor
    private func temporarilyHideHUDForWeChatAutomation() {
        panelState.collapseAndYield(duration: 4)
        panel.orderOut(nil)

        wechatYieldRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.restoreHUDAfterWeChatAutomation()
            }
        }
        wechatYieldRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @MainActor
    private func restoreHUDAfterWeChatAutomation() {
        wechatYieldRestoreWorkItem?.cancel()
        wechatYieldRestoreWorkItem = nil
        guard panel != nil, !panel.isVisible else { return }
        panel.orderFrontRegardless()
        panel.positionAtTop()
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "message.badge.fill", accessibilityDescription: CompanionProductCopy.brandName)
        button.image?.size = NSSize(width: 18, height: 18)
    }

    @objc func toggleCompanionFromMenu() {
        MainActor.assumeIsolated {
            if panelState.currentState == .compact {
                panelState.goExtended()
            } else {
                panelState.collapse()
            }
        }
    }

    @objc func refreshNow() {
        MainActor.assumeIsolated { monitor.refreshNow() }
    }

    @objc func checkForUpdates() {
        MainActor.assumeIsolated {
            panelState.pendingSettingsTab = "preferences"
            panelState.showDetail()
            NotificationCenter.default.post(name: .hudSwitchTab, object: "preferences")
            if AppUpdateController.shared.offer == nil {
                Task { await AppUpdateController.shared.check(force: true, installIfEnabled: false) }
            }
        }
    }

    @objc func openRetrospective() {
        MainActor.assumeIsolated {
            RetrospectiveWindowManager.shared.showWindow(monitor: monitor)
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Show first-launch onboarding in a separate window.
    @objc func showOnboarding() {
        // Re-front the existing window instead of stacking duplicates.
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let onboardingView = OnboardingView {
            [weak self] in self?.closeOnboardingWindow()
        }
        .environmentObject(store)
        .environmentObject(monitor)

        let hostingView = NSHostingView(rootView: onboardingView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = CompanionProductCopy.brandName
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.contentView = hostingView
        // Keep the window object alive across close. The default
        // released-on-close behaviour frees it while AppKit still holds
        // references from the in-flight button event, which is what crashed
        // in objc_autoreleasePoolPop after an AX click.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    /// Close onboarding outside the button/AX event stack. Closing the key
    /// window synchronously from its own click handler tears down the view
    /// that is still mid-event; one main-queue hop lets the event finish.
    private func closeOnboardingWindow() {
        guard let window = onboardingWindow else { return }
        onboardingWindow = nil
        DispatchQueue.main.async {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        onboardingWindow = nil
        panelState.showDetail()
    }

    /// Handle keyboard shortcuts. Returns true if the event was consumed.
    /// Called from NSEvent local monitor (always main thread).
    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Esc → collapse to compact
        if event.keyCode == 53 {
            guard event.window === panel else { return false }
            panelState.collapse()
            return true
        }

        guard event.modifierFlags.contains(.command) else { return false }

        switch event.charactersIgnoringModifiers {
        case "1":
            panelState.pendingSettingsTab = "today"
            panelState.showDetail()
            return true
        case ",":
            panelState.pendingSettingsTab = "system"
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
    private func resizeNotificationPanel(caller: String, measuredHeight: CGFloat? = nil) {
        guard panelState.isReady, panelState.currentState == .notification else { return }
        let (w, h) = panelSize(for: .notification, notificationMeasuredHeight: measuredHeight)
        let curr = panel.frame
        guard abs(h - curr.height) >= 2 || abs(w - curr.width) >= 2 else { return }
        panel.animateHeight(to: h, width: w, caller: caller)
    }

    @MainActor
    private func panelSize(for state: HUDState, notificationMeasuredHeight: CGFloat? = nil) -> (CGFloat, CGFloat) {
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
            //
            // Height comes from the banner's own rendered size (reported
            // through `SizePreferenceKey`), so long messages, the expanded
            // briefing card and the snooze menu all fit without being
            // clipped. The static estimate is only the fallback used
            // before the first measurement of a new banner arrives.
            // `notificationMeasuredHeight` lets a `@Published` sink pass the
            // value it just received (willSet timing) instead of re-reading
            // the still-stale property.
            let measured = notificationMeasuredHeight ?? panelState.measuredNotificationSize.height
            let height = IslandNotificationLayout.panelHeight(
                measuredContentHeight: measured,
                notchHeight: notch.notchHeight,
                fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
            )
            return (max(IslandChrome.notificationMinWidth, notch.notchWidth + 240), height)
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

    /// Launch Services acknowledges the new window before the old process
    /// exits. Keep its monitor dormant until the old instance is gone so
    /// account queues and automatic sends never run in two instances here.
    @MainActor
    private func startMonitoringAfterRelaunch() {
        guard let parentPID = relaunchParent(
            arguments: CommandLine.arguments,
            currentPID: Int32(ProcessInfo.processInfo.processIdentifier)
        ), let parent = NSRunningApplication(processIdentifier: parentPID),
           parent.bundleIdentifier == Bundle.main.bundleIdentifier else {
            monitor.start()
            startFSWatcher()
            return
        }
        relaunchWaitTask = Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard !Task.isCancelled, let self else { return }
                if parent.isTerminated {
                    self.monitor.start()
                    self.startFSWatcher()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            let alert = NSAlert()
            alert.messageText = "聊天伴侣尚未完成重新打开"
            alert.informativeText = "原来的窗口仍在运行。请回到原窗口继续使用，再试一次。"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        relaunchWaitTask?.cancel()
        fsWatcher?.stop()
        monitor.stop()
        store.close()
    }
}
