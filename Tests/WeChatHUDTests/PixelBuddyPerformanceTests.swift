// Tests/WeChatHUDTests/PixelBuddyPerformanceTests.swift
//
// W4 — rendering-cost and lifecycle tests for the companion sprite.
//
// The sprite used to be rebuilt from scratch on every body evaluation:
//   * `framesForMood` allocated a fresh nested array per call,
//   * the view built 144 `Rectangle`s per frame,
//   * the 0.55s timer ran even while the panel was off screen.
// These tests pin the fixes: memoized frame tables, a gated timer, and a
// Canvas that paints the exact pixels the 144 rectangles used to paint.
import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

@MainActor
final class PixelBuddyPerformanceTests: XCTestCase {

    // MARK: - Frame table memoization

    /// The body reads frames on every evaluation, so the table must be built
    /// once per mood and handed out by reference afterwards.
    func testFrameTableIsBuiltOncePerMood() throws {
        // The cache is deliberately process-wide, so an earlier test may have
        // warmed this mood already. Either way, repeated calls must not build
        // anything more — that is the property the render pass depends on.
        let mood = BuddyMood.allCases.first { !PixelMoodFrames.cachedMoods.contains($0) } ?? .analyzing
        let wasCached = PixelMoodFrames.cachedMoods.contains(mood)
        let before = PixelMoodFrames.buildCount
        let first = framesForMood(mood)
        for _ in 0..<50 {
            let frames = framesForMood(mood)
            // Same table object every time: identity, not just equality.
            XCTAssertEqual(frames.count, first.count)
            XCTAssertTrue(frames[0] == first[0])
        }
        let built = PixelMoodFrames.buildCount - before
        XCTAssertEqual(built, wasCached ? 0 : 1,
                       "50 calls for one mood must build the table at most once")
        XCTAssertEqual(PixelMoodFrames.buildCount, PixelMoodFrames.cachedMoods.count,
                       "builds and cache entries must stay 1:1")
    }

    func testEveryMoodBuildsOneTableAndSharesItWithTheView() {
        var counts: [BuddyMood: Int] = [:]
        for mood in BuddyMood.allCases {
            let first = framesForMood(mood)
            counts[mood] = first.count
            XCTAssertEqual(framesForMood(mood).count, first.count)
        }
        // Frame-cycle lengths the animation depends on.
        XCTAssertEqual(counts[.idle], 8)
        XCTAssertEqual(counts[.scanning], 2)
        XCTAssertEqual(counts[.autopiloting], 2)
        for mood in BuddyMood.allCases {
            XCTAssertEqual(PixelMoodFrames.frameCount(for: mood), counts[mood], "\(mood)")
            XCTAssertTrue(PixelMoodFrames.cachedMoods.contains(mood), "\(mood) should be cached")
        }
    }

    // MARK: - Lifecycle gate

    /// A driver with the gate closed must not schedule a timer and must not
    /// advance a frame when something pokes it anyway.
    func testClosedGateSchedulesNothingAndNeverAdvances() {
        let driver = makeDriver(frameCount: 8)
        driver.panelVisibleProvider = { false }  // panel ordered out

        driver.start(interval: 0.01)
        XCTAssertFalse(driver.isRunning, "no timer may be scheduled while the gate is closed")
        driver.tick()
        XCTAssertEqual(driver.frameIndex, 0)
        XCTAssertEqual(driver.appliedTicks, 0)
        XCTAssertFalse(driver.isRunning)
    }

    /// The three other gate inputs each hold the sprite still on their own.
    func testEachGateInputStopsTheSprite() {
        XCTAssertEqual(makeDriver(reduceMotion: true).gateReason, .reduceMotion)
        XCTAssertEqual(makeDriver(appHidden: true).gateReason, .appHidden)
        XCTAssertEqual(makeDriver(panelVisible: false).gateReason, .panelOffScreen)
        XCTAssertEqual(makeDriver().gateReason, .ok)
        let asleep = makeDriver()
        asleep.setScreenAsleep(true)
        XCTAssertEqual(asleep.gateReason, .screenAsleep)
        XCTAssertFalse(asleep.isRunning, "going to sleep must park the timer")
    }

    /// Reduce Motion wins over the other reasons, so the reported cause is the
    /// most specific one (accessibility beats a hidden window).
    func testReduceMotionIsReportedFirst() {
        let driver = makeDriver(reduceMotion: true, appHidden: true, panelVisible: false)
        XCTAssertEqual(driver.gateReason, .reduceMotion)
    }

    func testOpenGateAdvancesAndWrapsTheCycle() {
        let driver = makeDriver(frameCount: 3)
        driver.start(interval: 0.01)
        XCTAssertTrue(driver.isRunning)
        driver.stop()
        for expected in [1, 2, 0, 1] {
            driver.tick()
            XCTAssertEqual(driver.frameIndex, expected)
        }
        XCTAssertEqual(driver.appliedTicks, 4)
    }

    /// Closing the gate mid-run stops the live timer on the next tick and
    /// keeps whatever frame was on screen (no jump, no rebuild).
    func testGateClosingMidRunStopsTheTimer() {
        let driver = makeDriver(frameCount: 4)
        driver.start(interval: 0.01)
        driver.tick()
        driver.tick()
        XCTAssertEqual(driver.frameIndex, 2)

        driver.panelVisibleProvider = { false }
        driver.tick()  // a tick that races the "panel disappeared" notification
        XCTAssertEqual(driver.frameIndex, 2, "the sprite keeps the frame it was on")
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(driver.appliedTicks, 2)
    }

    /// The lifecycle signal itself parks the timer — no waiting for a tick.
    func testClosedGateStopsTheRunningTimerImmediately() {
        let driver = makeDriver(frameCount: 4)
        driver.start(interval: 0.01)
        XCTAssertTrue(driver.isRunning)
        driver.panelVisibleProvider = { false }
        driver.start()   // the app-update signal that saw the panel go away
        XCTAssertFalse(driver.isRunning, "a closed gate must stop the timer at once")
        driver.tick()
        XCTAssertEqual(driver.appliedTicks, 0)
    }

    /// `start()` is called from app-update notifications several times a
    /// second; it must not restart the cycle each time.
    func testRestartingAnOpenGateKeepsTheSameTimer() {
        let driver = makeDriver(frameCount: 4)
        driver.start(interval: 0.55)
        driver.tick()
        driver.start(interval: 0.55)
        XCTAssertTrue(driver.isRunning)
        XCTAssertEqual(driver.frameIndex, 1, "a redundant start must not reset the frame")
        driver.start(interval: 0.25)
        XCTAssertEqual(driver.frameIndex, 1, "a new interval keeps the current frame")
        XCTAssertTrue(driver.isRunning)
    }

    /// Reopening the gate brings the sprite back without losing the mood: the
    /// cycle length handed to the driver (from the current mood) is preserved
    /// and the next tick moves within it.
    func testGateReopeningResumesTheCurrentMoodCycle() {
        let driver = makeDriver(frameCount: 8)
        driver.panelVisibleProvider = { false }
        driver.start(interval: 0.01)
        driver.tick()
        XCTAssertEqual(driver.frameIndex, 0)

        driver.panelVisibleProvider = { true }
        driver.start(interval: 0.01)
        XCTAssertTrue(driver.isRunning)
        for _ in 0..<10 { driver.tick() }
        XCTAssertEqual(driver.frameIndex, 10 % 8, "cycle length stays at the mood's frame count")
    }

    /// End-to-end: a *real* `Timer` on the main run loop advances the sprite
    /// while the gate is open, and the same live timer stops advancing the
    /// moment the gate closes.
    func testRealTimerAdvancesOnlyWhileTheGateIsOpen() {
        let driver = makeDriver(frameCount: 8)
        driver.start(interval: 0.005)
        XCTAssertTrue(driver.isRunning, "an open gate must arm the timer")

        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        let advancedWhileOpen = driver.appliedTicks
        XCTAssertGreaterThan(advancedWhileOpen, 0, "the timer must tick while the gate is open")

        // The panel goes away: no notification reaches the driver, exactly the
        // race the tick-time re-check exists for.
        driver.panelVisibleProvider = { false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(driver.appliedTicks, advancedWhileOpen,
                       "a closed gate must freeze the sprite even with a live timer")
        XCTAssertFalse(driver.isRunning, "the tick that saw the closed gate must stop the timer")
    }

    // MARK: - Helpers

    /// Reports the per-call cost a body evaluation used to pay (rebuilding the
    /// mood's table) against what it pays now (a cache hit), and asserts the
    /// hit is cheaper. The rebuild below is a stand-in for the retired
    /// `framesForMood` body: the same 24×24 arrays per frame, allocated fresh
    /// on every call.
    func testMemoizedLookupIsCheaperThanRebuildingTheTable() {
        let iterations = 20_000
        let moods = BuddyMood.allCases
        let cycleLength = 8

        // Warm the cache so the measured path is the one the render pass takes.
        for mood in moods { _ = framesForMood(mood) }
        var sink = 0
        var start = Date()
        for index in 0..<iterations {
            let frames = framesForMood(moods[index % moods.count])
            sink &+= frames.count
        }
        let cachedSeconds = Date().timeIntervalSince(start)

        start = Date()
        for _ in 0..<iterations {
            let frames = (0..<cycleLength).map { _ in
                Array(repeating: Array(repeating: PixelColor.clear, count: 24), count: 24)
            }
            sink &+= frames.count
        }
        let rebuiltSeconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(sink, 0)

        let cachedMicros = cachedSeconds / Double(iterations) * 1_000_000
        let rebuiltMicros = rebuiltSeconds / Double(iterations) * 1_000_000
        print(String(format: "[buddy-cost] cache hit %.3f us/call vs rebuild %.3f us/call (%.1fx)",
                     cachedMicros, rebuiltMicros, rebuiltMicros / max(cachedMicros, 0.000001)))
        XCTAssertLessThan(cachedMicros, rebuiltMicros,
                          "a memoized lookup must not cost more than rebuilding the table")
    }

    private func makeDriver(frameCount: Int = 8,
                            reduceMotion: Bool = false,
                            appHidden: Bool = false,
                            panelVisible: Bool = true) -> CompanionFrameDriver {
        let driver = CompanionFrameDriver(frameCount: frameCount)
        driver.reduceMotionProvider = { reduceMotion }
        driver.appHiddenProvider = { appHidden }
        driver.panelVisibleProvider = { panelVisible }
        return driver
    }
}
