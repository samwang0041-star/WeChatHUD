import AppKit
import QuartzCore
import SwiftUI
import simd

/// NSView subclass that owns a single persistent mouse tracking area and
/// forwards enter/exit events via closures. Needed because NSTrackingArea
/// only dispatches to NSResponder-class owners — AppDelegate (NSObject)
/// silently drops the events.
///
/// The tracking area is added **once** at init with `.inVisibleRect`, so
/// AppKit auto-syncs its rect with the view's bounds across resizes. We
/// must NOT override `updateTrackingAreas` and re-create the area on every
/// bounds change — that would fire spurious exited/entered pairs during
/// the spring animation, causing the pill to flicker between states.
final class PillContainerView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTrackingArea()
    }

    /// Make the very first click on the pill dispatch through AppKit's
    /// responder chain immediately instead of being swallowed as a
    /// window-activation click. This override has to exist on EVERY
    /// view in the hit-test chain — the deepest hit view is the one
    /// AppKit asks about, and that's inside the hosted SwiftUI tree
    /// (see `FirstMouseHostingView` below).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func installTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        if let window, IslandHitTest.contains(frame: window.frame, point: NSEvent.mouseLocation) {
            return
        }
        onExited?()
    }
}

/// NSHostingView subclass that accepts first-mouse. Clicks landing on
/// any SwiftUI-rendered subview bubble up to here for the first-mouse
/// poll, so the host returning `true` is enough to bypass AppKit's
/// window-activation-swallow behavior for the whole SwiftUI tree.
final class FirstMouseHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        sizingOptions = []
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    /// The floating window frame is animated manually by `FloatingPanel`.
    /// `NSHostingView` normally exposes SwiftUI's current intrinsic size
    /// (for example the 420pt-wide extended inbox) to AppKit Auto Layout.
    /// If the hosting view keeps that intrinsic size, `NSPanel.setFrame`
    /// refuses intermediate animation sizes and jumps straight to the
    /// final width/height on the first tick. Returning no intrinsic metric
    /// lets the panel own its frame while SwiftUI content clips/layouts
    /// inside whatever size the animation has reached.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: 1, height: 1)
    }
}

/// A floating NSPanel rendered as a Dynamic Island-style pill that
/// wraps the notch on MacBooks, and emulates the same silhouette on
/// external / non-notched displays. In compact state the panel's
/// height equals the notch height and its middle span is aligned
/// with the physical cutout so only the left/right "wings" of the
/// pill read as visible UI. Expanded states grow DOWNWARD from the
/// notch — the top edge stays locked to `screen.frame.maxY`.
class FloatingPanel: NSPanel {
    /// The pill-shaped container view. Exposed so AppDelegate can hook up
    /// the mouse enter/exit closures to PanelState.
    let pillContainer: PillContainerView

    init(contentView: NSView, displayScreen: DisplayScreen = .builtIn) {
        // Allocate the container before super.init so we can assign self.pillContainer.
        let container = PillContainerView()
        self.pillContainer = container

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // `.popUpMenu` (level 101) paints above the menu bar on
        // every macOS configuration we've tested. `.statusBar` (25)
        // theoretically sits above `.mainMenu` (24), but some setups
        // still clip floating panels to `visibleFrame` — leaving a
        // ~25pt gap between our pill and the physical screen top
        // that breaks the "island continues out of the notch"
        // illusion. Overriding to pop-up-menu level is the simplest
        // reliable fix.
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.minSize = NSSize(width: 1, height: 1)
        self.contentMinSize = NSSize(width: 1, height: 1)
        // No drop shadow — the pill's top edge is flush with the
        // hardware notch, and a shadow would paint a visible halo
        // above/around the notch that breaks the "island" illusion.
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Container is now a transparent host — the island
        // silhouette (pill with a notch cutout at top-center) is
        // drawn by SwiftUI via `IslandShape` as the root view's
        // background. Keeping the AppKit layer transparent lets
        // the notch cutout show whatever's behind the panel on
        // external displays, mirroring the hardware cutout on
        // notched Macs.
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        container.layer?.masksToBounds = false

        // Set a window appearance so SwiftUI controls render correctly in the
        // dark pill states. The detail (settings) state will override this.
        self.appearance = NSAppearance(named: .darkAqua)
        self.displayScreen = displayScreen

        // Wire ourselves into AppDelegate BEFORE adding the SwiftUI
        // hosting view. NSHostingView can trigger layout on addSubview,
        // at which point CompactInboxBar reads app.panel.notchWidth.
        // If app.panel is still nil it falls back to the placeholder 200,
        // producing a bogus first measurement that later bounces.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.panel = self
        }

        // Refresh notch so the first SwiftUI render sees real geometry.
        refreshNotchGeometry()

        container.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: container.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.contentView = container
        positionAtTop()
    }

    /// Which screen preference to use — updated from settings.
    var displayScreen: DisplayScreen = .builtIn

    /// Resolve the target screen based on the displayScreen preference.
    var targetScreen: NSScreen {
        let mapped = NSScreen.screens.map { screen -> (NSScreen, IslandScreenPolicy.Candidate) in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let isBuiltIn = number.map { CGDisplayIsBuiltin(CGDirectDisplayID($0.uint32Value)) != 0 } ?? false
            return (screen, IslandScreenPolicy.Candidate(
                id: number?.intValue ?? 0,
                isBuiltIn: isBuiltIn,
                hasNotch: screen.safeAreaInsets.top > 0,
                name: screen.localizedName
            ))
        }
        let picked = IslandScreenPolicy.pick(preference: displayScreen, screens: mapped.map(\.1))
        return mapped.first(where: { $0.1 == picked })?.0 ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Cached geometry of the target screen's notch. Refreshed on
    /// every reposition so moving the panel to a different display
    /// or changing the display configuration picks up the new
    /// notch/fake-notch metrics.
    private(set) var notch: NotchGeometry = NotchGeometry(
        hasRealNotch: false, notchWidth: 200, notchHeight: 32, notchCenterX: 0
    )

    /// Refresh `notch` from the current `targetScreen`. Cheap.
    func refreshNotchGeometry(caller: String = #function) {
        notch = NotchGeometry.detect(on: targetScreen)
    }

    /// Position the panel with its top edge flush against the
    /// screen's top edge, horizontally centered on the notch (real
    /// or fake). On notched Macs the compact-height pill's middle
    /// span then disappears under the hardware cutout; on external
    /// screens the same positioning produces a notch-silhouette
    /// look. Expansions always grow downward — the top edge is
    /// locked, so the animation visually "drops out" of the island.
    func positionAtTop() {
        refreshNotchGeometry()
        let panelWidth = frame.width
        let x = notch.notchCenterX - panelWidth / 2
        let y = targetScreen.frame.maxY - frame.height
        setFrameOrigin(NSPoint(x: x, y: y))
        recordIslandScreenIfPreviewing()
    }

    private func recordIslandScreenIfPreviewing() {
        guard PreviewRuntime.isEnabled else { return }
        let screen = targetScreen
        let payload: [String: Any] = [
            "screen": screen.localizedName,
            "hasRealNotch": notch.hasRealNotch,
            "notchWidth": notch.notchWidth,
            "notchHeight": notch.notchHeight,
            "notchCenterX": notch.notchCenterX,
            "panelX": frame.minX,
            "panelY": frame.minY,
            "panelW": frame.width,
            "panelH": frame.height,
            "screenX": screen.frame.minX,
            "screenY": screen.frame.minY,
            "screenW": screen.frame.width,
            "screenH": screen.frame.height,
            "preference": displayScreen.rawValue
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechathud-island-screen.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    private var animationTimer: Timer?
    private var animationDisplayLink: CADisplayLink?
    private var animationRun: SpringRun?
    var onFrameAnimationStarted: (() -> Void)?
    var onFrameAnimationEnded: (() -> Void)?

    /// One frame-animation pass, modelled as four damped springs — one per
    /// frame component (x, y, width, height). Velocity is kept across
    /// retargets: when a new target arrives mid-flight we swap `target`
    /// and keep integrating from the live velocity, so the trajectory
    /// bends smoothly instead of stopping and restarting from zero.
    private struct SpringRun {
        var target: NSRect
        var velocity: SIMD4<Double>   // x, y, w, h — pt per second
        var expanding: Bool
        var lastTimestamp: CFTimeInterval
        /// Refreshed on retarget: the wedge cap protects a wedged run,
        /// not a healthy one that just received a new goal.
        var startedWallClock: Date
    }

    private static func components(of rect: NSRect) -> SIMD4<Double> {
        SIMD4(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private static func rect(from v: SIMD4<Double>) -> NSRect {
        NSRect(x: v.x, y: v.y, width: v.z, height: v.w)
    }

    /// Is `point` (global Cocoa coordinates) inside the panel?
    ///
    /// `NSRect.contains` treats the `maxY` edge as exclusive, and the
    /// whole point of this panel is to sit *on* the top edge of the
    /// display. A cursor pushed against the top of the screen therefore
    /// reports as outside, which used to make the expand animation settle
    /// with "mouse outside" and trigger a spurious auto-collapse while the
    /// user's pointer never moved. Inset the rect instead of testing the
    /// raw frame.
    func containsMouse(_ point: NSPoint = NSEvent.mouseLocation, tolerance: CGFloat = 2) -> Bool {
        IslandHitTest.contains(frame: frame, point: point, tolerance: tolerance)
    }

    /// True while a frame animation is in flight (display link or the
    /// timer fallback).
    var isFrameAnimationRunning: Bool { animationDisplayLink != nil || animationTimer != nil }

    private func cancelFrameAnimation(notify: Bool = true) {
        guard isFrameAnimationRunning else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        animationRun = nil
        if notify {
            onFrameAnimationEnded?()
        }
    }

    /// Animate the panel frame, keeping its top edge locked to the
    /// screen top (i.e., to the notch).
    ///
    /// The frame is driven by a per-component damped spring stepped on
    /// the display link — not a fixed-duration ease and not AppKit's
    /// `NSViewAnimation`/`animator()` (both proven unreliable for
    /// NSPanel: they snap width/height instantly or desync the origin).
    /// Springs give us pixel-perfect symmetric expansion AND, unlike a
    /// re-anchored easing curve, a retarget mid-flight preserves the
    /// current velocity — the trajectory bends toward the new target
    /// instead of stopping and re-launching, which was the visible
    /// stutter when a measurement or a second notification resized the
    /// panel mid-expand.
    func animateHeight(to newHeight: CGFloat, width: CGFloat? = nil, caller: String = #function) {
        let newWidth = width ?? frame.width
        refreshNotchGeometry(caller: caller)
        let x = notch.notchCenterX - newWidth / 2
        let y = targetScreen.frame.maxY - newHeight
        let target = NSRect(x: x, y: y, width: newWidth, height: newHeight)

        // Already heading exactly there? Keep the spring in flight —
        // retargeting to the same value would only re-announce started/
        // ended to PanelState. SwiftUI re-reports sizes every layout pass.
        if let run = animationRun,
           abs(run.target.height - target.height) < 1,
           abs(run.target.width - target.width) < 1,
           abs(run.target.origin.x - target.origin.x) < 1,
           abs(run.target.origin.y - target.origin.y) < 1 {
            return
        }

        AnimationDebugger.logStart(from: self.frame, to: target, caller: caller,
                                   duration: AnimationDebugger.isEnabled ? AnimationDebugger.slowDuration : 0)

        if CompanionMotion.reduceMotion || self.frame == target {
            cancelFrameAnimation(notify: false)
            IslandFrameTiming.recordInstant()
            setFrame(target, display: true)
            onFrameAnimationEnded?()
            return
        }

        if var run = animationRun {
            // Retarget in flight: keep the integrated velocity so the
            // spring bends toward the new goal without a velocity zero.
            // The wedge clock restarts too — it exists to unstick a run
            // that never settles, not to truncate a healthy retarget.
            run.target = target
            run.expanding = IslandMotion.isExpanding(from: self.frame, to: target)
            run.startedWallClock = Date()
            animationRun = run
            return
        }

        onFrameAnimationStarted?()

        animationRun = SpringRun(
            target: target,
            velocity: .zero,
            expanding: IslandMotion.isExpanding(from: self.frame, to: target),
            lastTimestamp: 0,
            startedWallClock: Date()
        )
        IslandFrameTiming.begin()

        // Drive the integration from the display's own refresh signal.
        // A repeating `Timer` fires on the runloop clock, so a busy frame
        // (SwiftUI re-laying out the panel as it resizes) leaves it behind
        // — the timer then bursts to catch up or skips a beat, which is the
        // stutter that was visible on the expand/collapse. `CADisplayLink`
        // fires once per vsync and hands us `targetTimestamp`, the moment
        // the frame we are about to draw will be shown, so each frame is
        // positioned for its own presentation time and never drifts.
        // ProMotion: don't cap at 60 — a 120 Hz panel animating at half
        // rate reads as jank next to the rest of the system UI.
        if let contentView, contentView.window != nil {
            let link = contentView.displayLink(target: self, selector: #selector(stepFrameAnimation(_:)))
            let maxFPS = Double(targetScreen.maximumFramesPerSecond)
            let ceiling = max(60, maxFPS)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(ceiling), preferred: Float(ceiling))
            link.add(to: .main, forMode: .common)
            animationDisplayLink = link
        } else {
            // Fallback when the view is not in a window yet.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard self?.animationRun != nil else {
                    timer.invalidate()
                    return
                }
                self?.stepFrameAnimation(at: CACurrentMediaTime())
            }
            animationTimer = timer
            // Continue animating during mouse tracking and menu interactions.
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func stepFrameAnimation(_ link: CADisplayLink) {
        // `targetTimestamp` is the presentation time of the frame being
        // drawn right now — one refresh ahead of `timestamp` — so the
        // position lands exactly where it should appear on screen.
        stepFrameAnimation(at: link.targetTimestamp)
    }

    private func stepFrameAnimation(at mediaTime: CFTimeInterval) {
        guard var run = animationRun else { return }
        let stepStart = CACurrentMediaTime()
        let now = ProcessInfo.processInfo.systemUptime
        IslandFrameTiming.tick(uptime: now)

        // First tick after a retarget/start has no previous timestamp —
        // use one nominal frame instead of a huge dt.
        let dt = run.lastTimestamp > 0
            ? min(max(mediaTime - run.lastTimestamp, 0), IslandMotion.maxStep)
            : 1.0 / 60.0
        run.lastTimestamp = mediaTime

        // Semi-implicit Euler: velocity integrates acceleration, position
        // integrates the new velocity. Stable for our stiffness range and
        // cheap enough to run inside a vsync tick.
        let (k, c) = IslandMotion.spring(expanding: run.expanding)
        var pos = FloatingPanel.components(of: frame)
        let targetV = FloatingPanel.components(of: run.target)
        let accel = -k * (pos - targetV) - c * run.velocity
        run.velocity += accel * dt
        pos += run.velocity * dt

        let stepped = FloatingPanel.rect(from: pos)
        // `display: false` — the window server composites the resized
        // window at its own display cycle. Forcing a synchronous redraw
        // here re-laid-out the whole SwiftUI tree inside the tick, which is
        // what starved the next frames.
        setFrame(stepped, display: false)
        animationRun = run

        AnimationDebugger.logSample(window: self, startTime: run.startedWallClock,
                                    elapsed: Date().timeIntervalSince(run.startedWallClock))

        // Anything slow here is our own main-thread work (window resize +
        // SwiftUI re-render) rather than the display's cadence, so surface
        // it separately when hunting stutter.
        let cost = CACurrentMediaTime() - stepStart
        if cost > 0.008 {
            AnimationDebugger.logEvent(String(format: "slowStep %.1fms w=%.0f h=%.0f",
                                            cost * 1000, stepped.width, stepped.height))
        }

        let settled = simd_distance(pos, targetV) < IslandMotion.settleDistance
            && simd_length(run.velocity) < IslandMotion.settleVelocity
        let wedged = Date().timeIntervalSince(run.startedWallClock) > IslandMotion.maxRunDuration
        if settled || wedged {
            finishFrameAnimation()
        }
    }

    private func finishFrameAnimation() {
        guard let run = animationRun else { return }
        animationRun = nil
        animationTimer?.invalidate()
        animationTimer = nil
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        // Land exactly on the target and paint once, so the final frame is
        // never left to a deferred composite of the previous step.
        setFrame(run.target, display: true)
        onFrameAnimationEnded?()
        AnimationDebugger.logEnd(frame: frame)
        IslandFrameTiming.finish(duration: Date().timeIntervalSince(run.startedWallClock))
    }

    /// Snap the panel to the target size with NO animation. Used on
    /// first-ever layout so the initial placeholder `contentRect`
    /// doesn't animate down to the real compact size — that's the
    /// "first animation is wrong" artifact on launch.
    func setFrameInstantly(height: CGFloat, width: CGFloat? = nil) {
        let wasAnimating = isFrameAnimationRunning
        cancelFrameAnimation(notify: false)
        setFrame(targetFrame(height: height, width: width), display: true)
        if wasAnimating { onFrameAnimationEnded?() }
    }

    func setFrameInstantlyCentered(height newHeight: CGFloat, width newWidth: CGFloat) {
        let wasAnimating = isFrameAnimationRunning
        cancelFrameAnimation(notify: false)
        let centerX = frame.midX
        let x = centerX - newWidth / 2
        let y = frame.maxY - newHeight
        setFrame(NSRect(x: x, y: y, width: newWidth, height: newHeight), display: true)
        if wasAnimating { onFrameAnimationEnded?() }
    }

    /// Compute the target NSRect given a desired height/width. Keeps
    /// the top edge pinned to the notch and horizontally centers the
    /// panel on the notch center — so expansions "grow down" out of
    /// the island rather than drifting sideways.
    private func targetFrame(height newHeight: CGFloat, width: CGFloat? = nil) -> NSRect {
        refreshNotchGeometry()
        let newWidth = width ?? frame.width
        let x = notch.notchCenterX - newWidth / 2
        let y = targetScreen.frame.maxY - newHeight
        return NSRect(x: x, y: y, width: newWidth, height: newHeight)
    }

    /// Switch the panel between the dark pill appearance and the light
    /// system-settings appearance used in the `.detail` state. The
    /// dark island silhouette is painted by SwiftUI (IslandShape),
    /// so the container itself stays transparent in the dark
    /// states — we only set a solid background for detail/settings
    /// which uses a standard rounded window instead of the island.
    func setDetailAppearance(_ isDetail: Bool) {
        if isDetail {
            // Use system (light) appearance for the settings panel so SwiftUI
            // controls render with native macOS System Settings styling.
            self.appearance = nil   // inherit system appearance
            pillContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            pillContainer.layer?.cornerRadius = 12
            pillContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            pillContainer.layer?.masksToBounds = true
        } else {
            // Island states (compact / extended / notification):
            // container stays transparent — SwiftUI's IslandShape
            // paints the black pill with its notch cutout. Reverting
            // to an opaque black layer here would fill the notch
            // region too and break the silhouette.
            self.appearance = NSAppearance(named: .darkAqua)
            pillContainer.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
            pillContainer.layer?.cornerRadius = 0
            pillContainer.layer?.masksToBounds = false
        }
    }

    // Dynamic focus policy.
    //
    // The pill states (compact / extended / notification) must never be
    // key, otherwise the passive glance-view would keep stealing focus
    // from whatever the user is actually typing in. But the detail state
    // embeds real controls (TextField, search, etc.) that MUST be able
    // to become first responder — if `canBecomeKey` is hard-coded to
    // false, SwiftUI text fields silently reject every click.
    //
    // AppDelegate flips `allowsBecomeKey` alongside the state transition
    // and calls `makeKey()` on entering `.detail`.
    var allowsBecomeKey: Bool = false {
        didSet {
            if !allowsBecomeKey, isKeyWindow {
                resignKey()
            }
        }
    }
    override var canBecomeKey: Bool { allowsBecomeKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - Animation Debugger

struct AnimationDebugger {
    static let isEnabled = ProcessInfo.processInfo.environment["WCHUD_ANIMATION_DEBUG"] == "1"
    static let slowDuration: TimeInterval = 2.0
    private static let boot = Date()

    static func logEvent(_ message: String) {
        guard isEnabled else { return }
        let ms = Date().timeIntervalSince(boot) * 1000
        print(String(format: "[ANIM] @%08.1fms %@", ms, message))
    }

    static func logStart(from: NSRect, to: NSRect, caller: String, duration: TimeInterval) {
        guard isEnabled else { return }
        logEvent(">>> START caller=\(caller) duration=\(duration)s")
        print("[ANIM]      from=(x:\(String(format: "%.1f", from.origin.x)) y:\(String(format: "%.1f", from.origin.y)) w:\(String(format: "%.1f", from.size.width)) h:\(String(format: "%.1f", from.size.height)))")
        print("[ANIM]      to  =(x:\(String(format: "%.1f", to.origin.x)) y:\(String(format: "%.1f", to.origin.y)) w:\(String(format: "%.1f", to.size.width)) h:\(String(format: "%.1f", to.size.height)))")
    }

    static func logSample(window: NSWindow, startTime: Date, elapsed: TimeInterval) {
        guard isEnabled else { return }
        let f = window.frame
        print(String(format: "[ANIM] %06.1fms frame=(x:%.1f y:%.1f w:%.1f h:%.1f)", elapsed * 1000, f.origin.x, f.origin.y, f.size.width, f.size.height))
    }

    static func logEnd(frame: NSRect) {
        guard isEnabled else { return }
        print("[ANIM] <<< END   final=(x:\(String(format: "%.1f", frame.origin.x)) y:\(String(format: "%.1f", frame.origin.y)) w:\(String(format: "%.1f", frame.size.width)) h:\(String(format: "%.1f", frame.size.height)))")
    }
}

/// Records island frame-timer cadence for the 60fps acceptance gate.
enum IslandFrameTiming {
    static var lastIntervals: [TimeInterval] = []
    static var lastDuration: TimeInterval = 0
    static var lastWasInstant = false
    private static var previousUptime: TimeInterval?

    static func begin() {
        lastIntervals = []
        lastWasInstant = false
        previousUptime = nil
    }

    static func recordInstant() {
        lastIntervals = []
        lastDuration = 0
        lastWasInstant = true
        persist()
    }

    static func tick(uptime: TimeInterval) {
        if let previousUptime {
            lastIntervals.append(uptime - previousUptime)
        }
        previousUptime = uptime
    }

    static func finish(duration: TimeInterval) {
        lastDuration = duration
        lastWasInstant = false
        persist()
    }

    static var estimatedFPS: Double {
        guard let avg = averageInterval, avg > 0 else { return 0 }
        return 1 / avg
    }

    static var averageInterval: TimeInterval? {
        guard !lastIntervals.isEmpty else { return nil }
        return lastIntervals.reduce(0, +) / Double(lastIntervals.count)
    }

    /// Worst single interval of the last animation. The average can look
    /// perfect while one 80 ms stall is exactly what the eye notices, so
    /// the acceptance report carries the tail too.
    static var worstInterval: TimeInterval {
        lastIntervals.max() ?? 0
    }

    /// 95th-percentile interval of the last animation.
    static var p95Interval: TimeInterval {
        guard !lastIntervals.isEmpty else { return 0 }
        let sorted = lastIntervals.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    static var reportPath: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechathud-island-fps.json")
    }

    private static func persist() {
        let payload: [String: Any] = [
            "instant": lastWasInstant,
            "duration": lastDuration,
            "samples": lastIntervals.count,
            "fps": estimatedFPS,
            "averageMs": (averageInterval ?? 0) * 1000,
            "p95Ms": p95Interval * 1000,
            "worstMs": worstInterval * 1000
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: reportPath)
        }
    }
}
