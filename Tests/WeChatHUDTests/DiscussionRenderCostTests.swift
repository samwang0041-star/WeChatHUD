import XCTest
@testable import WeChatHUD

/// Guards the render cost of the 待办 workspace. The store legitimately holds
/// thousands of pending items, and `DiscussionWorkspaceView` re-reads its item
/// list several times per row, so an unmemoized filter+sort per access turns a
/// single render pass into an O(rows² log rows) storm.
final class DiscussionRenderCostTests: XCTestCase {

    private func items(_ count: Int) -> [DiscussionItem] {
        let now = Date()
        return (0..<count).map { index in
            DiscussionItem(
                id: Int64(index),
                chatUsername: "chat\(index % 37)",
                chatName: "对话 \(index % 37)",
                kind: index % 5 == 0 ? .info : .todo,
                owner: [DiscussionItemOwner.mine, .theirs, .shared][index % 3],
                content: "事项内容 \(index) 需要处理",
                detail: "细节 \(index)",
                anchorMsgUID: "m\(index)",
                sourceTimestamp: 1_700_000_000 + index,
                dueAt: index % 7 == 0 ? now.addingTimeInterval(Double(index)) : nil,
                status: .pending,
                confidence: 0.9,
                promptVersion: "test",
                createdAt: now,
                updatedAt: now
            )
        }
    }

    /// A single `DiscussionPresentation.items` pass over the live corpus must
    /// stay well under one frame budget so scrolling does not drop frames.
    func testSinglePresentationPassIsFastAtLiveScale() {
        let corpus = items(3000)

        _ = DiscussionPresentation.items(corpus, scope: .all, query: "", history: false)

        let start = DispatchTime.now()
        for _ in 0..<20 {
            _ = DiscussionPresentation.items(corpus, scope: .all, query: "", history: false)
        }
        let msPerCall = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 / 20

        XCTAssertLessThan(
            msPerCall, 12,
            "one filter+sort pass over 3000 items took \(msPerCall)ms; the workspace calls this per row"
        )
    }

    /// Lazy row memoization: evaluating the same inputs repeatedly must not
    /// redo the sort. This mirrors what one render pass of the list pane does.
    func testRepeatedSameInputEvaluationDoesNotResort() {
        let corpus = items(3000)
        let cache = DiscussionItemsCache()

        let start = DispatchTime.now()
        for _ in 0..<200 {
            _ = cache.items(corpus, scope: .all, query: "", history: false)
        }
        let msTotal = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        XCTAssertLessThan(
            msTotal, 60,
            "200 repeated lookups with unchanged inputs took \(msTotal)ms; they must reuse the cached sort"
        )
    }

    /// Changing an input must invalidate the cache and still return fresh data.
    func testCacheInvalidatesOnInputChange() {
        let cache = DiscussionItemsCache()
        let corpus = items(50)

        let all = cache.items(corpus, scope: .all, query: "", history: false)
        let mine = cache.items(corpus, scope: .mine, query: "", history: false)
        let searched = cache.items(corpus, scope: .all, query: "事项内容 3", history: false)

        XCTAssertEqual(all.count, 50)
        XCTAssertTrue(mine.allSatisfy { $0.owner == .mine })
        XCTAssertLessThan(mine.count, all.count)
        XCTAssertFalse(searched.isEmpty)
        XCTAssertTrue(searched.allSatisfy { $0.content.contains("事项内容 3") })
    }
}
