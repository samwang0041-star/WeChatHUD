import XCTest
@testable import WeChatHUD

/// The heartbeat's own cadences are process-observed windows, and the repo
/// already has a rule for those (`MonotonicClock`): `Date` is an instant the
/// system *owns*, so it can move backward under a long-running process — which
/// is precisely what a 24/7 overlay is.
///
/// On wall clock a backward correction (what macOS applies on resume after a
/// timezone change) made each delta negative, so the fallback scan and every
/// proactive reminder — VIP 升档、承诺到期、多条未回 — stopped firing for the size
/// of the step, hours to days, while the island chrome still read normal. The
/// 8-second post-automation window failed the other way and swallowed the
/// *user's own* activation into WeChat, which is the state where autopilot must
/// not send.
final class HeartbeatCadenceAxisTests: XCTestCase {

    // MARK: - The predicate

    func testWindowElapsedTreatsNeverRanAsDue() {
        XCTAssertTrue(ChatMonitor.windowElapsed(since: nil, now: 10_000, interval: 60),
                      "从没跑过必须算「到点」，否则第一个 tick 就把它当刚跑过")
        XCTAssertFalse(ChatMonitor.windowElapsed(since: 1_000, now: 1_030, interval: 60))
        XCTAssertTrue(ChatMonitor.windowElapsed(since: 1_000, now: 1_060, interval: 60))
        // The axis cannot go backward, so a stuck clock can never re-open a
        // window that already closed — which is what `Date()` allowed.
        XCTAssertTrue(ChatMonitor.windowElapsed(since: 1_000, now: 1_000, interval: 0))
    }

    // MARK: - The axis it is actually wired to

    /// A cadence anchor that is set from `Date()` and compared against `Date()`
    /// is off-axis, and the only durable defence is that the field type itself
    /// is `TimeInterval?` — so this counts the wall-clock spellings instead.
    func testCadenceAnchorsUseNoWallClock() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ChatMonitor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for anchor in ["lastSafetyScanAt", "lastProactiveOutreachAt", "lastAutomationActivationAt"] {
            let writes = source.components(separatedBy: "\(anchor) = Date()").count - 1
            XCTAssertEqual(writes, 0, "\(anchor) 又回到墙上时钟了")
            let reads = source.components(separatedBy: "timeIntervalSince(self.\(anchor)").count - 1
                + source.components(separatedBy: "timeIntervalSince(\(anchor)").count - 1
            XCTAssertEqual(reads, 0, "\(anchor) 的比较必须走 windowElapsed/单调轴")
        }
        let uses = source.components(separatedBy: "Self.windowElapsed(").count - 1
        XCTAssertGreaterThanOrEqual(uses, 2, "两处节拍都要真的用上这个判据")
    }

    /// The whole reason this axis exists: a `Date()` window is a *calendar*
    /// answer, so this proves the injected clock is what the cadence reads.
    func testCadenceReadsTheInjectableMonotonicClock() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ChatMonitor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(
            source.components(separatedBy: "monotonicNow()").count - 1, 4,
            "锚点写入和读取都要走同一个可注入的单调时钟")
    }
}
