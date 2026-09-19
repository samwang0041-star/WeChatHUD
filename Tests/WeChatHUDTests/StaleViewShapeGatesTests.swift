import XCTest
@testable import WeChatHUD

/// Gates for the one bug class the view layer cannot prove behaviorally: a view
/// that keeps a value it derived once from something that changes underneath it.
/// None of these three surfaces has a test seam — hosting a `View` and driving
/// `@State` from an XCTest is not possible here — so the shape is pinned at the
/// source instead, because each one is a user-visible wrong fact rather than a
/// cosmetic stale frame.
final class StaleViewShapeGatesTests: XCTestCase {

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (try? String(contentsOfFile: root + "/Sources/WeChatHUD/" + relative, encoding: .utf8)) ?? ""
    }

    /// 「这件事从哪里来」 stays mounted while the 待办 selection changes under it
    /// (row click, range pill, search, or a scan auto-completing the open item).
    /// An un-keyed `.task` left the previous item's chat window on screen under
    /// the new item's title.
    func testSourcePaneKeysItsLoadToTheItemItDisplays() {
        let file = source("Views/DiscussionSourceView.swift")
        XCTAssertFalse(file.isEmpty, "DiscussionSourceView not found")
        XCTAssertTrue(
            file.contains(".task(id: item.id)"),
            "the source window must reload when the item changes under a mounted view"
        )
        XCTAssertFalse(
            file.contains(".task {"),
            "an un-keyed task here is the stale-source bug coming back"
        )
    }

    /// The sidebar's per-day counts are computed by a walk that takes one read
    /// per chat, so a fast date switch can land the older result last; and a
    /// chat with zero messages that day must not fall back to the *window*
    /// count, which is a different question.
    func testSidebarDayStatsGuardTheirOwnRequest() {
        let file = source("Views/Analytics/InsightSidebarView.swift")
        XCTAssertFalse(file.isEmpty, "InsightSidebarView not found")
        XCTAssertTrue(
            file.contains("guard key == dayStatsTaskID"),
            "the async write must drop a result whose request is no longer current"
        )
        XCTAssertTrue(
            file.contains("dayStatsByChat[username]?.messageCount ?? 0"),
            "a day with no record has to read as zero, not as the window total"
        )
    }

    /// The 周报 roll-up counts a catalog snapshot; without a live trigger it
    /// kept yesterday's numbers across a scan and across an account switch.
    func testWeeklyReportFollowsTheLiveDiscussionList() {
        let file = source("Views/DailyReportTabView.swift")
        XCTAssertFalse(file.isEmpty, "DailyReportTabView not found")
        XCTAssertTrue(
            file.contains("onChange(of: monitor.discussionItems"),
            "the weekly catalog must be re-read when the rows it counts change"
        )
    }
    /// The detail pane reads its transcript through a freshly built reader actor
    /// per call, and the @-focus jump spawns an unstructured Task that
    /// `.task(id:)` cannot cancel — so the losing read published chat A's
    /// bubbles inside chat B's pane under B's title, and the user composed to B
    /// off A's text.
    func testTranscriptPublishesOnlyForItsOwnRequest() {
        let file = source("Views/ConversationDetailView.swift")
        XCTAssertFalse(file.isEmpty, "ConversationDetailView not found")
        let body = file.range(of: "private func loadTranscriptAndIdentity")
            .map { String(file[$0.lowerBound...].prefix(1_800)) } ?? ""
        let guardAt = body.range(of: "guard token == transcriptToken")?.lowerBound
        let lastAwait = body.range(of: "monitor.recentMessagesAsync")?.lowerBound
        let write = body.range(of: "transcriptRows = FocusedTranscript")?.lowerBound
        XCTAssertNotNil(guardAt, "换对话时晚到的读必须被 token 拦住")
        XCTAssertNotNil(lastAwait)
        XCTAssertNotNil(write)
        if let g = guardAt, let a = lastAwait {
            XCTAssertTrue(g > a, "守卫要在最后一次 await 之后，否则拦不住晚到的回填")
        }
        if let g = guardAt, let w = write {
            XCTAssertTrue(g < w, "守卫必须挡在写 transcriptRows 前面")
        }
    }
    /// A persisted inbox watermark must not be a bare `Int(date)`: a Date built
    /// from WeChat's `create_time` can be 2^63 (traps the conversion) or dated
    /// ahead of now, and `rebuildInbox` reads a `silencedAt` past the permanent
    /// threshold as "this chat is muted forever".
    func testWatermarksGoThroughTheClampedConversion() {
        let file = source("Services/ChatMonitor.swift")
        XCTAssertFalse(file.isEmpty, "ChatMonitor not found")
        XCTAssertFalse(
            file.contains("Int(item.timestamp.timeIntervalSince1970)"),
            "水位写入必须走 MessageHelpers.watermarkSeconds"
        )
        XCTAssertTrue(file.contains("MessageHelpers.watermarkSeconds("))
    }
}

extension StaleViewShapeGatesTests {

    /// 24 格/7 格的直方图是按固定位置索引的，缓存过的洞察行少给一格就是
    /// "打开洞察总览时进程消失"，而不是少画一根柱子。
    func testFixedPositionHistogramsArePadded() throws {
        XCTAssertEqual(MessageHelpers.buckets([1, 2], count: 7), [1, 2, 0, 0, 0, 0, 0])
        XCTAssertEqual(MessageHelpers.buckets([], count: 24).count, 24)
        XCTAssertEqual(MessageHelpers.buckets([5, 6, 7], count: 2), [5, 6])
        let exact = Array(repeating: 1, count: 24)
        XCTAssertEqual(MessageHelpers.buckets(exact, count: 24), exact)

        for (file, fn, count) in [
            ("Views/Analytics/InsightOverviewDashboard.swift", "weekdayBars(_ messagesByWeekday", 7),
            ("Views/Analytics/InsightOverviewDashboard.swift", "hourlyBarChart(_ messagesByHour", 24),
            ("Views/Analytics/ChatInsightDetailView.swift", "hourlyBarChart(_ messagesByHour", 24),
        ] {
            let body = source(file).range(of: fn)
                .map { String(source(file)[$0.lowerBound...].prefix(200)) } ?? ""
            XCTAssertTrue(body.contains("MessageHelpers.buckets("), "\(file).\(fn) 未做定长归一")
            XCTAssertTrue(body.contains("count: \(count)"), "\(file).\(fn) 的格数不对")
        }
    }
}
