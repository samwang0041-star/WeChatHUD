import XCTest
import simd
@testable import WeChatHUD

/// Pins the panel-frame spring's settle behaviour.
///
/// These exist because of a shipped bug: the integrator re-read the
/// window's `frame` as its position on every tick, but AppKit stores
/// window rects as whole points. The read-back therefore rounded the
/// spring's own residual away each tick, the run froze 2–3 pt short of
/// its target with a permanent velocity, and the settle test could never
/// pass. The run only ended at the 2.5 s wedge cap, whose exact-target
/// snap is what the user saw as "the island flashes and shifts a few
/// pixels a few seconds after the mouse enters".
final class IslandFrameSpringTests: XCTestCase {

    /// What AppKit does to a rect handed to `NSWindow.setFrame`: the origin
    /// is floored, the size ceiled to whole points. Verified against a live
    /// panel (requested `x: -1145.696 w: 562.544` → applied
    /// `x: -1146 w: 563`).
    private func quantized(_ v: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(v.x.rounded(.down), v.y.rounded(.down), v.z.rounded(.up), v.w.rounded(.up))
    }

    private func quantized(_ r: NSRect) -> SIMD4<Double> {
        quantized(SIMD4(r.origin.x, r.origin.y, r.size.width, r.size.height))
    }

    /// The hover-expand that reproduced the report: compact pill →
    /// expanded inbox, at 60 Hz.
    private let compact = SIMD4<Double>(896, 0, 128, 32)
    private let expanded = SIMD4<Double>(680, 0, 560, 150)

    private func runTicks(spring: inout IslandFrameSpring,
                          dt: TimeInterval = 1.0 / 60.0,
                          limit: Int = 600) -> Int {
        var ticks = 0
        while !spring.hasSettled && ticks < limit {
            spring.step(dt: dt)
            ticks += 1
        }
        return ticks
    }

    func testExpandSettlesWellInsideTheWedgeCap() {
        var spring = IslandFrameSpring(position: compact, target: expanded, expanding: true)
        let ticks = runTicks(spring: &spring)
        XCTAssertTrue(spring.hasSettled, "expand must settle on its own, not at the wedge cap")
        // ~0.44 s measured on a live panel; the wedge cap is 2.5 s / 150
        // ticks. A regression that reintroduces the freeze lands exactly on
        // the cap, so anything at the cap is a failure.
        XCTAssertLessThan(ticks, 60, "expand took \(ticks) ticks (\(Double(ticks) / 60)s)")
        XCTAssertLessThan(simd_distance(spring.position, expanded), 1)
    }

    func testCollapseSettlesWellInsideTheWedgeCap() {
        var spring = IslandFrameSpring(position: expanded, target: compact, expanding: false)
        let ticks = runTicks(spring: &spring)
        XCTAssertTrue(spring.hasSettled, "collapse must settle on its own, not at the wedge cap")
        XCTAssertLessThan(ticks, 60, "collapse took \(ticks) ticks (\(Double(ticks) / 60)s)")
        XCTAssertLessThan(simd_distance(spring.position, compact), 1)
    }

    /// The regression itself: the window quantizes every frame it applies.
    /// The spring must still settle, because it integrates its own position
    /// and only *paints* quantized rects.
    func testSettlesWhenEveryPaintedFrameIsQuantized() {
        var spring = IslandFrameSpring(position: compact, target: expanded, expanding: true)
        var painted = spring.frame
        var ticks = 0
        while !spring.hasSettled && ticks < 600 {
            spring.step(dt: 1.0 / 60.0)
            // What the window server actually keeps.
            painted = spring.frame
            ticks += 1
        }
        XCTAssertTrue(spring.hasSettled)
        XCTAssertLessThan(ticks, 60)
        // What the window actually stores, and how far that is from the
        // goal — the wedge cap's correction snap has nothing visible left
        // to correct.
        let stored = quantized(painted)
        XCTAssertEqual(stored.x, stored.x.rounded())
        XCTAssertEqual(stored.z, stored.z.rounded())
        XCTAssertLessThan(abs(stored.x - expanded.x), 1)
        XCTAssertLessThan(abs(stored.z - expanded.z), 1)
        XCTAssertLessThan(abs(stored.w - expanded.w), 1)
    }

    /// Executable record of the removed behaviour, so the reason the
    /// position is held in the spring (and not read back from the window)
    /// cannot be lost. It reproduces the limit cycle that was measured on a
    /// live panel: a 2–3 pt offset with a constant `k · offset / c` speed,
    /// both frozen, above `settleVelocity` forever.
    func testReReadingTheQuantizedWindowFreezesTheRunShortOfTarget() {
        var position = compact
        var velocity = SIMD4<Double>.zero
        let (k, c) = IslandMotion.spring(expanding: true)
        let dt = 1.0 / 60.0

        var previous = position
        for _ in 0..<600 {
            let accel = -k * (position - expanded) - c * velocity
            velocity += accel * dt
            position += velocity * dt
            // The window rounds what it is given, and the next tick reads it back.
            position = quantized(position)
            previous = position
        }

        let offset = simd_distance(previous, expanded)
        XCTAssertGreaterThan(offset, IslandMotion.settleDistance,
                             "the quantized read-back is meant to strand the run short of its target")
        XCTAssertGreaterThan(simd_length(velocity), IslandMotion.settleVelocity,
                             "and to leave it permanently above the settle velocity")
        // Velocity is pinned by the frozen offset, not decaying: at
        // equilibrium the damping term exactly cancels the spring term.
        XCTAssertEqual(simd_length(velocity), k * offset / c, accuracy: 0.5)
        XCTAssertFalse(IslandFrameSpring(position: previous, target: expanded, expanding: true)
            .hasSettled, "so the settle test can never pass — only the wedge cap ends the run")
    }

    // MARK: - Landing on the pixel grid

    /// A window is painted on whole points, so the run has to aim where the
    /// server will actually store it. AppKit floors the origin and ceils the
    /// size; the exact ideal rect is therefore unreachable from above, and a
    /// spring that keeps converging on it stalls a point outside.
    func testLandingRectIsWhatTheWindowServerStores() {
        // The traced hover: an expanded pane measured 560×252 with a
        // fractional origin, and the compact pill sits on a half point.
        XCTAssertEqual(FloatingPanel.landing(NSRect(x: 584, y: 865, width: 560, height: 252)),
                       SIMD4(584, 865, 560, 252))
        XCTAssertEqual(FloatingPanel.landing(NSRect(x: 715.5, y: 1085, width: 297, height: 32)),
                       SIMD4(715, 1085, 297, 32))
        // 560.1 → 561 and 500.6 → 500 are the live-verified rules.
        XCTAssertEqual(FloatingPanel.landing(NSRect(x: 500.6, y: 100, width: 560.1, height: 252.4)),
                       SIMD4(500, 100, 561, 253))
    }

    /// The aim point must be the centre of the cell that quantizes to the
    /// landing rect, so that the *stored* rect equals the landing rect for the
    /// whole settling motion — that is what leaves the run with nothing to
    /// correct on its final frame.
    func testSpringAimsAtTheCentreOfTheLandingCell() {
        let landing = FloatingPanel.landing(NSRect(x: 584, y: 865, width: 560, height: 252))
        let aim = FloatingPanel.springTarget(for: landing)
        XCTAssertEqual(aim, SIMD4(584.5, 865.5, 559.5, 251.5))

        // Any residual the spring can still have (< ½ pt) quantizes back to the
        // landing rect: floor(origin + ½ ± ½) and ceil(size − ½ ± ½).
        for drift in [-0.49, -0.25, 0.0, 0.25, 0.49] {
            let position = aim + SIMD4(repeating: drift)
            XCTAssertEqual(quantized(position), landing,
                           "a residual of \(drift) pt changed the stored rect")
        }
    }

    /// The end test reads the *stored* rect, so it cannot declare victory while
    /// the pixels still have a point to move — and it does not wait for the
    /// asymptote either, which is what turned the last frame into a jolt.
    func testArrivalIsJudgedOnStoredPixelsNotOnTheAsymptote() {

        let landing = SIMD4<Double>(584, 865, 560, 252)
        var spring = IslandFrameSpring(
            position: FloatingPanel.springTarget(for: landing),
            target: FloatingPanel.springTarget(for: landing),
            expanding: true
        )
        spring.velocity = SIMD4(repeating: 5)
        XCTAssertTrue(spring.hasArrived(painted: landing, landing: landing))

        // One point out on the ceiled size — the stall the old code waited on.
        XCTAssertFalse(spring.hasArrived(painted: SIMD4(584, 865, 561, 253), landing: landing))
        // Moving fast through the right pixels is not an arrival either.
        spring.velocity = SIMD4(repeating: 200)
        XCTAssertFalse(spring.hasArrived(painted: landing, landing: landing))
    }

    /// Inside the arrival band an expand stops popping and borrows the
    /// critically damped pair, so the last couple of points converge from one
    /// side instead of crossing pixel boundaries a few times (the live trace
    /// stepped 1 pt three times in its final ~100 ms with the ring still on).
    func testArrivalBandSwitchesToTheCriticallyDampedPair() {
        // Outside the band the expand is underdamped — the pop out of the notch.
        let popping = IslandMotion.spring(expanding: true, distance: 50)
        let settling = IslandMotion.spring(expanding: false, distance: 50)
        XCTAssertNotEqual(popping.stiffness, settling.stiffness)
        XCTAssertNotEqual(popping.damping, settling.damping)

        // Inside it, both agree: the run arrives instead of ringing.
        let arriving = IslandMotion.spring(expanding: true, distance: 0.5)
        XCTAssertEqual(arriving.stiffness, settling.stiffness, accuracy: 0.0001)
        XCTAssertEqual(arriving.damping, settling.damping, accuracy: 0.0001)

        // A collapse never pops, wherever it is.
        XCTAssertEqual(IslandMotion.spring(expanding: false, distance: 50).stiffness,
                       IslandMotion.spring(expanding: false, distance: 0.5).stiffness,
                       accuracy: 0.0001)
    }

    /// End-to-end on the pixel grid: the expansion traced from the reported
    /// hover must finish with the stored rect already equal to the landing
    /// rect, and its last stretch must be monotone — the underdamped ring used
    /// to cross pixel boundaries three times in the final ~100 ms.
    func testHoverExpansionLandsOnTheStoredRectWithoutRinging() {
        // Real geometry from the trace: a compact pill at x 715.5 widening to a
        // measured 560×252 pane.
        let start = SIMD4<Double>(715.5, 1085, 297, 32)
        let ideal = SIMD4<Double>(584, 865, 560, 252)
        let landing = FloatingPanel.landing(NSRect(x: ideal.x, y: ideal.y, width: ideal.z, height: ideal.w))
        var spring = IslandFrameSpring(
            position: start,
            target: FloatingPanel.springTarget(for: landing),
            expanding: IslandMotion.isExpanding(
                from: NSRect(x: start.x, y: start.y, width: start.z, height: start.w),
                to: NSRect(x: ideal.x, y: ideal.y, width: ideal.z, height: ideal.w)
            )
        )

        var stored = quantized(start)
        var paintedWidths: [Double] = []
        var ticks = 0
        while !spring.hasArrived(painted: stored, landing: landing) && ticks < 600 {
            spring.step(dt: 1.0 / 60.0)
            // What the window server keeps for this tick.
            stored = quantized(spring.position)
            paintedWidths.append(stored.z)
            ticks += 1
        }

        XCTAssertLessThan(ticks, 60, "the expansion must arrive on its own, not at the wedge cap")
        XCTAssertEqual(stored, landing, "the run ended on pixels it was not showing")

        // Monotone over the tail: ringing shows up as the painted size going
        // back and forth across a pixel boundary.
        let tail = Array(paintedWidths.suffix(12))
        for (previous, next) in zip(tail, tail.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next,
                                     "the painted width went \(previous) → \(next) on the way in")
        }
    }

    /// Same contract on the way back: the collapse must land on the stored
    /// rect it is already showing.
    func testCollapseLandsOnTheStoredRect() {
        let start = SIMD4<Double>(584, 865, 560, 252)
        let compact = SIMD4<Double>(715.5, 1085, 297, 32)
        let landing = FloatingPanel.landing(
            NSRect(x: compact.x, y: compact.y, width: compact.z, height: compact.w))
        var spring = IslandFrameSpring(
            position: start,
            target: FloatingPanel.springTarget(for: landing),
            expanding: false
        )

        var stored = quantized(start)
        var ticks = 0
        while !spring.hasArrived(painted: stored, landing: landing) && ticks < 600 {
            spring.step(dt: 1.0 / 60.0)
            stored = quantized(spring.position)
            ticks += 1
        }
        XCTAssertLessThan(ticks, 60)
        XCTAssertEqual(stored, landing,
                       "the collapse ended \(ticks) ticks short: the finish snap would have jolted the pill")
    }

    func testSettleRequiresBothDistanceAndVelocity() {
        // Distance clear, still flying: not settled, or the spring would
        // stop the instant it crossed the target.
        var fast = IslandFrameSpring(position: expanded, target: expanded, expanding: true)
        fast.velocity = SIMD4(repeating: 400)
        XCTAssertFalse(fast.hasSettled)

        // Velocity clear, still far: not settled either.
        var far = IslandFrameSpring(position: compact, target: expanded, expanding: true)
        far.velocity = .zero
        XCTAssertFalse(far.hasSettled)

        XCTAssertTrue(IslandFrameSpring(position: expanded, target: expanded, expanding: true).hasSettled)
    }

    func testRetargetKeepsVelocitySoTheTrajectoryBendsInsteadOfRestarting() {
        // The first hover animates to the estimate, then the real
        // measurement retargets mid-flight (AppDelegate). Velocity must
        // survive, otherwise the motion visibly stops and re-launches.
        var spring = IslandFrameSpring(position: compact, target: expanded, expanding: true)
        for _ in 0..<6 { spring.step(dt: 1.0 / 60.0) }
        let carried = spring.velocity
        XCTAssertGreaterThan(simd_length(carried), 0)

        spring.target = SIMD4<Double>(680, 0, 560, 252)
        XCTAssertEqual(simd_length(spring.velocity), simd_length(carried), accuracy: 0.0001)
        spring.step(dt: 1.0 / 60.0)
        XCTAssertLessThan(simd_distance(spring.position, SIMD4<Double>(680, 0, 560, 252)),
                          simd_distance(compact, SIMD4<Double>(680, 0, 560, 252)))
    }
}
