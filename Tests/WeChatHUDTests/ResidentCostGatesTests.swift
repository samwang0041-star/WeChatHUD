import XCTest
@testable import WeChatHUD

/// Cost gates for a process that never quits.
///
/// Two of these surfaces could spend unbounded time per event: the insight
/// page re-ran a library-wide walk on every completed scan (measured on this
/// machine: 4648 shard/table pairs, ~288k rows), and every AX lookup in the
/// send path walked WeChat's whole element tree on the main actor with the
/// default per-call messaging timeout — which is the thread that draws the
/// island. Both are off-main or on-main stalls that repeat forever, so they are
/// pinned here rather than left to a review of the call graph.
final class ResidentCostGatesTests: XCTestCase {

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (try? String(contentsOfFile: root + "/Sources/WeChatHUD/" + relative, encoding: .utf8)) ?? ""
    }

    // MARK: - Insight reload

    /// A scan tick is not evidence that anything arrived, so it cannot trigger
    /// a full reload on its own schedule.
    func testScanTickReloadIsRateLimited() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(InsightStore.AutoReload.permitted(last: nil, now: now))
        XCTAssertFalse(
            InsightStore.AutoReload.permitted(last: now.addingTimeInterval(-30), now: now),
            "a reload 30s ago must not be followed by another library-wide walk"
        )
        XCTAssertTrue(
            InsightStore.AutoReload.permitted(
                last: now.addingTimeInterval(-InsightStore.AutoReload.interval), now: now)
        )
    }

    /// The page's own triggers (open, window, scope, date) are user intent and
    /// must stay immediate; only the scan tick is rate-limited.
    func testOnlyTheScanTickUsesTheNewDataTrigger() {
        let view = source("Views/Analytics/ChatInsightView.swift")
        XCTAssertFalse(view.isEmpty, "ChatInsightView not found")
        guard let start = view.range(of: "onChange(of: monitor.stats.lastSyncAt)") else {
            XCTFail("the scan-tick reload was removed; update this gate"); return
        }
        let block = view[start.lowerBound...].prefix(400)
        XCTAssertTrue(
            block.contains("trigger: .newData"),
            "the scan tick must go through the rate limit, not reload synchronously"
        )
        XCTAssertEqual(
            view.components(separatedBy: "reloadInsightStats(trigger: .newData)").count - 1, 1,
            "only the scan tick may use the rate-limited trigger"
        )
    }

    // MARK: - AX walks

    /// Every AX element the launcher holds must carry a messaging timeout: an
    /// AX read is a blocking round trip into WeChat, and the default is long
    /// enough to freeze the island.
    func testAXApplicationElementsCarryAMessagingTimeout() {
        let launcher = source("Services/WeChatLauncher.swift")
        XCTAssertFalse(launcher.isEmpty, "WeChatLauncher not found")
        let creationSites = launcher.components(separatedBy: "AXUIElementCreateApplication(").count - 1
        XCTAssertEqual(
            creationSites, 1,
            "raw AXUIElementCreateApplication bypasses the timeout; go through axApplication(processID:)"
        )
        XCTAssertTrue(
            launcher.contains("AXUIElementSetMessagingTimeout"),
            "the timeout helper disappeared"
        )
    }

    /// A depth cap is not a bound: WeChat's tree is wide, and every node costs
    /// one to four blocking reads.
    func testAXWalksHaveANodeBudget() {
        let launcher = source("Services/WeChatLauncher.swift")
        XCTAssertTrue(launcher.contains("maxNodes"), "dfsAX lost its node budget")
        XCTAssertTrue(launcher.contains("remaining > 0"), "the search-result walk lost its budget")
    }
}
