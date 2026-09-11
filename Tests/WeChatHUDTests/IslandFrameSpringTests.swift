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
