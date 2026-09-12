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
    /// Screen-space hit test for the *visible* island. While a mask-driven
    /// spring is in flight the view fills the covering union, so a raw
    /// bounds test would treat empty cover as inside the pill.
    var isScreenPointInside: ((NSPoint) -> Bool)?
    private var lastPointerInside = false

    /// Color painted behind the hosted SwiftUI content, or `nil` for a
    /// transparent container.
    ///
    /// Held as a color rather than a `cgColor`: a dynamic NSColor resolves into
    /// one concrete CGColor at assignment and a CALayer never re-resolves it, so
    /// storing the resolved value left the old scheme's plate under the new
    /// scheme's text — a white plate with white labels. It is resolved again on
    /// every effective-appearance change.
    var plateColor: NSColor? {
        didSet { applyPlate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPlate()
    }

    private func applyPlate() {
        guard let plateColor else {
            layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        // The plate lives on the layer, so make sure there is one: a container
        // that has never been drawn would otherwise drop the color silently.
        if layer == nil { wantsLayer = true }
        var resolved = plateColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = plateColor.usingColorSpace(.sRGB) ?? plateColor
        }
        layer?.backgroundColor = resolved.cgColor
    }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEventInsideVisibleIsland(windowPoint: convert(point, to: nil)) else { return nil }
        return super.hitTest(point)
    }

    private func installTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        publishPointerInside(isEventInsideVisibleIsland(event))
    }

    override func mouseExited(with event: NSEvent) {
        // Re-test the painted island. AppKit fires exit when the cursor
        // crosses the covering window's exclusive maxY, which is exactly
        // the top scanline the island occupies — a hover parked on the
        // notch would otherwise collapse itself.
        publishPointerInside(isEventInsideVisibleIsland(event))
    }

    override func mouseMoved(with event: NSEvent) {
        publishPointerInside(isEventInsideVisibleIsland(event))
    }

    func publishPointerInside(_ inside: Bool) {
        guard inside != lastPointerInside else { return }
        lastPointerInside = inside
        if inside { onEntered?() } else { onExited?() }
    }

    private func isEventInsideVisibleIsland(_ event: NSEvent) -> Bool {
        isEventInsideVisibleIsland(windowPoint: event.locationInWindow)
    }

    private func isEventInsideVisibleIsland(windowPoint: NSPoint) -> Bool {
        guard let isScreenPointInside, let window else { return true }
        let screen = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        return isScreenPointInside(screen)
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
        container.isScreenPointInside = { [weak self] point in
            self?.containsMouse(point) ?? false
        }
        positionAtTop()
        installPointerMonitor()
    }

    deinit {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        pointerRecoveryTimer?.invalidate()
    }

    /// Which screen preference to use — updated from settings.
    var displayScreen: DisplayScreen = .builtIn

    /// Resolve the target screen based on the displayScreen preference.
    ///
    /// Optional on purpose: `NSScreen.screens` is empty in clamshell mode with
    /// no external display and momentarily during a hot-plug reconfiguration.
    /// The old `?? NSScreen.screens[0]` therefore trapped on the launch path
    /// (`AppDelegate` calls `positionAtTop()`), taking the whole app down for
    /// a display event. Callers fall back to the panel's current frame.
    var targetScreen: NSScreen? {
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
        return mapped.first(where: { $0.1 == picked })?.0 ?? NSScreen.main ?? NSScreen.screens.first
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
        guard let screen = targetScreen else {
            // No display attached. Keep the placeholder metrics so geometry
            // math stays total; `positionAtTop`/animation are skipped below.
            notch = NotchGeometry(hasRealNotch: false, notchWidth: 200, notchHeight: 32, notchCenterX: 0)
            return
        }
        notch = NotchGeometry.detect(on: screen)
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
        guard let screen = targetScreen else { return }
        // A snap to a new screen is a discontinuity: the in-flight spring's
        // integrated `position`/`target` are in the *old* screen's coordinates,
        // so leaving the run alive lets it re-derive the mask a tick later
        // against the new frame and drag the island back off the notch. End the
        // run first (notify: true, so PanelState's exit bookkeeping still
        // runs), then re-anchor from a clean spring state.
        cancelFrameAnimation(notify: true)
        let panelWidth = frame.width
        let x = notch.notchCenterX - panelWidth / 2
        let y = screen.frame.maxY - frame.height
        setFrameOrigin(NSPoint(x: x, y: y))
        // Re-anchor the island to the (possibly new) notch. Only the origin
        // moved, so the mask's offset inside the stage is unchanged — but the
        // screen-space island the hit test reads has to be re-derived.
        if let island = visibleFrame {
            applyIslandMask(painted: NSRect(
                x: notch.notchCenterX - island.width / 2,
                y: frame.maxY - island.height,
                width: island.width,
                height: island.height
            ), in: frame)
        }
        recordIslandScreenIfPreviewing()
    }

    private func recordIslandScreenIfPreviewing() {
        guard PreviewRuntime.isEnabled else { return }
        guard let screen = targetScreen else { return }
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
    /// Visible island while a mask-driven run is in flight. Hit testing
    /// reads this instead of `frame`, because `frame` is the covering
    /// union and would count empty space as inside the pill.
    private var visibleFrame: NSRect?
    private var maskLayer: CALayer?
    var visibleIslandFrame: NSRect? { visibleFrame }
    /// The island *stage*: the largest island rect this panel has ever needed.
    ///
    /// The window is kept at least this big and every later expand/collapse is
    /// a compositor mask inside it. Growing the window is the one operation
    /// that cannot be paid off the animation path: the window server
    /// allocates a new backing store and the hosted SwiftUI tree re-lays out,
    /// which lands as a dropped frame in the middle of the motion.
    ///
    /// Eight in-process expand/collapse cycles measured exactly that
    /// asymmetry — every *expand* dropped one 29–42 ms frame, while every
    /// collapse held a clean 16.7 ms, because a collapse's cover is already
    /// the current window frame and never resizes. Keeping the stage means
    /// only the first expand pays it.
    private var stageSize: CGSize = .zero
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var pointerRecoveryTimer: Timer?

    /// One frame-animation pass, modelled as four damped springs — one per
    /// frame component (x, y, width, height). Velocity is kept across
    /// retargets: when a new target arrives mid-flight we swap `target`
    /// and keep integrating from the live velocity, so the trajectory
    /// bends smoothly instead of stopping and restarting from zero.
    ///
    /// The numeric state lives in `IslandFrameSpring`, which integrates its
    /// own continuous position rather than re-reading the window's frame.
    /// Re-reading would re-inject AppKit's whole-point quantization every
    /// tick and freeze the run short of its target — see that type's `step`
    /// for the mechanism behind the post-expansion "flash + shift".
    private struct SpringRun {
        var spring: IslandFrameSpring
        /// Last display-link timestamp, for the per-tick `dt`.
        var lastTimestamp: CFTimeInterval
        /// Refreshed on retarget: the wedge cap protects a wedged run,
        /// not a healthy one that just received a new goal.
        var startedWallClock: Date

        /// The rect the run ends on: the target as the window server will
        /// store it. See `FloatingPanel.landing(_:)`.
        var landing: SIMD4<Double>

        /// The rect the window server was storing after the last tick.
        var painted: SIMD4<Double>
        /// Covering window the mask is painted inside. Stable for the
        /// whole run so a retarget only grows it, never shrinks it under
        /// the currently visible island.
        var cover: NSRect

        /// The goal as an `NSRect`, read from the spring's own target
        /// components so the integrator and the window can never disagree
        /// about where the run is heading.
        var target: NSRect { FloatingPanel.rect(from: spring.target) }
    }

    private static func components(of rect: NSRect) -> SIMD4<Double> {
        SIMD4(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    /// The whole-point rect the window server will store for `rect`.
    ///
    /// AppKit floors the origin and ceils the size (verified against a live
    /// panel: `x: 500.6` → `500`, `w: 560.1` → `561`, `560.0` → `560`).
    /// Landing on this rect — computed here instead of read back from the
    /// window — means the final `setFrame` paints exactly the pixels the run
    /// was already showing, so ending a run cannot jolt the panel.
    /// Internal so the pixel-grid contract is testable without a live window
    /// server (see `IslandFrameSpringTests`).
    static func landing(_ rect: NSRect) -> SIMD4<Double> {
        SIMD4(rect.origin.x.rounded(.down), rect.origin.y.rounded(.down),
              rect.size.width.rounded(.up), rect.size.height.rounded(.up))
    }

    /// Where to aim the spring so the *stored* rect is the landing rect for the
    /// whole tail: the centre of the quantization cell.
    ///
    /// A floor-quantized origin maps to `[landing, landing + 1)` and a
    /// ceil-quantized size to `(landing - 1, landing]`, so ±½ from the centre is
    /// as far as the residual can be — and the residual is what the spring
    /// never quite spends. Aiming at the landing rect itself would let a
    /// ceiled size stall a point above it (the bug behind the jolt); aiming at
    /// the centre makes the stored rect equal the landing for the entire
    /// settling motion, so the run ends with nothing to correct.
    ///
    /// The half point of *travel* this gives up is not visible: the stored
    /// window rect is the landing rect either way.
    static func springTarget(for landing: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(landing.x + 0.5, landing.y + 0.5, landing.z - 0.5, landing.w - 0.5)
    }

    static func rect(from v: SIMD4<Double>) -> NSRect {
        NSRect(x: v.x, y: v.y, width: v.z, height: v.w)
    }

    /// Is `point` (global Cocoa coordinates) inside the panel?
    ///
    /// The panel sits *on* the top edge of the display, so the test has to
    /// count a cursor parked on that top scanline as inside — the raw
    /// `NSRect.contains` excludes its `maxY` edge, which used to make the
    /// expand animation settle with "mouse outside" and trigger a spurious
    /// auto-collapse while the pointer never moved. `IslandHitTest` makes
    /// every edge inclusive instead of widening the rect, so a cursor that
    /// has genuinely left still reads as outside.
    func containsMouse(_ point: NSPoint = NSEvent.mouseLocation) -> Bool {
        IslandMaskGeometry.containsMouse(painted: visibleFrame ?? frame, point: point)
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
        clearIslandMask()
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
        let y = (targetScreen?.frame.maxY ?? frame.maxY) - newHeight
        let target = NSRect(x: x, y: y, width: newWidth, height: newHeight)
        let fromVisible = visibleFrame ?? frame

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

        AnimationDebugger.logStart(from: fromVisible, to: target, caller: caller,
                                   duration: AnimationDebugger.isEnabled ? AnimationDebugger.slowDuration : 0)

        if CompanionMotion.reduceMotion || fromVisible == target {
            cancelFrameAnimation(notify: false)
            IslandFrameTiming.recordInstant()
            let cover = growStage(toCover: target)
            if cover != frame {
                setFrame(cover, display: true)
            }
            applyIslandMask(painted: target, in: cover)
            onFrameAnimationEnded?()
            return
        }

        if var run = animationRun {
            // Retarget in flight: keep the integrated velocity so the
            // spring bends toward the new goal without a velocity zero.
            // The wedge clock restarts too — it exists to unstick a run
            // that never settles, not to truncate a healthy retarget.
            let landing = FloatingPanel.landing(target)
            run.spring.target = FloatingPanel.springTarget(for: landing)
            run.spring.expanding = IslandMotion.isExpanding(from: fromVisible, to: target)
            run.landing = landing
            run.startedWallClock = Date()
            // A retarget that needs more room grows the stage the same way a
            // fresh run does; one that fits inside it resizes nothing.
            let needed = growStage(toCover: target)
            if needed != run.cover {
                setFrame(needed, display: false)
                run.cover = needed
                applyIslandMask(painted: FloatingPanel.rect(from: run.painted), in: needed)
            }
            animationRun = run
            return
        }

        onFrameAnimationStarted?()

        let landing = FloatingPanel.landing(target)
        // Cover = the existing stage, grown only if this island needs more
        // room than it has ever had. A collapse — or any expand the stage
        // already holds — therefore performs NO window resize at all: the
        // spring is pure compositor work from its first frame to its last.
        let cover = growStage(toCover: target)
        // One window-server resize for the whole run: the covering union.
        // SwiftUI lays out once at the destination size; later ticks only
        // move a compositor mask. That is what removes the 19 ms first-tick
        // hitch of setFrame-per-vsync.
        //
        // The resize itself is timed: it is the one window-server round trip
        // left in the run, and the SwiftUI layout it triggers lands on the
        // *next* frame — outside any `slowStep` measurement. Logging it here
        // is the only way to tell "the island is janky" apart from "one frame
        // paid for the destination layout".
        let resizeStart = CACurrentMediaTime()
        if cover != frame {
            setFrame(cover, display: false)
        }
        let resizeCost = (CACurrentMediaTime() - resizeStart) * 1000
        if resizeCost > 4 {
            AnimationDebugger.logEvent(String(format: "stageGrow %.1fms %.0f×%.0f -> %.0f×%.0f",
                                            resizeCost, fromVisible.width, fromVisible.height,
                                            cover.width, cover.height))
        }
        applyIslandMask(painted: fromVisible, in: cover)
        animationRun = SpringRun(
            spring: IslandFrameSpring(
                position: FloatingPanel.components(of: fromVisible),
                target: FloatingPanel.springTarget(for: landing),
                expanding: IslandMotion.isExpanding(from: fromVisible, to: target)
            ),
            lastTimestamp: 0,
            startedWallClock: Date(),
            landing: landing,
            painted: FloatingPanel.components(of: fromVisible),
            cover: cover
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
            let maxFPS = Double(targetScreen?.maximumFramesPerSecond ?? 60)
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
        let isFirstTick = run.lastTimestamp <= 0
        let dt = isFirstTick
            ? 1.0 / 60.0
            : min(max(mediaTime - run.lastTimestamp, 0), IslandMotion.maxStep)
        run.lastTimestamp = mediaTime

        // How long the run waited for its first frame. The destination layout
        // that the covering resize triggers is paid on the main thread before
        // this tick can run, so a late first tick is the signature of "the
        // window resized and SwiftUI re-laid out the whole inbox" — jank the
        // per-tick `slowStep` probe can never see, because it measures only
        // the tick body.
        if isFirstTick {
            let latency = Date().timeIntervalSince(run.startedWallClock) * 1000
            if latency > 20 {
                AnimationDebugger.logEvent(String(format: "firstTick %.1fms after run start", latency))
            }
        }

        // One vsync step of the frame spring. The spring integrates its own
        // continuous position — never the window's read-back frame, which
        // AppKit has already rounded to whole points (see `SpringRun`).
        run.spring.step(dt: dt)

        let stepped = run.spring.frame
        // Paint the mask, not the window. The covering frame is already at
        // the union; moving a CALayer is compositor work and cannot relayout
        // SwiftUI. `display: false` setFrame-per-tick used to cost 8–19 ms.
        applyIslandMask(painted: stepped, in: run.cover)
        run.painted = FloatingPanel.landing(stepped)
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

        // The wedge cap is a safety net for a run that cannot converge; a
        // healthy run settles well inside it (measured ~0.44 s expand,
        // ~0.50 s collapse).
        let wedged = Date().timeIntervalSince(run.startedWallClock) > IslandMotion.maxRunDuration
        if weldedToTarget(run) || wedged {
            finishFrameAnimation()
        }
    }

    /// Whether the tick loop is done with this run.
    ///
    /// Ending on the *stored* rect rather than on the spring's own distance
    /// keeps the final correction inside the arrival: see
    /// `IslandFrameSpring.hasArrived(painted:landing:)` for the measurements
    /// behind it. `hasSettled` is kept as the second opinion so a run whose
    /// residual collapses faster than a point still ends promptly.
    private func weldedToTarget(_ run: SpringRun) -> Bool {
        run.spring.hasArrived(painted: run.painted, landing: run.landing)
            || run.spring.hasSettled
    }

    private func finishFrameAnimation() {
        guard let run = animationRun else { return }
        animationRun = nil
        animationTimer?.invalidate()
        animationTimer = nil
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        // Park the mask on the whole-point rect the spring landed on and
        // leave the window at the stage. The island the user sees is exactly
        // this rect; the window around it is invisible either way, and
        // keeping it means the next expand has nothing to resize.
        //
        // Order matters: the mask moves to the landing rect *before* SwiftUI
        // swaps surfaces, so the incoming surface is already inside the pill
        // when it appears.
        applyIslandMask(painted: FloatingPanel.rect(from: run.landing), in: run.cover)
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
        let island = targetFrame(height: height, width: width)
        let cover = growStage(toCover: island)
        if cover != frame {
            setFrame(cover, display: true)
        }
        applyIslandMask(painted: island, in: cover)
        if wasAnimating { onFrameAnimationEnded?() }
    }

    func setFrameInstantlyCentered(height newHeight: CGFloat, width newWidth: CGFloat) {
        let wasAnimating = isFrameAnimationRunning
        cancelFrameAnimation(notify: false)
        let centerX = frame.midX
        let x = centerX - newWidth / 2
        let y = frame.maxY - newHeight
        let island = NSRect(x: x, y: y, width: newWidth, height: newHeight)
        let cover = growStage(toCover: island)
        if cover != frame {
            setFrame(cover, display: true)
        }
        applyIslandMask(painted: island, in: cover)
        if wasAnimating { onFrameAnimationEnded?() }
    }

    /// Reveal only `painted` inside `cover` via a compositor mask.
    ///
    /// Actions are disabled (`CATransaction.setDisableActions`) so the
    /// display-link owns timing; an implicit CA animation on top of the
    /// spring would lag one vsync and read as jelly.
    private func applyIslandMask(painted: NSRect, in cover: NSRect) {
        visibleFrame = painted
        guard let container = contentView else { return }
        container.wantsLayer = true
        let mask: CALayer
        if let existing = maskLayer {
            mask = existing
        } else {
            mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.maskedCorners = IslandMaskGeometry.maskedCorners
            mask.cornerCurve = IslandMaskGeometry.cornerCurve
            container.layer?.mask = mask
            maskLayer = mask
        }
        let layerFrame = IslandMaskGeometry.layerFrame(painted: painted, in: cover)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layerFrame
        mask.cornerRadius = IslandMaskGeometry.cornerRadius(for: layerFrame.size)
        CATransaction.commit()
        refreshPointerAgainstVisibleIsland()
    }

    private func clearIslandMask() {
        // The mask is permanent now: the window is a stage far larger than
        // the island, so dropping the mask would expose the whole stage.
        // Cancelling a run therefore leaves the island where the run had
        // reached — callers that want a different island re-apply the mask
        // with it.
        guard maskLayer != nil, let island = visibleFrame else { return }
        applyIslandMask(painted: island, in: frame)
    }

    /// The covering window's tracking area fires enter as soon as the union
    /// is applied. Re-test against the painted island so a cursor sitting in
    /// the yet-to-grow region does not count as hovering, and a cursor that
    /// the shrinking mask has left is reported as an exit.
    private func refreshPointerAgainstVisibleIsland() {
        let inside = containsMouse()
        // The stage is far larger than the island, so the window has to stop
        // taking mouse events whenever the cursor is over the part of it that
        // is not the island — otherwise a transparent overlay would swallow
        // clicks across the top-centre of the screen. hitTest alone is not
        // enough: AppKit still routes a click to the window (and can activate
        // it) when the content view declines it. (Same pairing as
        // codex-island's IslandWindowController + IslandHostingView.)
        if ignoresMouseEvents == inside {
            ignoresMouseEvents = !inside
            setPointerRecoveryPolling(!inside)
            AnimationDebugger.logEvent("pointer hit-test -> \(inside ? "hoverable" : "click-through") island=\(String(format: "%.0f×%.0f", visibleFrame?.width ?? 0, visibleFrame?.height ?? 0))")
        }
        pillContainer.publishPointerInside(inside)
    }

    /// While the window is ignoring mouse events it receives none, so the only
    /// way back to hoverable is the global monitor firing. If that monitor is
    /// unavailable (no Accessibility grant, a stray sandbox) the island would
    /// go permanently dead to the pointer, which is a far worse failure than a
    /// little idle CPU. Polling only runs in that state — while the island is
    /// hoverable, real events do the work.
    private func setPointerRecoveryPolling(_ on: Bool) {
        if on {
            guard pointerRecoveryTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPointerAgainstVisibleIsland() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerRecoveryTimer = timer
        } else {
            pointerRecoveryTimer?.invalidate()
            pointerRecoveryTimer = nil
        }
    }

    /// Tracking areas only fire while the cursor is inside the covering
    /// window. After a mask-driven expand the cover is the union, so a
    /// cursor that never entered the *visible* island can sit in empty
    /// cover forever with no exit event. A local/global mouse-moved pair
    /// re-tests the painted island on every move, including jumps that
    /// skip the tracking-area edge (CGEvent / cliclick).
    private func installPointerMonitor() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.refreshPointerAgainstVisibleIsland()
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.refreshPointerAgainstVisibleIsland()
        }
    }

    /// Compute the target NSRect given a desired height/width. Keeps
    /// the top edge pinned to the notch and horizontally centers the
    /// panel on the notch center — so expansions "grow down" out of
    /// the island rather than drifting sideways.
    private func targetFrame(height newHeight: CGFloat, width: CGFloat? = nil) -> NSRect {
        refreshNotchGeometry()
        let newWidth = width ?? frame.width
        let x = notch.notchCenterX - newWidth / 2
        let y = (targetScreen?.frame.maxY ?? frame.maxY) - newHeight
        return NSRect(x: x, y: y, width: newWidth, height: newHeight)
    }

    /// The stage, centred on the notch and pinned to the screen's top edge —
    /// the same anchoring an island rect uses, so the mask's mapping between
    /// the two is a pure translation.
    private func stageFrame(size: CGSize) -> NSRect {
        let x = notch.notchCenterX - size.width / 2
        let y = (targetScreen?.frame.maxY ?? frame.maxY) - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Grow the stage so it can hold `island`, and return the stage frame.
    ///
    /// Monotonic on purpose: the stage never shrinks. A smaller island is
    /// revealed by the mask, not by resizing the window — which is the whole
    /// point, because the resize is what costs a frame.
    @discardableResult
    private func growStage(toCover island: NSRect) -> NSRect {
        let size = CGSize(
            width: max(max(stageSize.width, frame.width), island.width),
            height: max(max(stageSize.height, frame.height), island.height)
        )
        stageSize = size
        return stageFrame(size: size)
    }

    /// What the panel is showing, which decides the surface behind it.
    ///
    /// The two panes that fill the panel are styled for opposite schemes — the
    /// settings pages use scheme-aware colors and system controls, a conversation
    /// is white ink on dark — so the window appearance and the container plate
    /// have to be chosen per surface, not per "is this a detail state".
    enum Surface {
        /// Island states: transparent, because SwiftUI's IslandShape paints the
        /// black pill with its notch cutout. An opaque layer here would fill the
        /// notch region and break the silhouette.
        case island
        /// Workspace settings pages: follow the system scheme so SwiftUI
        /// controls render with native macOS System Settings styling.
        case systemSettings
        /// A conversation: `ConversationDetailView` paints white ink and
        /// white-opacity bubbles, so it needs a dark plate in either system
        /// scheme. Left to the system scheme, a light-mode Mac drew white text
        /// on a white plate.
        case conversation
    }

    func setSurface(_ surface: Surface) {
        switch surface {
        case .island:
            self.appearance = NSAppearance(named: .darkAqua)
            pillContainer.plateColor = nil
            pillContainer.layer?.cornerRadius = 0
            pillContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            pillContainer.layer?.masksToBounds = false
        case .systemSettings:
            self.appearance = nil   // inherit system appearance
            pillContainer.plateColor = .windowBackgroundColor
            pillContainer.layer?.cornerRadius = 12
            pillContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            pillContainer.layer?.masksToBounds = true
        case .conversation:
            self.appearance = NSAppearance(named: .darkAqua)
            // Fixed dark on purpose: the view on top is white ink in either
            // system scheme.
            pillContainer.plateColor = NSColor(white: 0.11, alpha: 1)
            pillContainer.layer?.cornerRadius = 12
            pillContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            pillContainer.layer?.masksToBounds = true
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
    /// `WCHUD_ANIMATION_DEBUG=1` logs and slows the springs down so a run can
    /// be read frame by frame; `=fast` logs at real speed, which is the only
    /// way to see the dynamics the user actually gets (slow-mo changes which
    /// quantized rect the run settles on).
    private static let mode = ProcessInfo.processInfo.environment["WCHUD_ANIMATION_DEBUG"]
    static let isEnabled = mode != nil
    static let isSlowMotion = mode == "1"
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
        if let panel = window as? FloatingPanel, let visible = panel.visibleIslandFrame {
            print(String(format: "[ANIM] %06.1fms frame=(x:%.1f y:%.1f w:%.1f h:%.1f)", elapsed * 1000, visible.origin.x, visible.origin.y, visible.size.width, visible.size.height))
        } else {
            let f = window.frame
            print(String(format: "[ANIM] %06.1fms frame=(x:%.1f y:%.1f w:%.1f h:%.1f)", elapsed * 1000, f.origin.x, f.origin.y, f.size.width, f.size.height))
        }
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
