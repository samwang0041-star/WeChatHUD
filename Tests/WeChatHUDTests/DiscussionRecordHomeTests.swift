import XCTest
@testable import WeChatHUD

/// Every kind the extractor produces must have somewhere to be seen, at every
/// strictness level. The levels hold the two record kinds out of the task list,
/// so those kinds need a tab of their own — otherwise an item is hidden by the
/// level and invisible in every tab, while still being counted as "held back".
///
/// `timePlace` was exactly that gap: the levels excluded it, and 信息备忘
/// filtered to `info` alone. (Found in QA, not by a failing test — which is why
/// this one exists.)
final class DiscussionRecordHomeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ id: Int64, kind: DiscussionItemKind, owner: DiscussionItemOwner) -> DiscussionItem {
        DiscussionItem(
            id: id, chatUsername: "c", chatName: "林晓", kind: kind, owner: owner,
            content: "\(kind)-\(owner)-\(id)", detail: nil, anchorMsgUID: "\(id)",
            sourceTimestamp: Int(now.timeIntervalSince1970), dueAt: nil, status: .pending,
            confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now
        )
    }

    func testRecordKindsAreExactlyInfoAndTimePlace() {
        XCTAssertTrue(DiscussionItemKind.info.isRecord)
        XCTAssertTrue(DiscussionItemKind.timePlace.isRecord)
        for kind in [DiscussionItemKind.todo, .decision, .question] {
            XCTAssertFalse(kind.isRecord, "\(kind) is work, not a record")
        }
    }

    func testMemoTabShowsBothRecordKinds() {
        let items = [
            item(1, kind: .info, owner: .shared),
            item(2, kind: .timePlace, owner: .shared),
            item(3, kind: .todo, owner: .mine),
            item(4, kind: .question, owner: .theirs)
        ]
        let notes = DiscussionPresentation.items(items, scope: .notes, query: "", history: false)
        XCTAssertEqual(Set(notes.map(\.id)), [1, 2], "both record kinds, and only those")
    }

    func testRecordKindsDoNotAppearAsWork() {
        // A record showing up under 我要做 would list the same item twice —
        // once as work and once as a memo.
        let items = [
            item(1, kind: .info, owner: .mine),
            item(2, kind: .timePlace, owner: .mine),
            item(3, kind: .timePlace, owner: .theirs),
            item(4, kind: .timePlace, owner: .shared)
        ]
        XCTAssertTrue(DiscussionPresentation.items(items, scope: .mine, query: "", history: false).isEmpty)
        XCTAssertTrue(DiscussionPresentation.items(items, scope: .theirs, query: "", history: false).isEmpty)
        XCTAssertTrue(DiscussionPresentation.items(items, scope: .shared, query: "", history: false).isEmpty)
    }

    func testEveryRecordKindIsReachableAtEveryLevel() {
        // The bug this pins: a kind that the level hides and no tab can show.
        let kinds: [DiscussionItemKind] = [.todo, .decision, .question, .info, .timePlace]
        let owners: [DiscussionItemOwner] = [.mine, .theirs, .shared]
        var next: Int64 = 1
        var items: [DiscussionItem] = []
        for kind in kinds {
            for owner in owners {
                items.append(item(next, kind: kind, owner: owner));
                next += 1
            }
        }
        for level in DiscussionStrictness.allCases {
            // What the workspace would actually be able to render: the level's
            // filter feeds the tabs, so a tab is only a home if the union of
            // all tabs covers every admitted item.
            let admitted = items.filter { level.admits($0) }
            var reachable = Set<Int64>()
            for scope in DiscussionScope.allCases {
                let shown = DiscussionPresentation.items(admitted, scope: scope, query: "", history: false, now: now, calendar: .current)
                reachable.formUnion(shown.map(\.id))
            }
            XCTAssertEqual(
                reachable, Set(admitted.map(\.id)),
                "\(level.label) hides items that no tab can show: \(Set(admitted.map(\.id)).subtracting(reachable))"
            )
        }
    }

    func testHeldBackCountMatchesWhatTheMemoTabRecovers() {
        // The receipt promises the user can get the held-back rows back. The
        // promise is only true if the record tabs cover them.
        let items = [
            item(1, kind: .info, owner: .shared),
            item(2, kind: .timePlace, owner: .shared),
            item(3, kind: .todo, owner: .mine)
        ]
        let hidden = DiscussionStrictness.actionable.hidden(from: items)
        let recovered = DiscussionPresentation.items(hidden, scope: .notes, query: "", history: false)
        XCTAssertEqual(hidden.count, 2)
        XCTAssertEqual(
            Set(recovered.map(\.id)), Set(hidden.map(\.id)),
            "every held-back item must be visible somewhere the user can reach"
        )
    }
}
