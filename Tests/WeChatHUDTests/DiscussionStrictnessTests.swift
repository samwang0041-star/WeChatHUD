import XCTest
@testable import WeChatHUD

/// The task surfaces were showing everything the extractor produced: on a real
/// corpus half of the pending list was record-keeping (`info`), all of it
/// competing for attention with actual work. These tests pin the three levels
/// that decide what counts as work.
///
/// The knob is deliberately structural (kind + owner + date) rather than a
/// confidence threshold: confidence on this corpus is saturated and
/// anti-correlated with work — a factual sentence scores high, a real request
/// scores lower — so tightening it deletes tasks and keeps trivia. That
/// property is asserted here too, so nobody "fixes" it back to confidence.
final class DiscussionStrictnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(
        kind: DiscussionItemKind,
        owner: DiscussionItemOwner,
        due: Date? = nil,
        status: DiscussionItemStatus = .pending,
        content: String = "x"
    ) -> DiscussionItem {
        DiscussionItem(
            id: Int64(abs(content.hashValue % 100_000)),
            chatUsername: "c",
            chatName: "林晓",
            kind: kind,
            owner: owner,
            content: content,
            detail: nil,
            anchorMsgUID: "m",
            sourceTimestamp: Int(now.timeIntervalSince1970),
            dueAt: due,
            status: status,
            confidence: 0.9,
            promptVersion: "test",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Level semantics

    func testEverythingAdmitsRecordsAndWork() {
        XCTAssertTrue(DiscussionStrictness.everything.admits(kind: .info, owner: .shared, dueAt: nil, now: now))
        XCTAssertTrue(DiscussionStrictness.everything.admits(kind: .timePlace, owner: .shared, dueAt: nil, now: now))
        XCTAssertTrue(DiscussionStrictness.everything.admits(kind: .todo, owner: .mine, dueAt: nil, now: now))
    }

    func testActionableDropsRecordKindsButKeepsEverySide() {
        let level = DiscussionStrictness.actionable
        XCTAssertFalse(level.admits(kind: .info, owner: .mine, dueAt: nil, now: now))
        XCTAssertFalse(level.admits(kind: .timePlace, owner: .mine, dueAt: nil, now: now))
        for kind in [DiscussionItemKind.todo, .decision, .question] {
            for owner in [DiscussionItemOwner.mine, .theirs, .shared] {
                XCTAssertTrue(level.admits(kind: kind, owner: owner, dueAt: nil, now: now), "\(kind)/\(owner)")
            }
        }
    }

    func testPressingKeepsWorkWithASideOrANearDate() {
        let level = DiscussionStrictness.pressing
        // Work with a side attached survives regardless of date.
        XCTAssertTrue(level.admits(kind: .todo, owner: .mine, dueAt: nil, now: now))
        XCTAssertTrue(level.admits(kind: .decision, owner: .theirs, dueAt: nil, now: now))
        // Unowned work needs a date inside the window.
        XCTAssertFalse(level.admits(kind: .todo, owner: .shared, dueAt: nil, now: now))
        XCTAssertFalse(level.admits(kind: .question, owner: .shared, dueAt: nil, now: now))
        let soon = now.addingTimeInterval(2 * 24 * 60 * 60)
        XCTAssertTrue(level.admits(kind: .question, owner: .shared, dueAt: soon, now: now))
        let far = now.addingTimeInterval(30 * 24 * 60 * 60)
        XCTAssertFalse(level.admits(kind: .question, owner: .shared, dueAt: far, now: now))
        // Records stay out even when dated: the level is about work.
        XCTAssertFalse(level.admits(kind: .info, owner: .mine, dueAt: soon, now: now))
    }

    func testLevelsAreMonotonic() {
        // Narrowing must never bring something back: a user who tightens the
        // level and sees an item appear has been lied to about the ordering.
        let kinds: [DiscussionItemKind] = [.todo, .decision, .question, .timePlace, .info]
        let owners: [DiscussionItemOwner] = [.mine, .theirs, .shared]
        let dates: [Date?] = [nil, now.addingTimeInterval(86400), now.addingTimeInterval(40 * 86400)]
        for kind in kinds {
            for owner in owners {
                for due in dates {
                    let e = DiscussionStrictness.everything.admits(kind: kind, owner: owner, dueAt: due, now: now)
                    let a = DiscussionStrictness.actionable.admits(kind: kind, owner: owner, dueAt: due, now: now)
                    let p = DiscussionStrictness.pressing.admits(kind: kind, owner: owner, dueAt: due, now: now)
                    XCTAssertTrue(e || !a, "actionable admitted \(kind)/\(owner) that everything rejected")
                    XCTAssertTrue(a || !p, "pressing admitted \(kind)/\(owner) that actionable rejected")
                }
            }
        }
    }

    func testNonPendingItemsAreNeverAdmitted() {
        for level in DiscussionStrictness.allCases {
            for status in [DiscussionItemStatus.done, .dismissed, .archived] {
                let done = item(kind: .todo, owner: .mine, status: status, content: "\(level)-\(status)")
                XCTAssertFalse(level.admits(done), "\(level) admitted a \(status) item")
            }
        }
    }

    func testHiddenSetIsExactlyTheComplement() {
        let items = [
            item(kind: .todo, owner: .mine, content: "a"),
            item(kind: .info, owner: .shared, content: "b"),
            item(kind: .timePlace, owner: .shared, content: "c"),
            item(kind: .todo, owner: .mine, status: .done, content: "d")
        ]
        for level in DiscussionStrictness.allCases {
            let shown = items.filter { level.admits($0) }
            let hidden = level.hidden(from: items)
            XCTAssertEqual(shown.count + hidden.count, items.filter { $0.status == .pending }.count, "\(level)")
            XCTAssertTrue(Set(shown.map(\.id)).isDisjoint(with: Set(hidden.map(\.id))))
        }
    }

    // MARK: - The knob is structural, not confidence

    func testWorkIsFoundEvenWhenConfidenceIsLow() {
        // A request phrased casually scores lower than a fact, so any
        // confidence-based level would drop it. The structural level must not.
        let lowConfidenceWork = item(kind: .todo, owner: .mine, content: "低置信但要做");
        let highConfidenceFact = item(kind: .info, owner: .shared, content: "高置信但只是事实");
        for level in DiscussionStrictness.allCases where level != .everything {
            XCTAssertTrue(level.admits(lowConfidenceWork), "\(level) dropped real work")
            XCTAssertFalse(level.admits(highConfidenceFact), "\(level) kept a record as work")
        }
    }

    // MARK: - Persistence

    func testSettingRoundTripsAndDefaultsAreLenient() throws {
        let encoded = try JSONEncoder().encode(DiscussionStrictnessSetting(level: .pressing));
        let decoded = try JSONDecoder().decode(DiscussionStrictnessSetting.self, from: encoded);
        XCTAssertEqual(decoded.level, .pressing);
        // A value written by a newer build must not blank the list.
        let unknown = Data(#"{"level":"future_level"}"#.utf8);
        XCTAssertEqual(try JSONDecoder().decode(DiscussionStrictnessSetting.self, from: unknown).level, .actionable);
        // An absent setting means the user never chose.
        XCTAssertEqual(DiscussionStrictness.default, .actionable);
    }

    func testLabelsAndReceiptWordingAreStable() {
        XCTAssertEqual(DiscussionStrictness.allCases.map(\.label), ["全部都记", "只留要做的", "只留压在我身上的"])
        XCTAssertEqual(DiscussionWorkspaceView.receiptLabel(hidden: 413, mine: 0), "已收起 413 条 · 展开")
        XCTAssertEqual(
            DiscussionWorkspaceView.receiptLabel(hidden: 629, mine: 140),
            "已收起 629 条（其中 140 条是我要做的） · 展开"
        )
    }

    func testBadgeAndTodayShareTheLevel() {
        let items = [
            item(kind: .todo, owner: .mine, due: now.addingTimeInterval(-3600), content: "overdue task"),
            item(kind: .info, owner: .mine, content: "memo")
        ]
        // The badge never counts memos, at any level.
        for level in DiscussionStrictness.allCases {
            XCTAssertEqual(WorkspaceBadgeCounts.taskCount(items, strictness: level), 1, "\(level)")
        }
        // 今天 agrees with the badge instead of rolling its own rule.
        XCTAssertEqual(TodayFeed.mineTasks(items, strictness: .actionable).count, 1)
        XCTAssertEqual(TodayFeed.mineTasks(items, strictness: .everything).count, 1, "memos stay out of 今天 at every level")
    }
}
