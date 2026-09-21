import AppKit
import Combine
import SwiftUI
import QuartzCore

// MARK: - Animation debug logging (lazy)

extension AnimationDebugger {
    /// Lazy `logEvent`.
    ///
    /// `AnimationDebugger.logEvent(_:)` takes an already-built `String`, so
    /// every call site paid for the interpolation — and, in the panel's hot
    /// paths, for half a dozen `String(format:)` calls measuring mouse and
    /// window coordinates — even with `WCHUD_ANIMATION_DEBUG` unset. This
    /// entry point takes the message as an autoclosure, so when debug is off
    /// the expression is never evaluated.
    ///
    /// A separate name, not an overload: Swift prefers the exact `String`
    /// overload over an `@autoclosure () -> String` one for both a plain and an
    /// interpolated literal (measured — an overload here is dead code and the
    /// message is still built eagerly).
    static func logLazyEvent(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        emit(message())
    }

    /// Timestamp + print, split out so the gating decision is testable without
    /// a second process.
    static func emit(_ message: String) {
        let ms = Date().timeIntervalSince(debugBoot) * 1000
        print(String(format: "[ANIM] @%08.1fms %@", ms, message))
    }

    /// Mirrors the private boot stamp the value-taking `logEvent` uses, so the
    /// two entry points stamp lines on the same clock.
    private static let debugBoot = Date()
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var panelState: PanelState!

    /// Optional view of `panel` that does not trap when the IUO is still nil.
    var attachedPanel: FloatingPanel? {
        let panel: FloatingPanel? = self.panel
        return panel
    }
    var monitor: ChatMonitor!
    var store: HUDStore!
    var reader: WeChatReader!
    var aiService: AIService!
    var fsWatcher: FSEventsWatcher?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var wechatYieldRestoreWorkItem: DispatchWorkItem?
    /// Standalone toast window — the island's compositor mask clips anything
    /// painted inside the panel, so a toast in the ~312×34 compact island
    /// could never be seen. This floats just below the island instead.
    private var toastWindow: NSPanel?
    /// Generation of the in-flight hide. Hide completion must match this or
    /// a toast that arrived mid-fade would be ordered out by the stale run.
    private var toastHideGeneration: UInt64 = 0
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

    /// Install the menu bar before the first window exists.
    ///
    /// `configureMainMenu()` was written, documented and unit-tested — and never
    /// called. `MainMenuTests` builds the menu in isolation and passes, so the
    /// only thing missing was the one line that puts it on screen: a menu-bar
    /// app with no `NSApp.mainMenu` shows the app name and nothing else, and
    /// every item 关于 / 服务 / 重做 / ⌃⌘S was unreachable while the suite was
    /// green. This is the "two ends are right, the wire between them is
    /// missing" shape a previous QA round already caught once in the key-file
    /// diagnostics; `MainMenuWiringTests` now scans this file so it cannot
    /// happen a third time.
    ///
    /// `applicationWillFinishLaunching` rather than `…DidFinishLaunching`:
    /// that is the documented place to build the main menu, and it runs before
    /// any window is shown, so the first activation already has its menu.
    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WCHUD] launch — pid=\(ProcessInfo.processInfo.processIdentifier)")
        // A previous run that was killed leaves a plaintext copy of the whole
        // message store behind; `$TMPDIR` is only pruned after days of
        // non-access, and a 24/7 app keeps its own snapshots warm. Anything
        // whose owning pid is gone goes now, before this process writes any.
        WeChatReader.removeOrphanedSnapshotDirectories()
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
                AnimationDebugger.logLazyEvent("frameAnimationEnded mouseInside=\(inside) state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(x:\(String(format: "%.1f", self.panel.frame.minX))…\(String(format: "%.1f", self.panel.frame.maxX)) y:\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
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
                AnimationDebugger.logLazyEvent("mouseEntered state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
                self.panelState.mouseEntered()
            }
        }
        panel.pillContainer.onExited = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                AnimationDebugger.logLazyEvent("mouseExited state=\(self.panelState.currentState) mouse=(\(String(format: "%.1f", NSEvent.mouseLocation.x)),\(String(format: "%.1f", NSEvent.mouseLocation.y))) frame=(\(String(format: "%.1f", self.panel.frame.minY))…\(String(format: "%.1f", self.panel.frame.maxY)))")
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
                AnimationDebugger.logLazyEvent("state -> \(state)")
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
                    if IslandMeasurement.isUsableCachedSize(cached) {
                        self.panel.animateHeight(to: cached.height, width: cached.width, caller: "AppDelegate.currentState.extended.cached")
                    } else {
                        // First hover this session: do not animate to the static
                        // estimate and do not snap the width. The covering-window
                        // mask spring lays SwiftUI out once at the destination
                        // size when the measurement arrives, so an instant widen
                        // would only flash a 32 pt bar at the expanded width.
                        // `scheduleFirstHoverFallback` covers a dropped measurement.
                        self.scheduleFirstHoverFallback(width: w, height: h)
                    }
                } else if state == .compact || state == .peek {
                    // The compact frame is fully determined by notch
                    // geometry (notchWidth + 2·wingWidth × notchHeight) —
                    // it needs no SwiftUI measurement, so drive the window
                    // animation NOW. Waiting for the PreferenceKey round
                    // trip used to add a whole layout pass of dead time
                    // between "mouse out" and "pill starts retracting".
                    self.panel.animateHeight(to: h, width: w, caller: state == .peek ? "AppDelegate.currentState.peek" : "AppDelegate.currentState.compact")
                } else if state == .notification || state == .detail {
                    self.panel.animateHeight(to: h, width: w, caller: "AppDelegate.currentState.\(state)")
                }
                // In-state compact relayouts (idle → pending → urgent wing
                // width changes) still come through the measurement sink.

                // Force the next SwiftUI measurement to re-publish by
                // resetting our locally-held size expectation. Needed
                // on EVERY transition into a measured state — compact
                // and extended both feed the same `measuredExtendedSize`
                // pipe, so without a reset the new state's rendered
                // size could match the last one and get filtered by
                // `removeDuplicates`.
                if state == .extended || state == .compact || state == .peek {
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
                    let isSettings = self.panelState.selectedChatUsername == nil
                    // Settings pages follow the system scheme; a conversation is
                    // white ink on dark.
                    self.panel.setSurface(isSettings ? .systemSettings : .conversation)
                case .extended:
                    self.panel.allowsBecomeKey = false
                    self.panel.setSurface(.island)
                    self.releaseActivationIfIdle()
                case .compact, .peek, .notification:
                    self.panel.allowsBecomeKey = false
                    self.panel.setSurface(.island)
                    self.releaseActivationIfIdle()
                }
                // A state change moves the island — re-anchor a toast still
                // on screen. Once now (frame still animating) and once after
                // the spring settles (~0.4s) when visibleIslandFrame is final.
                self.syncToastWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.syncToastWindow() }
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
                guard current == .extended || current == .compact || current == .peek,
                      size.height > 1, size.width > 1 else { return }
                let targetSize: CGSize
                if current == .compact || current == .peek {
                    let (w, h) = self.panelSize(for: current)
                    targetSize = CGSize(width: w, height: h)
                } else {
                    let cover = self.panel.frame.size
                    if IslandMeasurement.isCoveringStage(size, cover: cover, lastContent: self.panelState.lastExtendedSize) {
                        AnimationDebugger.logEvent("ignore stage-sized measurement \(Int(size.width))×\(Int(size.height)) cover=\(Int(cover.width))×\(Int(cover.height))")
                        let remembered = self.panelState.lastExtendedSize
                        if IslandMeasurement.isUsableCachedSize(remembered),
                           cover.height > remembered.height + 24 {
                            targetSize = remembered
                        } else {
                            return
                        }
                    } else {
                        targetSize = IslandMeasurement.clamped(size)
                    }
                }

                AnimationDebugger.logLazyEvent("measurement current=\(current) raw=(\(String(format: "%.1f", size.width))×\(String(format: "%.1f", size.height))) target=(\(String(format: "%.1f", targetSize.width))×\(String(format: "%.1f", targetSize.height))) frame=(\(String(format: "%.1f", self.panel.frame.width))×\(String(format: "%.1f", self.panel.frame.height)))")
                // Compare against the *visible* island. During a mask-driven
                // run `panel.frame` is the covering union, so a 252 pt inbox
                // would look like it already matched a 252 pt cover and the
                // height spring would never start.
                //
                // The tolerance and the snap-vs-animate decision are pure,
                // so `IslandMeasurement.sizeAction` owns them and the tests pin
                // them without standing up an NSPanel. The rule the sink used
                // to encode by hand — "compact width jitter may snap, a
                // collapse from a taller island animates" — is the `.compact`
                // branch there. Peek is a same-height width morph and MUST NOT
                // snap: `setFrameInstantly` cancels the mask spring the morph is
                // riding, which is the stutter this split fixes. Never call
                // `setFrameInstantly` for `.peek`.
                let curr = self.panel.visibleIslandFrame ?? self.panel.frame
                let action = IslandMeasurement.sizeAction(
                    state: current,
                    visible: curr.size,
                    target: targetSize,
                    isAnimating: self.panel.isFrameAnimationRunning
                )
                switch action {
                case .ignore:
                    return
                case .animate:
                    let caller = (current == .compact || current == .peek)
                        ? "AppDelegate.compactCollapse"
                        : "AppDelegate.measuredExtendedSize"
                    self.panel.animateHeight(to: targetSize.height, width: targetSize.width, caller: caller)
                case .snapInstantly:
                    // Compact-only width changes (idle → pending → urgent)
                    // should not animate — snap instantly back to the notch
                    // center so a bad compact self-measurement cannot poison
                    // the next hover animation.
                    self.panel.setFrameInstantly(height: targetSize.height, width: targetSize.width)
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

        // Standalone windows (Settings, onboarding, retrospective) activate
        // the app on open; when the last one closes nothing released that
        // activation — the app stayed active with no key window, so typed
        // keys died and ⌘Q hit WeChatHUD. Release on every window close,
        // deferred one turn so the closing window is already out of
        // `NSApp.windows` when we re-check.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.releaseActivationIfIdle() }
            }
        }

        // Start the monitor (includes initial scan + WeChat process observer).
        if PreviewRuntime.isEnabled {
            PreviewRuntime.applyAccessibilityOverrides()
            PreviewRuntime.applyAppearanceOverride()
            PreviewRuntime.simulateHover()
            PreviewRuntime.installCaptureBridge()
            PreviewRuntime.scheduleLaunchCapture()
            PreviewRuntime.scheduleAccessibilityAudit()
            PreviewRuntime.activateForMenuCheck()
            PreviewRuntime.seed(store: store, monitor: monitor)
        } else {
            startMonitoringAfterRelaunch()
        }

        // Increase Contrast / Differentiate Without Color change how chrome is
        // drawn. NSWorkspace announces both on its own notification centre,
        // which SwiftUI does not observe; the bridge re-posts them where the
        // workspace and island roots are listening.
        CompanionAccessibility.installSystemBridge()

        AppUpdateController.shared.bind(store: store)
        if !PreviewRuntime.isEnabled {
            AppUpdateController.shared.scheduleLaunchCheck()
        }

        // Menu bar status item
        setupMenuBarItem()
        if store.getSetting("onboarded") == nil {
            showOnboarding()
        } else if PreviewRuntime.isEnabled {
            if CommandLine.arguments.contains("--preview-peek") {
                PreviewRuntime.runPeekMorphCapture(panelState: panelState)
            } else {
                // `--preview-transitions` measures every island transition
                // (hover in/out, peek, expand, row expand, collapse, banner)
                // and writes frame timing per leg, so acceptance covers the
                // interactions the pointer actually triggers rather than the
                // one path `--preview-peek` drives.
                if CommandLine.arguments.contains("--preview-transitions") {
                    PreviewRuntime.runTransitionMeasurement(monitor: monitor, panelState: panelState)
                }
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
            // `--preview-cycle=N` runs N hover expand/collapse cycles from
            // inside the app so motion can be measured without touching the
            // operator's pointer or a second display.
            let cyclePrefix = "--preview-cycle="
            if let raw = CommandLine.arguments.first(where: { $0.hasPrefix(cyclePrefix) }),
               let count = Int(raw.dropFirst(cyclePrefix.count)) {
                PreviewRuntime.startAnimationCycle(monitor: monitor, panelState: panelState, count: count)
            }
            if CommandLine.arguments.contains("--preview-notification") {
                // Fire the banner after the launch-time work (workspace
                // window first paint, preview data seeding) has settled — a
                // real notification never races the app's own launch, and
                // animating into that window is what made the measurement
                // log look like the motion itself was stuttering.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    // Hold the banner long enough to inspect it. The hold is
                    // passed straight to the presentation call instead of
                    // being written into (and restored from) the stored
                    // notification setting: when the preview process was
                    // killed mid-hold, the restore never ran and a
                    // 900-second duration stayed behind in the preview
                    // database, making later launches look as if the banner
                    // ignored further clicks.
                    PreviewRuntime.simulateNotification(
                        monitor: self.monitor, panelState: self.panelState,
                        longForm: true, holdSeconds: 900
                    )
                    // `--preview-briefing` performs the banner's own body
                    // action (a click anywhere on the card) afterwards, so the
                    // expanded in-place card can be captured in the real panel
                    // too.
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

        panelState.$toastMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.syncToastWindow() }
            }
            .store(in: &cancellables)

        panelState.$islandTextInputActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Read the CURRENT value, not the delivered one: a true→false
                // pair queued in one runloop turn would otherwise run
                // makeKeyAndOrderFront on an already-collapsed panel. Re-reading
                // makes both deliveries converge on the latest state.
                if self.panelState.islandTextInputActive {
                    self.panel.allowsBecomeKey = true
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.makeKeyAndOrderFront(nil)
                } else if self.panelState.currentState != .detail {
                    self.panel.allowsBecomeKey = false
                    self.releaseActivationIfIdle()
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
        let registration = MainMenu.build(target: self)
        NSApp.mainMenu = registration.menu
        // Each of these three is a separate handshake with AppKit: the system
        // discovers services for the Services menu, appends the open-window
        // list to the Window menu, and attaches the Help search field. None of
        // it happens from `mainMenu` alone.
        NSApp.servicesMenu = registration.services
        NSApp.windowsMenu = registration.windows
        NSApp.helpMenu = registration.help
    }

    @objc func openGuide() {
        MainActor.assumeIsolated {
            panelState.pendingSettingsTab = "guide"
            panelState.showDetail()
        }
    }

    /// 设置… (⌘,) — bring the workspace window forward.
    ///
    /// It deliberately does not force a tab. The item's first job is what every
    /// Mac user expects from ⌘,: open the settings window. It used to jump to
    /// 微信连接 as well, so pressing ⌘, from 待办 threw away the page the user
    /// was on and dropped them into a connection screen with side effects —
    /// the same behaviour as `openGuide` (⌘?), which is a *destination* item
    /// and therefore right to pick its own page.
    @objc func openPreferences() {
        MainActor.assumeIsolated {
            panelState.showDetail()
        }
    }

    /// ⌃⌘S — show or hide the workspace sidebar.
    ///
    /// The window is a SwiftUI `NavigationSplitView` and only the view knows
    /// its current column visibility, so the menu item forwards the intent
    /// rather than flipping a flag here. Two reasons not to call
    /// `toggleSidebar:` through the responder chain instead: SwiftUI's
    /// split view does not claim that selector, and an item that does nothing
    /// when pressed is worse than no item.
    @objc func toggleSidebar() {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name: .hudToggleSidebar, object: nil)
        }
    }

    /// Set up menu bar status item with unread badge.
    @MainActor
    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        if let statusItem {
            MenuBarController.shared.isCompanionOpen = { [weak self] in
                // Peek is still a collapsed notch pill: it shows none of the
                // inbox. Counting it as "open" made the menu read 收起 while
                // the user was only hovering, and let ChatMonitor's action
                // prefetch warm data nobody could see. Only a state that has
                // actually left the notch is open.
                guard let state = self?.panelState.currentState else { return false }
                return state == .extended || state == .notification || state == .detail
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
        // At VIP T2+ the badge also shows the longest wait ("等 4 小时+");
        // otherwise it's just the pending count. The string itself lives
        // in CompanionProductCopy.menuBarBadge so it's unit-testable.
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
                let worstTier = tiers.values.max() ?? .none
                MenuBarController.shared.badgeText = CompanionProductCopy.menuBarBadge(
                    pendingCount: compactCount, longestWait: worstTier
                )
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

        // Preview island overrides go *after* `isReady`, not with the rest of
        // the preview setup.
        //
        // They expand the island, and the expanded island's size comes from its
        // content's own `SizePreferenceKey` report — which the sink above drops
        // while `isReady` is false. Called early, the flag therefore produced a
        // panel at the fallback size with an unpainted body: a black slab.
        // A QA pass measured that slab, could not reconcile it with the AX dump,
        // and nearly filed it as a product bug (the real peek/click path renders
        // correctly). A preview flag that manufactures the defect it is supposed
        // to photograph is worse than no flag.
        if PreviewRuntime.isEnabled {
            PreviewRuntime.applyIslandSnapshotOverrides(monitor: monitor, panelState: panelState)
            PreviewRuntime.applyIslandDetailOverride(panelState: panelState)
            PreviewRuntime.applyRetrospectiveOverride(monitor: monitor)
            PreviewRuntime.applyWorkspaceTabOverride(panelState: panelState)
            PreviewRuntime.applyWindowWidthOverride()
            PreviewRuntime.applyWorkspaceScrollOverride()
        }
    }

    /// Show/hide the standalone toast window to match `toastMessage`.
    /// Held while the panel is ordered out (WeChat automation) — a toast
    /// popping over WeChat mid-send would be worse than a delayed one.
    @MainActor
    private func syncToastWindow() {
        let wantsVisible = panelState.toastMessage != nil
        let windowVisible = toastWindow?.isVisible == true
        let panelVisible = panel.isVisible
        let action = CompanionMotion.toastWindowAction(
            windowVisible: windowVisible,
            wantsVisible: wantsVisible,
            panelVisible: panelVisible
        )
        switch action {
        case .snapHide:
            toastHideGeneration &+= 1
            panelState.toastCollapsing = false
            toastWindow?.alphaValue = 1
            toastWindow?.orderOut(nil)
        case .animateHide:
            dismissToastAnimated()
        case .snapShow, .animateShow, .retarget:
            guard let message = panelState.toastMessage else { return }
            presentToast(message, action: action)
        }
    }

    @MainActor
    private func presentToast(_ message: String, action: CompanionMotion.ToastWindowAction) {
        toastHideGeneration &+= 1
        if toastWindow == nil { toastWindow = makeToastPanel() }
        guard let toastWindow else { return }

        let host = NSHostingView(
            rootView: IslandToastContent(message: message, playsEnter: action == .animateShow)
                .environmentObject(panelState)
                .environmentObject(monitor)
        )
        toastWindow.contentView = host
        let fitting = host.fittingSize
        let size = NSSize(
            width: min(400, max(160, fitting.width)),
            height: max(30, fitting.height)
        )
        // Hang just below the island's painted rect — already in SCREEN
        // coordinates (containsMouse compares it directly against
        // NSEvent.mouseLocation). Fall back to below the panel frame when
        // no island is painted.
        let islandScreen = panel.visibleIslandFrame ?? panel.frame
        let origin = NSPoint(
            x: islandScreen.midX - size.width / 2,
            y: islandScreen.minY - 6 - size.height
        )
        toastWindow.setFrame(NSRect(origin: origin, size: size), display: true)
        if action == .animateShow {
            panelState.toastCollapsing = false
            toastWindow.alphaValue = 0
            toastWindow.orderFrontRegardless()
            animateToastAlpha(to: 1, duration: CompanionMotion.enterDuration)
        } else {
            panelState.toastCollapsing = false
            toastWindow.alphaValue = 1
            toastWindow.orderFrontRegardless()
        }
    }

    @MainActor
    private func dismissToastAnimated() {
        guard let toastWindow, toastWindow.isVisible else { return }
        toastHideGeneration &+= 1
        let generation = toastHideGeneration
        panelState.toastCollapsing = true
        animateToastAlpha(to: 0, duration: CompanionMotion.exitDuration) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.toastHideGeneration else { return }
                guard self.panelState.toastMessage == nil else { return }
                self.panelState.toastCollapsing = false
                self.toastWindow?.orderOut(nil)
                self.toastWindow?.alphaValue = 1
            }
        }
    }

    @MainActor
    private func animateToastAlpha(to value: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            self.toastWindow?.animator().alphaValue = value
        }, completionHandler: completion)
    }

    private func makeToastPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }

    @MainActor
    private func temporarilyHideHUDForWeChatAutomation() {
        // Order out BEFORE collapsing.
        //
        // `collapseAndYield` swaps the state to `.compact`, and the state sink
        // answers that with a frame spring. A spring on an ordered-out panel
        // cannot tick (see `FloatingPanel.canDisplayFrameAnimation`), so
        // starting it first froze the run at the *expanded* rect and left that
        // rect in the compositor mask. Coming back four seconds later,
        // `positionAtTop` re-anchored the same oversized island and the panel
        // painted as a black plate the size of its grow-only stage — with the
        // inbox still inside it, which is exactly what the bug report shows.
        // Hidden first, the collapse lands instantly and the mask is already
        // the compact pill before WeChat takes focus.
        panel.orderOut(nil)
        toastHideGeneration &+= 1
        toastWindow?.alphaValue = 1
        toastWindow?.orderOut(nil)
        panelState.collapseAndYield(duration: 4)

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
        // A toast posted while the panel was ordered out never painted; its
        // 4s timer kept running, so re-arm it before showing the island.
        if let pending = panelState.toastMessage {
            panelState.showToast(pending)
        }
        // The island has to be the one the CURRENT state owns before the window
        // is on screen again. The frame the panel carries is the grow-only
        // stage; what the user sees is a compositor mask inside it, and a
        // hide/show cycle must re-derive that mask from the state rather than
        // trust whatever rect it was holding when the window went away.
        settleIslandForCurrentState()
        panel.orderFrontRegardless()
        panel.positionAtTop()
        syncToastWindow()
    }

    /// Land the panel on the island its current state owns, with no motion.
    ///
    /// Only for the order-back-in path: the panel is still hidden when this
    /// runs, so nothing is animated by snapping and nothing is visible until
    /// `orderFrontRegardless` a line later.
    @MainActor
    private func settleIslandForCurrentState() {
        switch panelState.currentState {
        case .compact, .peek, .notification, .detail:
            // Notch geometry (compact/peek) or a static estimate
            // (notification/detail) fully determines these — no SwiftUI
            // measurement is needed for the window to be right.
            let (width, height) = panelSize(for: panelState.currentState)
            panel.setFrameInstantly(height: height, width: width)
        case .extended:
            // Measurement-driven: reuse the last real inbox size when there is
            // one. Without one the island is left for the next SwiftUI report,
            // which `invalidateMeasuredSize` on the transition has already
            // primed to arrive.
            let cached = panelState.lastExtendedSize
            guard IslandMeasurement.isUsableCachedSize(cached) else { return }
            panel.setFrameInstantly(height: cached.height, width: cached.width)
        }
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "message.badge.fill", accessibilityDescription: CompanionProductCopy.brandName)
        button.image?.size = NSSize(width: 18, height: 18)
    }

    @objc func toggleCompanionFromMenu() {
        MainActor.assumeIsolated {
            if panelState.currentState == .compact || panelState.currentState == .peek {
                panelState.goExtended()
            } else {
                panelState.collapse()
            }
        }
    }

    @objc func refreshNow() {
        MainActor.assumeIsolated {
            monitor.refreshNow()
            panelState.showNewMessages()
        }
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
        // Keep the reference until close() actually runs — between nil-ing
        // and the queued close, a reposted .hudShowOnboarding would stack a
        // second onboarding window while the first is still tearing down.
        // windowWillClose clears the reference itself during close().
        DispatchQueue.main.async {
            window.close()
            // Completing onboarding continues into the detail/settings
            // surface. (windowWillClose cannot own this — an early ✕-close
            // must NOT open settings, only the completion path may.)
            MainActor.assumeIsolated { [weak self] in
                self?.panelState.showDetail()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        onboardingWindow = nil
    }

    /// Handle keyboard shortcuts. Returns true if the event was consumed.
    /// Called from NSEvent local monitor (always main thread).
    ///
    /// Only *cancel* is claimed here. Command chords belong to the menu bar:
    /// this monitor runs first and a `true` return swallows the event, so
    /// claiming ⌘1 / ⌘, here made the menu items that advertise those chords
    /// (显示 > 打开 WeChatHUD, 设置…) unreachable and did something else
    /// instead. Which keys are cancel, and what cancel means per window, is
    /// `KeyboardShortcutPolicy` — a pure function, so it is testable.
    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let target: KeyboardShortcutPolicy.Target
        if event.window === panel {
            target = .island
        } else if event.window is SettingsWindow {
            target = .workspace
        } else {
            target = .other
        }

        switch KeyboardShortcutPolicy.action(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            target: target,
            hasAttachedSheet: event.window?.attachedSheet != nil,
            // CompanionDialog lives inside the island panel — only gate
            // cancel for events targeting THAT window. A dialog open in the
            // island must not kill Escape in Settings (and vice versa).
            hasModalOverlay: panelState.modalDialogOpen && event.window === panel
        ) {
        case .collapseIsland:
            panelState.collapse()
            return true
        case .closeWorkspace:
            event.window?.performClose(nil)
            return true
        case nil:
            return false
        }
    }

    /// Activation grabbed for `.detail`/text input must be released on the
    /// way out — `resignKey()` alone leaves WeChatHUD the active app with no
    /// key window, so typed keys die and ⌘Q hits the HUD instead of the
    /// user's app. Deactivate only when no other HUD window can take key
    /// (Settings/Insight/Retrospective stay foreground while open).
    @MainActor
    private func releaseActivationIfIdle() {
        guard NSApp.isActive else { return }
        // The panel is excluded EXCEPT when it's legitimately key-capable:
        // in .detail / text-input the island holds activation on purpose, so
        // a secondary window closing (onboarding, a sheet) must not rip
        // activation away from it.
        let anotherWindowCanTakeKey = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey
                && (window !== panel || panel.allowsBecomeKey)
        }
        if !anotherWindowCanTakeKey {
            NSApp.deactivate()
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
        let curr = panel.visibleIslandFrame ?? panel.frame
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
        case .peek:
            // Same height as compact. Outboard glance slots grow the
            // silhouette without opening the inbox. Width is geometric
            // so a count change cannot jitter the morph.
            let width = notch.notchWidth
                + CompactInboxMetrics.wingWidth * 2
                + IslandChrome.peekSlotWidth * 2
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
            return (IslandNotificationLayout.panelWidth(notchWidth: notch.notchWidth), height)
        case .detail:
            return (PanelState.width(for: state), PanelState.height(for: state))
        }
    }

    /// Safety net for a first-hover whose SwiftUI measurement never arrives
    /// (e.g. `isReady` still false drops it in the measurement sink): after
    /// 0.25 s, fall back to the static estimate so the panel can never be
    /// stranded as a widened 32 pt bar. When the measurement did arrive the
    /// pipe is non-zero and this is a no-op — the single height spring owns
    /// the run and must not be bent by a stale estimate.
    private func scheduleFirstHoverFallback(width: CGFloat, height: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.panelState.currentState == .extended,
                  self.panelState.measuredExtendedSize.height <= 1 else { return }
            self.panel.animateHeight(to: height, width: width, caller: "AppDelegate.currentState.extended.estimatedFallback")
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
            alert.messageText = "WeChatHUD 尚未完成重新打开"
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
        // After `stop()`, so no scan is mid-read on a file being unlinked. The
        // per-instance `deinit` only covers whichever reader happens to be
        // released, and this process may have made snapshots under several.
        WeChatReader.removeOwnSnapshotDirectories()
    }
}
