import XCTest
import simd
@testable import WeChatHUD

/// How long the island is *visibly* still, measured against the real spring.
///
/// `IslandMotion.expandDuration` / `collapseDuration` are labels. What the user
/// gets is whatever `IslandFrameSpring` plus AppKit's whole-point quantization
/// produces, and a live hover trace (`WCHUD_ANIMATION_DEBUG=fast`) measured
/// ~440 ms of expand and ~500 ms of collapse — with the final ~120 ms spent
/// creeping at well under a point per frame. That is motion that has finished
/// but has not stopped, and it is what reads as "拖".
///
/// These tests step the shipping integrator, not a reimplementation, so the
/// numbers are the ones the panel produces.
final class IslandSpringCadenceTests: XCTestCase {

    /// The measured hover pair from a live 2021+ MBP notch trace.
    private let compact = NSRect(x: 715.5, y: 1085.0, width: 297.0, height: 32.0)
    private let expanded = NSRect(x: 584.0, y: 861.0, width: 560.0, height: 256.0)

    struct Trace {
        /// When the run ended.
        let duration: TimeInterval
        /// When the *painted* rect last changed — the honest end of the motion.
        let lastVisibleChange: TimeInterval
        /// Largest excursion past the goal, per axis.
        let overshoot: SIMD4<Double>
        /// How many times a painted edge crossed the goal edge it was
        /// approaching. One is a pop; dozens is the island visibly shuddering
        /// against the notch.
        let edgeFlips: Int
        let ticks: Int
    }

    /// Whether any painted edge crossed the goal edge it was approaching.
    /// A named loop rather than an inline `contains(where:)`: the SIMD4
    /// subscript inside a closure expression is beyond the type checker.
    private func crossedGoal(_ previous: SIMD4<Double>, _ current: SIMD4<Double>,
                             _ landing: SIMD4<Double>) -> Bool {
        for axis in 0..<4 where (current[axis] - landing[axis]) * (previous[axis] - landing[axis]) < 0 {
            return true
        }
        return false
    }

    private func simulate(from start: NSRect, to goal: NSRect, expanding: Bool,
                          dt: TimeInterval = 1.0 / 60.0, cap: TimeInterval = 2.0) -> Trace {
        let landing = FloatingPanel.landing(goal)
        var spring = IslandFrameSpring(
            position: FloatingPanel.landing(start),
            target: FloatingPanel.springTarget(for: landing),
            expanding: expanding)
        var painted = FloatingPanel.landing(start)
        var lastPainted = painted
        var lastVisibleChange = 0.0
        var peak = SIMD4<Double>.zero
        var crossed = false
        var t = 0.0
        var ticks = 0
        var flips = 0
        while t < cap {
            t += dt
            ticks += 1
            spring.step(dt: dt)
            painted = FloatingPanel.landing(spring.frame)
            if painted != lastPainted {
                if crossedGoal(lastPainted, painted, landing) { flips += 1 }
                lastPainted = painted
                lastVisibleChange = t
            }
            // Overshoot only counts once the run has been at its goal — the
            // start of the run is 250pt away by definition.
            if simd_length(painted - landing) < 1.0 { crossed = true }
            if crossed { peak = simd_max(peak, simd_abs(painted - landing)) }
            if spring.hasArrived(painted: painted, landing: landing) || spring.hasSettled { break }
        }
        return Trace(duration: t, lastVisibleChange: lastVisibleChange,
                     overshoot: peak, edgeFlips: flips, ticks: ticks)
    }

    private func report(_ name: String, _ trace: Trace) {
        print(String(format: "[CADENCE] %@: end=%.0fms lastMove=%.0fms deadTail=%.0fms flips=%d overshoot=(%.0f,%.0f,%.0f,%.0f) ticks=%d",
                     name, trace.duration * 1000, trace.lastVisibleChange * 1000,
                     (trace.duration - trace.lastVisibleChange) * 1000, trace.edgeFlips,
                     trace.overshoot.x, trace.overshoot.y, trace.overshoot.z, trace.overshoot.w,
                     trace.ticks))
    }

    func testHoverExpandEndsInsideItsNominalDuration() {
        let trace = simulate(from: compact, to: expanded, expanding: true)
        report("expand", trace)
        XCTAssertLessThanOrEqual(trace.lastVisibleChange, IslandMotion.expandDuration + 0.05,
                                 "expand is still moving at \(Int(trace.lastVisibleChange * 1000))ms")
        // The pop is the island's whole character, and it is now a designed
        // number rather than a by-product of a coarse integration step.
        XCTAssertGreaterThanOrEqual(trace.overshoot.w, 4,
                                    "the expand stopped popping: +\(trace.overshoot.w)pt of height")
    }

    func testCollapseEndsInsideItsNominalDuration() {
        let trace = simulate(from: expanded, to: compact, expanding: false)
        report("collapse", trace)
        XCTAssertLessThanOrEqual(trace.lastVisibleChange, IslandMotion.collapseDuration + 0.03,
                                 "collapse is still moving at \(Int(trace.lastVisibleChange * 1000))ms")
        // Tucking away is the quick half of the pair. It used to be the slow
        // one: 450 ms of collapse against 400 ms of expand.
        XCTAssertLessThan(trace.duration,
                          simulate(from: compact, to: expanded, expanding: true).duration,
                          "the collapse now runs longer than the expand it follows")
    }

    /// The run that used to fail: at 30 Hz one Euler step per tick put enough
    /// energy error into the integrator that the collapse rang across the
    /// pixel grid for 2.4 s, and at 24 Hz it never settled at all.
    func testTheMotionIsTheSameShapeAtEveryDisplayCadence() {
        for hz in [120.0, 90.0, 60.0, 30.0, 24.0, 20.0] {
            let expand = simulate(from: compact, to: expanded, expanding: true, dt: 1 / hz)
            let collapse = simulate(from: expanded, to: compact, expanding: false, dt: 1 / hz)
            report("\(Int(hz))Hz expand", expand)
            report("\(Int(hz))Hz collapse", collapse)
            XCTAssertLessThanOrEqual(expand.edgeFlips, 1, "\(Int(hz))Hz expand shudders: \(expand.edgeFlips) edge crossings")
            XCTAssertLessThanOrEqual(collapse.edgeFlips, 1, "\(Int(hz))Hz collapse shudders: \(collapse.edgeFlips) edge crossings")
            XCTAssertLessThanOrEqual(collapse.duration, IslandMotion.collapseDuration + 0.12,
                                     "\(Int(hz))Hz collapse ran for \(Int(collapse.duration * 1000))ms")
            XCTAssertLessThanOrEqual(expand.duration, IslandMotion.expandDuration + 0.12,
                                     "\(Int(hz))Hz expand ran for \(Int(expand.duration * 1000))ms")
        }
    }

    /// A dead tail is the part the eye reads as "didn't finish": the run is
    /// still stepping, still costing a compositor tick, but nothing on screen
    /// has changed for a while.
    func testNeitherRunWastesFramesAfterTheMotionIsOver() {
        for (name, trace) in [
            ("expand", simulate(from: compact, to: expanded, expanding: true)),
            ("collapse", simulate(from: expanded, to: compact, expanding: false)),
        ] {
            report(name, trace)
            XCTAssertLessThanOrEqual(trace.duration - trace.lastVisibleChange, 0.02,
                                     "\(name) keeps stepping for \(Int((trace.duration - trace.lastVisibleChange) * 1000))ms after the last visible change")
        }
    }

    /// The pop a *retarget* produces, which is the case the live trace shows:
    /// the hover widen is still carrying velocity when the measured inbox
    /// height arrives, so `FloatingPanel` re-aims the same spring
    /// (`run.spring.target = …`) instead of restarting it. A from-rest run
    /// never overshoots at all, so the excursion has to be measured here.
    private func simulateRetarget(through mid: NSRect, after midTicks: Int,
                                  to goal: NSRect, dt: TimeInterval = 1.0 / 60.0) -> Trace {
        let firstLanding = FloatingPanel.landing(mid)
        var spring = IslandFrameSpring(
            position: FloatingPanel.landing(compact),
            target: FloatingPanel.springTarget(for: firstLanding),
            expanding: true)
        var painted = FloatingPanel.landing(compact)
        var t = 0.0
        var ticks = 0
        for _ in 0..<midTicks {
            t += dt; ticks += 1
            spring.step(dt: dt)
            painted = FloatingPanel.landing(spring.frame)
        }
        // Re-aim, keeping the velocity the run has built up.
        let landing = FloatingPanel.landing(goal)
        spring.target = FloatingPanel.springTarget(for: landing)

        var lastPainted = painted
        var lastVisibleChange = t
        var peak = SIMD4<Double>.zero
        var arrived = false
        var flips = 0
        let cap = 2.0
        while t < cap {
            t += dt
            ticks += 1
            spring.step(dt: dt)
            painted = FloatingPanel.landing(spring.frame)
            if painted != lastPainted {
                if crossedGoal(lastPainted, painted, landing) { flips += 1 }
                lastPainted = painted
                lastVisibleChange = t
            }
            // The run is 200+ pt away the instant the target moves; only from
            // the first arrival onward does further travel count as pop. The
            // pop happens *after* that first pass, so the run keeps going to
            // its real settle test.
            if simd_length(painted - landing) < 1.0 { arrived = true }
            if arrived { peak = simd_max(peak, simd_abs(painted - landing)) }
            if spring.hasArrived(painted: painted, landing: landing) || spring.hasSettled { break }
        }
        return Trace(duration: t - Double(midTicks) * dt, lastVisibleChange: lastVisibleChange,
                     overshoot: peak, edgeFlips: flips, ticks: ticks)
    }

    /// A mid-flight retarget — the hover widen is still running when the
    /// measured inbox height arrives, and `FloatingPanel` re-aims the same
    /// spring rather than starting a new one.
    ///
    /// Bounded on the way *past* the goal, not on the pop itself: a live
    /// `WCHUD_ANIMATION_DEBUG=fast` trace showed +9 pt of height on this
    /// sequence, and a smaller pop is a taste change, not a defect. A run that
    /// throws the island a layout past its body, or that shudders across the
    /// pixel grid on the way in, is neither.
    func testRetargetPopsWithoutThrowingTheIslandPastItsBody() {
        let trace = simulateRetarget(through: NSRect(x: 637.5, y: 1085.0, width: 453.0, height: 32.0),
                                     after: 12, to: expanded)
        report("retarget", trace)
        XCTAssertLessThanOrEqual(trace.overshoot.w, 16, "height overshoot \(trace.overshoot.w)pt")
        XCTAssertLessThanOrEqual(trace.overshoot.z, 12, "width overshoot \(trace.overshoot.z)pt")
        XCTAssertLessThanOrEqual(trace.edgeFlips, 1, "retarget shudders: \(trace.edgeFlips) crossings")
        XCTAssertLessThanOrEqual(trace.duration, IslandMotion.expandDuration + 0.08,
                                 "retarget took \(Int(trace.duration * 1000))ms")
    }
}
