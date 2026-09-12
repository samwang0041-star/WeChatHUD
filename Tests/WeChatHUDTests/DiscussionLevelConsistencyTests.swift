import XCTest
@testable import WeChatHUD

/// Every surface that counts the user's work has to count it the same way.
///
/// QA found four places that had drifted apart: the sidebar badge, 今天, the
/// island's 待办 preview and the daily report each decided for themselves what
/// "my work" meant, and two of them did not consult the strictness level at
/// all. These tests pin the shared rule.
final class DiscussionLevelConsistencyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(
        _ id: Int64,
        kind: DiscussionItemKind,
        owner: DiscussionItemOwner,
        due: Date? = nil
    ) -> DiscussionItem {
        DiscussionItem(
            id: id, chatUsername: "c", chatName: "林晓", kind: kind, owner: owner,
            content: "item-\(id)", detail: nil, anchorMsgUID: "\(id)",
            sourceTimestamp: Int(now.timeIntervalSince1970), dueAt: due, status: .pending,
            confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now
        )
    }

    func testBadgeTodayTabsAndReportAgreeOnMyWork() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("consist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: dir.appendingPathComponent("hud.sqlite3").path)
        try store.open()

        // One of each shape that has ever caused the counts to differ.
        let shapes: [(DiscussionItemKind, DiscussionItemOwner, Int64)] = [
            (.todo, .mine, 1),          // work of mine
            (.question, .mine, 2),      // work of mine, waiting on my answer
            (.timePlace, .mine, 3),     // a record that happens to be mine
            (.info, .mine, 4),          // a record
            (.todo, .theirs, 5),        // someone else's work
            (.timePlace, .shared, 6)    // a record
        ]
        for (kind, owner, id) in shapes {
            _ = try store.insertDiscussionItem(
                chatUsername: "c", chatName: "林晓", kind: kind, owner: owner,
                content: "item-\(id)", detail: nil, anchorMsgUID: "\(id)",
                sourceTimestamp: Int(now.timeIntervalSince1970), dueAt: nil,
                confidence: 0.9, promptVersion: "test"
            )
        }

        for level in DiscussionStrictness.allCases {
            let items = store.loadDiscussionItems(status: .pending)
            let badge = WorkspaceBadgeCounts.taskCount(items, strictness: level)
            let today = TodayFeed.mineTasks(items, strictness: level).count
            let tab = DiscussionPresentation.items(
                items.filter { level.admits($0) }, scope: .mine, query: "", history: false
            ).count
            XCTAssertEqual(badge, today, "\(level.label): badge \(badge) vs 今天 \(today)")
            XCTAssertEqual(badge, tab, "\(level.label): badge \(badge) vs 我要做 tab \(tab)")
        }
    }

    func testTimePlaceIsNeverCountedAsMyWork() {
        // It is a record kind. Counting it as work made the badge promise a row
        // the 我要做 tab would not show.
        let items = [item(1, kind: .timePlace, owner: .mine)]
        for level in DiscussionStrictness.allCases {
            XCTAssertEqual(WorkspaceBadgeCounts.taskCount(items, strictness: level), 0, "\(level.label)")
            XCTAssertTrue(TodayFeed.mineTasks(items, strictness: level).isEmpty, "\(level.label)")
        }
    }

    func testReceiptCountsOnlyRealWorkAsMine() {
        // QA measured the old wording claiming 28 held-back items of "mine"
        // when only one of them was work; the rest were records.
        let items = [
            item(1, kind: .info, owner: .mine),
            item(2, kind: .timePlace, owner: .mine),
            item(3, kind: .question, owner: .mine),
            item(4, kind: .todo, owner: .mine),
            item(5, kind: .info, owner: .shared)
        ]
        let hidden = DiscussionStrictness.pressing.hidden(from: items, now: now)
        let mineWork = hidden.filter { $0.owner == .mine && !$0.kind.isRecord }.count
        // `pressing` keeps todo/decision with a side attached, but a question
        // of mine with no deadline does not qualify — so it is held back, and
        // the receipt must say so. That single item is exactly the number the
        // old wording inflated to 28 by counting records as work.
        XCTAssertEqual(hidden.count, 4, "two records of mine, my open question, one shared record")
        XCTAssertEqual(mineWork, 1, "one held-back item is genuinely my work")
        // At actionable the records go but the work stays — same rule.
        let actionableHidden = DiscussionStrictness.actionable.hidden(from: items, now: now)
        XCTAssertEqual(actionableHidden.count, 3, "only the records")
        XCTAssertEqual(
            actionableHidden.filter { $0.owner == .mine && !$0.kind.isRecord }.count, 0,
            "the default level never holds back my work"
        )
    }

    func testReportBuilderFiltersByTheSameLevel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: dir.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        for (kind, id) in [(DiscussionItemKind.timePlace, 1), (.todo, 2)] {
            _ = try store.insertDiscussionItem(
                chatUsername: "c", chatName: "林晓", kind: kind, owner: .mine,
                content: "x\(id)", detail: nil, anchorMsgUID: "r\(id)",
                sourceTimestamp: Int(now.timeIntervalSince1970), dueAt: nil,
                confidence: 0.9, promptVersion: "test"
            )
        }
        let trusted = DailyReportBuilder(store: store, replyDebtItems: [], stats: HUDStats(), strictness: .actionable)
        let report = trusted.build(for: now, now: now)
        XCTAssertEqual(
            report.metrics.pendingTodoCount, 1,
            "the report counts work only — a record is not a todo"
        )
    }
}
