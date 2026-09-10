// Tests/WeChatHUDTests/PixelBuddyTests.swift
import XCTest
@testable import WeChatHUD

final class PixelBuddyTests: XCTestCase {

    // MARK: - Compact mood derivation

    /// 1.2.3 made the island still: a background scan tick must not repaint the
    /// companion into a scanning state. This asserts the post-1.2.3 contract —
    /// syncing alone leaves the buddy idle — superseding the earlier
    /// expectation that .syncing surfaced as .scanning.
    func testCompactMood_syncingStaysStill() {
        let mood = deriveCompactMood(syncStatus: .syncing, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .idle)
    }

    func testCompactMood_syncError_returnsError() {
        let mood = deriveCompactMood(syncStatus: .error("fail"), hasUrgent: true, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .error, "error takes priority over urgent")
    }

    func testCompactMood_waitingForWeChat_returnsError() {
        let mood = deriveCompactMood(syncStatus: .waitingForWeChat, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .error)
    }

    func testCompactMood_stale_returnsError() {
        let mood = deriveCompactMood(syncStatus: .stale, hasUrgent: false, hasPending: false, idleMinutes: 0)
        XCTAssertEqual(mood, .error)
    }

    func testCompactMood_urgent_returnsUrgent() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: true, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .urgent, "urgent takes priority over pending")
    }

    func testCompactMood_pending_returnsPending() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: true, idleMinutes: 0)
        XCTAssertEqual(mood, .pending)
    }

    func testCompactMood_idle5min_returnsSleepy() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: false, idleMinutes: 5)
        XCTAssertEqual(mood, .sleepy)
    }

    func testCompactMood_idle3min_returnsIdle() {
        let mood = deriveCompactMood(syncStatus: .ok, hasUrgent: false, hasPending: false, idleMinutes: 3)
        XCTAssertEqual(mood, .idle)
    }

    // MARK: - Extended mood derivation

    func testExtendedMood_emptyInbox_returnsCelebrating() {
        let mood = deriveExtendedMood(actionItemCount: 0, isAIProcessing: false)
        XCTAssertEqual(mood, .celebrating)
    }

    func testExtendedMood_aiProcessing_returnsAnalyzing() {
        let mood = deriveExtendedMood(actionItemCount: 3, isAIProcessing: true)
        XCTAssertEqual(mood, .analyzing)
    }

    func testExtendedMood_hasItems_returnsBrowsing() {
        let mood = deriveExtendedMood(actionItemCount: 3, isAIProcessing: false)
        XCTAssertEqual(mood, .browsing)
    }
}
